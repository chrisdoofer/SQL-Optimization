# SQL Server Edition Optimisation - Azure Arc Reference Implementation

A scalable Azure Functions (PowerShell) solution that identifies SQL Server Enterprise-to-Standard downgrade opportunities across large Arc-enabled estates. Uses Azure Resource Graph for discovery, Arc Run Command for agentless DMV extraction, and the Logs Ingestion API for centralised reporting via Power BI.

## Architecture Overview

```
                              +---------------------------+
                              |     HTTP / Timer Trigger  |
                              +------------+--------------+
                                           |
                              +------------v--------------+
                              |   Direct Workflow Engine  |
                              |   (sequential processing)|
                              +---+----+----+----+---+---+
                                  |    |    |    |   |
                    Step 1: Resource Graph Discovery (paginated, 1000/page)
                                  |
                    Step 2: Arc Run Command per machine (with retry)
                                  |
                    Step 3: Logs Ingestion API (batched)
                                  |
                  +---------v-----------+       +------------------+
                  |  Log Analytics      |------>|  Power BI        |
                  |  Custom Table       |       |  Dashboard       |
                  +---------------------+       +------------------+
```

**Key design decisions:**
- Direct execution model — no Durable Functions SDK dependency issues
- Resource Graph pagination handles estates with 1000+ servers
- Exponential backoff retry (3 attempts) on Run Command failures
- Batched Logs Ingestion (500 entries/batch, splits at 1MB)
- 30-minute function timeout supports estates up to ~50 machines per invocation
- Timer trigger for weekly scheduled scans

---

## Prerequisites

### Azure Resources Required

| Resource | Purpose |
|----------|---------|
| Azure Arc-enabled servers with SQL Server | Target Windows machines |
| Log Analytics Workspace | Stores edition optimisation results |
| Data Collection Endpoint (DCE) | Ingestion endpoint for custom logs |
| Data Collection Rule (DCR) | Maps ingested data to the custom table |
| Function App (Elastic Premium EP1+) | Hosts the optimisation workflow |

