# SQL Server Edition Optimisation - Azure Arc Reference Implementation

A scalable Azure Functions (PowerShell) solution that identifies SQL Server Enterprise-to-Standard downgrade opportunities across large Arc-enabled estates. Uses Durable Functions fan-out/fan-in to process hundreds of servers in parallel, Azure Resource Graph for discovery, Arc Run Command for agentless DMV extraction, and the Logs Ingestion API for centralised reporting.

## Architecture Overview

```
                              +---------------------------+
                              |     HTTP / Timer Trigger  |
                              +------------+--------------+
                                           |
                              +------------v--------------+
                              |    Durable Orchestrator   |
                              |    (fan-out / fan-in)     |
                              +---+----+----+----+---+---+
                                  |    |    |    |   |
                    +-------------+    |    |    |   +-----------+
                    |                  |    |    |               |
              +-----v-----+    +------v-+  | +--v------+  +-----v-----+
              | Activity:  |   |Activity:|  | |Activity:|  | Activity:  |
              |RunCommand  |   |RunCmd   |  | |RunCmd   |  | RunCommand |
              | Server 1   |   |Server 2 |  | |Server N |  | Server N+1 |
              +-----+------+   +----+----+  | +----+----+  +-----+------+
                    |               |       |      |              |
                    +-------+-------+-------+------+--------------+
                            |
                  +---------v-----------+
                  |  Activity:          |
                  |  Ingest to Log      |
                  |  Analytics (batched)|
                  +---------+-----------+
                            |
                  +---------v-----------+       +------------------+
                  |  Log Analytics      |------>|  Power BI        |
                  |  Custom Table       |       |  Dashboard       |
                  +---------------------+       +------------------+
```

**Key design for scale:**
- Durable Functions fan-out/fan-in processes machines in parallel (default: 50 concurrent)
- Resource Graph pagination handles estates with 1000+ servers
- Exponential backoff retry (3 attempts) on Run Command failures
- Batched Logs Ingestion (500 entries/batch, splits at 1MB)
- Elastic Premium plan scales workers automatically

---

## Prerequisites

### Azure Resources Required

| Resource | Purpose |
|----------|---------|
| Azure Arc-enabled servers with SQL Server | Target Windows machines |
| Log Analytics Workspace | Stores edition optimisation results |
| Data Collection Endpoint (DCE) | Ingestion endpoint for custom logs |
| Data Collection Rule (DCR) | Maps ingested data to the custom table |
| Function App (Elastic Premium EP1+) | Hosts Durable Functions orchestration |