### Software & Tools (for deployment)

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (v2.50+)
- [Azure Functions Core Tools](https://learn.microsoft.com/azure/azure-functions/functions-run-local) (v4.x)
- [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) (included with Azure CLI)
- PowerShell 7.6+

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

### Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) v2.50+ (`az login` completed)
- [Azure Functions Core Tools](https://learn.microsoft.com/azure/azure-functions/functions-run-local) v4.x
- **Contributor** on the deployment subscription + **User Access Administrator** at the Management Group scope

> **No existing Log Analytics Workspace required** — the deployment creates everything from scratch.

### One-Command Deployment (Recommended)

Clone the repo and run the deployment script — it handles everything:

```powershell
git clone https://github.com/chrisdoofer/SQL-Optimization.git
cd SQL-Optimization

.\Deploy.ps1 `
    -DeploymentSubscriptionId "<dedicated-tooling-subscription-id>" `
    -ResourceGroupName "rg-sqleditionopt" `
    -Location "uksouth" `
    -FunctionAppName "func-sqleditionopt-<yourorg>" `
    -ManagementGroupId "mg-production"
```

**That's it.** The script:
1. ✅ Validates prerequisites (Azure CLI, func tools, login state)
2. ✅ Creates the resource group in the dedicated deployment subscription
3. ✅ Deploys all infrastructure via Bicep (Function App, Log Analytics, custom table, DCE, DCR)
4. ✅ Assigns RBAC at **Management Group** level (one assignment covers all child subscriptions)
5. ✅ Deploys the function code
6. ✅ Automatically triggers the first scan

**Why Management Group scope?**
- No need to list individual subscriptions — one RBAC assignment covers the entire hierarchy
- Automatically includes future subscriptions added under the management group
- Resource Graph queries all accessible subscriptions by default (no subscription list in code)
- The Function App deploys into its own dedicated subscription, isolated from workloads

> **Tip:** Omit `-ManagementGroupId` to default to the **Tenant Root Management Group** (scans entire tenant).

### Manual Step-by-Step (Alternative)

<details>
<summary>Click to expand manual deployment steps</summary>

#### Step 1: Deploy Infrastructure (Bicep)

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

#### Step 2: Assign RBAC Roles (Management Group scope)

| Role | Scope | Purpose |
|------|-------|---------|
| **Reader** | Management Group | Resource Graph queries across all child subscriptions |
| **Azure Connected Machine Resource Administrator** | Management Group | Execute Run Commands on any Arc machine |
| **Monitoring Metrics Publisher** | Data Collection Rule | Logs Ingestion API (least privilege) |

```bash
PRINCIPAL_ID=$(az functionapp identity show \
  --name func-sqleditionopt \
  --resource-group rg-sqleditionopt \
  --query principalId -o tsv)

# Single assignment covers ALL child subscriptions
az role assignment create \
  --assignee "$PRINCIPAL_ID" \
  --role "Reader" \
  --scope "/providers/Microsoft.Management/managementGroups/<mg-id>"

az role assignment create \
  --assignee "$PRINCIPAL_ID" \
  --role "Azure Connected Machine Resource Administrator" \
  --scope "/providers/Microsoft.Management/managementGroups/<mg-id>"

az role assignment create \
  --assignee "$PRINCIPAL_ID" \
  --role "Monitoring Metrics Publisher" \
  --scope "$(az monitor data-collection rule show --name func-sqleditionopt-dcr --resource-group rg-sqleditionopt --query id -o tsv)"
```

#### Step 3: Deploy Function Code

```bash
cd src
func azure functionapp publish func-sqleditionopt
```

</details>

### CI/CD (Optional)

A GitHub Actions workflow is included at `.github/workflows/deploy.yml` for teams that want push-to-deploy automation. This is **optional** — the solution works without it. See the workflow file for required secrets and OIDC setup.

---

## Execution

### Automatic (Post-Deployment)

The deployment script automatically triggers the first scan after publishing the function code. No manual action is required — results will begin appearing in Log Analytics within minutes (depending on estate size).

### On-Demand (HTTP)

The function requires a **function key** for authentication. Retrieve it and trigger a scan:

**PowerShell:**
```powershell
$funcName = "func-sqleditionopt-<yourorg>"
$rgName = "rg-sqleditionopt"

$key = az functionapp function keys list `
    --name $funcName `
    --resource-group $rgName `
    --function-name HttpStartFunction `
    --query "default" -o tsv

# Start workflow — scans ALL Arc-enabled SQL Servers in the Management Group
$response = Invoke-RestMethod `
    -Uri "https://$funcName.azurewebsites.net/api/orchestrate?code=$key" `
    -Method Post -ContentType 'application/json' -Body '{}'

# View results
$response | ConvertTo-Json -Depth 5
```

**Bash/curl:**
```bash
FUNC_NAME="func-sqleditionopt-<yourorg>"
RG_NAME="rg-sqleditionopt"

FUNC_KEY=$(az functionapp function keys list \
  --name $FUNC_NAME \
  --resource-group $RG_NAME \
  --function-name HttpStartFunction \
  --query "default" -o tsv)

# Start scan
curl -X POST "https://${FUNC_NAME}.azurewebsites.net/api/orchestrate?code=${FUNC_KEY}" \
  -H "Content-Type: application/json" \
  -d '{}'

# Optionally filter by tag (e.g. scan only Production machines)
curl -X POST "https://${FUNC_NAME}.azurewebsites.net/api/orchestrate?code=${FUNC_KEY}" \
  -H "Content-Type: application/json" \
  -d '{ "tagFilter": { "Environment": "Production" } }'
```

The function discovers all Arc-enabled SQL Servers across the entire Management Group scope (configured at deployment). No subscription list is needed — Resource Graph queries tenant-wide using the Managed Identity's Reader role.

The HTTP response returns a JSON summary with machine counts, success/failure stats, and ingestion status.

### Scheduled (Timer)

Runs automatically every Sunday at 02:00 UTC. Edit `src/ScheduledTrigger/function.json` to change.

### Local Development

```bash
cd src
func start
curl -X POST http://localhost:7071/api/orchestrate -H "Content-Type: application/json" -d '{}'
```

---

## Configuration

In `host.json`:

```json
{
  "functionTimeout": "00:30:00"
}
```

- **30-minute timeout** supports sequential processing of ~50 machines (each Run Command takes ~30-60s)
- For larger estates (100+ machines), upgrade to Elastic Premium EP2 and consider splitting into batches
- The Elastic Premium plan auto-scales workers for timer triggers

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
+-- Deploy.ps1                         # ONE-COMMAND DEPLOYMENT (clone, run, done)
+-- infrastructure/
|   +-- main.bicep                    # All infra: Function App, table, DCE, DCR
|   +-- role-assignments.bicep        # RBAC reference (used by Deploy.ps1)
+-- src/
|   +-- host.json                     # Function App config (timeout settings)
|   +-- local.settings.json           # Local dev settings
|   +-- profile.ps1                   # Managed Identity auth on startup
|   +-- requirements.psd1             # Az module dependencies
|   +-- modules/
|   |   +-- LogsIngestion.ps1         # Shared: Logs Ingestion API client (batched)
|   +-- HttpStartFunction/            # HTTP trigger -> runs full workflow
|   +-- ScheduledTrigger/             # Timer trigger -> runs full workflow
|   +-- DurableOrchestrator/          # (Disabled) Fan-out/fan-in for future use
|   +-- ActivityDiscoverMachines/     # (Disabled) Resource Graph query
|   +-- ActivityRunCommand/           # (Disabled) Run Command activity
|   +-- ActivityIngestLogs/           # (Disabled) Logs Ingestion activity
+-- powerbi/
|   +-- README-PowerBI.md             # Power BI setup guide
|   +-- KQL-Queries.kql              # Ready-to-use KQL for Power BI connector
|   +-- DAX-Measures.dax             # DAX measures (cost model, eligibility)
|   +-- Generate-PowerBITemplate.ps1  # Helper to generate template definition
+-- .github/workflows/deploy.yml      # Optional: CI/CD for GitHub Actions users
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
| Function timeout | Increase `functionTimeout` in host.json. EP plan supports up to 60 min. |
| Throttling at scale | Reduce the number of machines per invocation by filtering with tags. |