### Software & Tools (for deployment)

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (v2.50+)
- [Azure Functions Core Tools](https://learn.microsoft.com/azure/azure-functions/functions-run-local) (v4.x)
- [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) (included with Azure CLI)
- PowerShell 7.4+

### Target Machine Requirements

- Azure Arc agent installed and status = **Connected**
- SQL Server instance(s) running (Windows only)
- `SqlServer` PowerShell module installed (`Install-Module SqlServer -Force`)
- No inbound connectivity required - Arc Run Command is outbound-only

### Security Model

- **No SQL credentials distributed** - scripts execute locally via the Arc agent
- **No additional agents** - leverages existing Arc connectivity
- **HTTPS outbound only** - no inbound ports required
- **RBAC-controlled ingestion** - Managed Identity + Monitoring Metrics Publisher role
- **Managed Identity** for all Azure API calls - zero secrets in config

---

## Deployment

### Step 1: Deploy Infrastructure (Bicep)

A single deployment creates everything: Function App, custom Log Analytics table, Data Collection Endpoint, Data Collection Rule, and wires them together automatically.

**Only prerequisite:** an existing Log Analytics Workspace.

```bash
az login

az group create --name rg-sqleditionopt --location uksouth

az deployment group create \
  --resource-group rg-sqleditionopt \
  --template-file infrastructure/main.bicep \
  --parameters \
    functionAppName="func-sqleditionopt" \
    logAnalyticsWorkspaceId="/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>"
```

This creates:
- Storage Account
- Elastic Premium App Service Plan (EP1)
- Application Insights
- Custom table `SQLEditionOptimisation_CL` in your workspace
- Data Collection Endpoint (DCE)
- Data Collection Rule (DCR) linked to the table
- Function App with all settings pre-configured (DCE/DCR values wired automatically)

### Step 2: Assign RBAC Roles

| Role | Scope | Purpose |
|------|-------|---------|
| **Reader** | Target subscription(s) | Resource Graph queries |
| **Azure Connected Machine Resource Administrator** | Target subscription(s) | Execute Run Commands |
| **Monitoring Metrics Publisher** | Data Collection Rule | Logs Ingestion API |

```bash
PRINCIPAL_ID=$(az functionapp identity show \
  --name func-sqleditionopt \
  --resource-group rg-sqleditionopt \
  --query principalId -o tsv)

az role assignment create \
  --assignee "$PRINCIPAL_ID" \
  --role "Reader" \
  --scope "/subscriptions/<target-subscription-id>"

az role assignment create \
  --assignee "$PRINCIPAL_ID" \
  --role "Azure Connected Machine Resource Administrator" \
  --scope "/subscriptions/<target-subscription-id>"

az role assignment create \
  --assignee "$PRINCIPAL_ID" \
  --role "Monitoring Metrics Publisher" \
  --scope "$(az monitor data-collection rule show --name func-sqleditionopt-dcr --resource-group rg-sqleditionopt --query id -o tsv)"
```

### Step 3: Deploy Function Code

```bash
cd src
func azure functionapp publish func-sqleditionopt
```

---

## Execution

### On-Demand (HTTP)

```bash
FUNC_URL=$(az functionapp function show \
  --name func-sqleditionopt \
  --resource-group rg-sqleditionopt \
  --function-name HttpStartFunction \
  --query invokeUrlTemplate -o tsv)

FUNC_KEY=$(az functionapp function keys list \
  --name func-sqleditionopt \
  --resource-group rg-sqleditionopt \
  --function-name HttpStartFunction \
  --query default -o tsv)

# Start orchestration (returns status URLs for monitoring)
curl -X POST "${FUNC_URL}?code=${FUNC_KEY}" \
  -H "Content-Type: application/json" \
  -d '{}'

# With subscription/tag filters
curl -X POST "${FUNC_URL}?code=${FUNC_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "subscriptionIds": ["<sub-id-1>", "<sub-id-2>"],
    "tagFilter": { "Environment": "Production" }
  }'
```

The HTTP response includes a `statusQueryGetUri` — poll it to track progress.

### Scheduled (Timer)

Runs automatically every Sunday at 02:00 UTC. Edit `src/ScheduledTrigger/function.json` to change.

### Local Development

```bash
cd src
func start
curl -X POST http://localhost:7071/api/orchestrate -H "Content-Type: application/json" -d '{}'
```

---

## Scaling Configuration

In `host.json`:

```json
{
  "extensions": {
    "durableTask": {
      "maxConcurrentActivityFunctions": 50,
      "maxConcurrentOrchestratorFunctions": 10
    }
  }
}
```

- **50 concurrent activities** = 50 Arc machines processed simultaneously
- Adjust based on Azure subscription throttling limits
- The Elastic Premium EP1 plan auto-scales workers; upgrade to EP2/EP3 for larger estates
- For 500+ machines, consider increasing to EP2 and `maxConcurrentActivityFunctions: 100`

---

## Power BI Dashboard

See [`powerbi/README-PowerBI.md`](powerbi/README-PowerBI.md) for full setup instructions.

### Quick Summary

1. Open Power BI Desktop
2. **Get Data** → **Azure Log Analytics** → enter Workspace ID
3. Authenticate with Entra ID
4. Use the KQL queries from `powerbi/KQL-Queries.kql`
5. Add DAX measures from `powerbi/DAX-Measures.dax`
6. Save as `.pbit` template to share

### Prerequisites for Power BI Users

| Requirement | Details |
|-------------|---------|
| **Software** | Power BI Desktop (free) |
| **RBAC** | `Log Analytics Reader` on the workspace |
| **Auth** | Entra ID credentials (delegated — no app registration needed) |

### Cost Model (SQL Server 2022)

| Edition | Per 2-Core Pack | Per Core | Saving/Core on Downgrade |
|---------|----------------|----------|--------------------------|
| Enterprise | $15,123 | $7,561.50 | — |
| Standard | $3,945 | $1,972.50 | **$5,589.00** |

Source: [Microsoft SQL Server 2022 Pricing](https://www.microsoft.com/en-us/sql-server/sql-server-2022-pricing)

---

## Project Structure

```
SQL-Optimization/
+-- infrastructure/
|   +-- main.bicep                    # Function App (Elastic Premium), Storage, App Insights
|   +-- role-assignments.bicep        # RBAC for Managed Identity
+-- src/
|   +-- host.json                     # Durable Functions config (concurrency settings)
|   +-- local.settings.json           # Local dev settings
|   +-- profile.ps1                   # Managed Identity auth on startup
|   +-- requirements.psd1             # Az module dependencies
|   +-- modules/
|   |   +-- LogsIngestion.ps1         # Shared: Logs Ingestion API client (batched)
|   +-- HttpStartFunction/            # HTTP trigger -> starts orchestration
|   +-- ScheduledTrigger/             # Timer trigger -> starts orchestration
|   +-- DurableOrchestrator/          # Fan-out/fan-in orchestrator
|   +-- ActivityDiscoverMachines/     # Queries Resource Graph (paginated)
|   +-- ActivityRunCommand/           # Executes DMV script on one machine (with retry)
|   +-- ActivityIngestLogs/           # Batches results to Logs Ingestion API
+-- powerbi/
|   +-- README-PowerBI.md             # Power BI setup guide
|   +-- KQL-Queries.kql              # Ready-to-use KQL for Power BI connector
|   +-- DAX-Measures.dax             # DAX measures (cost model, eligibility)
|   +-- Generate-PowerBITemplate.ps1  # Helper to generate template definition
+-- README.md
```

---

## Troubleshooting

| Issue | Resolution |
|-------|------------|
| Resource Graph returns 0 results | Verify Arc machines are **Connected**. Test in Resource Graph Explorer. |
| 403 on Run Command | Assign **Azure Connected Machine Resource Administrator** on target scope. |
| 403 on Logs Ingestion | Assign **Monitoring Metrics Publisher** on the **DCR** (not DCE or workspace). |
| SqlServer module not found on targets | Run `Install-Module SqlServer -Force` on each target machine. |
| `sys.dm_db_persisted_sku_features` empty | Expected for Standard Edition or no Enterprise features — means eligible. |
| Orchestration timeout | Increase `functionTimeout` in host.json. EP plan supports up to 60 min. |
| Throttling at scale | Reduce `maxConcurrentActivityFunctions` in host.json. |
| Durable status shows "Running" for long time | Normal for large estates. Poll the statusQueryGetUri. |
