# SQL Server Edition Optimisation - Azure Arc Reference Implementation

A scalable Azure Functions (PowerShell) solution that identifies SQL Server Enterprise-to-Standard downgrade opportunities across Arc-enabled estates. Uses Azure Resource Graph for discovery, Arc Run Command for agentless DMV extraction, and the Logs Ingestion API for centralised reporting.

## Architecture Overview

```
┌──────────────────┐     ┌──────────────────────┐     ┌──────────────────────────────┐
│  Azure Function  │────▶│  Azure Resource Graph │────▶│  Arc-enabled SQL Servers      │
│  (Timer / HTTP)  │     │  (Inventory & Discovery) │  │  (Run Command → DMV queries) │
└──────────────────┘     └──────────────────────┘     └──────────────────────────────┘
                                                                    │
                                                                    ▼
┌──────────────────┐     ┌──────────────────────┐     ┌──────────────────────────────┐
│   Power BI       │◀────│  Log Analytics (KQL) │◀────│  Logs Ingestion API           │
│   Dashboard      │     │  Custom Table         │     │  (DCE → DCR → Workspace)     │
└──────────────────┘     └──────────────────────┘     └──────────────────────────────┘
```

**Data Pipeline:**
1. Query Azure Resource Graph for connected Arc-enabled SQL Server instances
2. Execute DMV scripts via Arc Run Command (no direct SQL connectivity required)
3. Collect structured JSON results centrally
4. Push via Logs Ingestion API to a custom Log Analytics table
5. Model and query using KQL
6. Visualise in Power BI (edition breakdown, feature usage, downgrade eligibility, cost savings)

**Key Principle:** Azure Resource Graph provides inventory (edition, version, cores) but **cannot** identify Enterprise feature usage. The `sys.dm_db_persisted_sku_features` DMV must be executed inside the SQL engine — this is why Arc Run Command is essential.

---

## Prerequisites

### Azure Resources Required

| Resource | Purpose |
|----------|---------|
| Azure Arc-enabled servers with SQL Server | Target machines for feature analysis |
| Log Analytics Workspace | Stores edition optimisation results |
| Data Collection Endpoint (DCE) | Ingestion endpoint for custom logs |
| Data Collection Rule (DCR) | Maps ingested data to the custom table |
| Function App (Consumption plan) | Hosts the orchestration logic |

### Software & Tools (for deployment)

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (v2.50+)
- [Azure Functions Core Tools](https://learn.microsoft.com/azure/azure-functions/functions-run-local) (v4.x)
- [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) (included with Azure CLI)
- PowerShell 7.4+

### Target Machine Requirements

- Azure Arc agent installed and status = **Connected**
- SQL Server instance(s) running (any edition)
- `SqlServer` PowerShell module installed (`Install-Module SqlServer -Force`)
- Windows OS (Run Command executes PowerShell)
- No inbound connectivity required — Arc Run Command is outbound-only via the Arc agent

### Security Model

- **No SQL credentials distributed** — scripts execute locally via the Arc agent
- **No additional agents** — leverages existing Arc connectivity
- **HTTPS outbound only** — no inbound ports required
- **RBAC-controlled ingestion** — Managed Identity + Monitoring Metrics Publisher role

---

## Deployment

### Step 1: Create the Log Analytics Custom Table

Create a custom table (`SQLEditionOptimisation_CL`) in your Log Analytics workspace:

```json
{
  "properties": {
    "schema": {
      "name": "SQLEditionOptimisation_CL",
      "columns": [
        { "name": "TimeGenerated", "type": "datetime" },
        { "name": "MachineName", "type": "string" },
        { "name": "InstanceName", "type": "string" },
        { "name": "Edition", "type": "string" },
        { "name": "ProductVersion", "type": "string" },
        { "name": "ProductLevel", "type": "string" },
        { "name": "VisibleCPUs", "type": "int" },
        { "name": "DatabaseName", "type": "string" },
        { "name": "CompatibilityLevel", "type": "int" },
        { "name": "EnterpriseFeatures", "type": "string" },
        { "name": "FeatureCount", "type": "int" },
        { "name": "HasBlockingFeatures", "type": "boolean" },
        { "name": "DowngradeEligibility", "type": "string" },
        { "name": "ResourceGroup", "type": "string" },
        { "name": "SubscriptionId", "type": "string" },
        { "name": "Location", "type": "string" }
      ]
    }
  }
}
```

### Step 2: Create Data Collection Endpoint & Rule

```bash
# Create DCE
az monitor data-collection endpoint create \
  --name "dce-sqleditionopt" \
  --resource-group "<your-rg>" \
  --location "<region>" \
  --public-network-access "Enabled"

# Create DCR referencing the custom table and DCE
az monitor data-collection rule create \
  --name "dcr-sqleditionopt" \
  --resource-group "<your-rg>" \
  --location "<region>" \
  --rule-file dcr-definition.json
```

### Step 3: Deploy Infrastructure (Bicep)

```bash
# Login to Azure
az login

# Create resource group
az group create --name rg-sqleditionopt --location uksouth

# Deploy the Function App and supporting resources
az deployment group create \
  --resource-group rg-sqleditionopt \
  --template-file infrastructure/main.bicep \
  --parameters \
    functionAppName="func-sqleditionopt" \
    logAnalyticsWorkspaceId="/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>" \
    dceEndpoint="https://<your-dce>.uksouth-1.ingest.monitor.azure.com" \
    dcrImmutableId="dcr-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### Step 4: Assign RBAC Roles to the Managed Identity

| Role | Scope | Purpose |
|------|-------|---------|
| **Reader** | Target subscription(s) | Resource Graph queries |
| **Azure Connected Machine Resource Administrator** | Target subscription(s) or RG(s) | Execute Run Commands on Arc machines |
| **Monitoring Metrics Publisher** | Data Collection Rule | Push data via Logs Ingestion API |

```bash
# Get the Function App's principal ID
PRINCIPAL_ID=$(az functionapp identity show \
  --name func-sqleditionopt \
  --resource-group rg-sqleditionopt \
  --query principalId -o tsv)

# Reader (for Resource Graph)
az role assignment create \
  --assignee "$PRINCIPAL_ID" \
  --role "Reader" \
  --scope "/subscriptions/<target-subscription-id>"

# Arc Run Command access
az role assignment create \
  --assignee "$PRINCIPAL_ID" \
  --role "Azure Connected Machine Resource Administrator" \
  --scope "/subscriptions/<target-subscription-id>"

# Logs Ingestion (scoped to DCR)
az role assignment create \
  --assignee "$PRINCIPAL_ID" \
  --role "Monitoring Metrics Publisher" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Insights/dataCollectionRules/dcr-sqleditionopt"
```

### Step 5: Deploy Function Code

```bash
cd src
func azure functionapp publish func-sqleditionopt
```

---

## Execution

### Option A: HTTP Trigger (On-Demand)

```bash
# Get function URL and key
FUNC_URL=$(az functionapp function show \
  --name func-sqleditionopt \
  --resource-group rg-sqleditionopt \
  --function-name OrchestratorFunction \
  --query invokeUrlTemplate -o tsv)

FUNC_KEY=$(az functionapp function keys list \
  --name func-sqleditionopt \
  --resource-group rg-sqleditionopt \
  --function-name OrchestratorFunction \
  --query default -o tsv)

# Run against all connected Arc machines
curl -X POST "${FUNC_URL}?code=${FUNC_KEY}" \
  -H "Content-Type: application/json" \
  -d '{}'

# Filter by subscription and tags
curl -X POST "${FUNC_URL}?code=${FUNC_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "subscriptionIds": ["<sub-id-1>", "<sub-id-2>"],
    "tagFilter": { "Environment": "Production", "Role": "SQLServer" }
  }'
```

### Option B: Timer Trigger (Scheduled)

Runs automatically — default schedule is **every Sunday at 02:00 UTC**.

Edit `src/ScheduledTrigger/function.json` to change:

```json
{ "schedule": "0 0 2 * * 0" }
```

### Option C: Local Development

```bash
cd src
func start

# Test locally
curl -X POST http://localhost:7071/api/orchestrate \
  -H "Content-Type: application/json" -d '{}'
```

---

## Querying Results in Log Analytics (KQL)

```kusto
// Instances by edition
SQLEditionOptimisation_CL
| where TimeGenerated > ago(7d)
| summarize InstanceCount = dcount(InstanceName) by Edition
| order by InstanceCount desc

// Feature usage classification
SQLEditionOptimisation_CL
| where TimeGenerated > ago(7d)
| where EnterpriseFeatures != ""
| summarize Features = make_set(EnterpriseFeatures) by InstanceName, DatabaseName

// Downgrade eligibility summary
SQLEditionOptimisation_CL
| where TimeGenerated > ago(7d)
| summarize
    Databases = dcount(DatabaseName),
    BlockedDatabases = dcountif(DatabaseName, DowngradeEligibility == "Blocked"),
    EligibleDatabases = dcountif(DatabaseName, DowngradeEligibility == "Eligible"),
    ReviewDatabases = dcountif(DatabaseName, DowngradeEligibility == "ReviewRequired")
  by InstanceName, Edition
| extend CanDowngrade = (BlockedDatabases == 0)

// Estimated savings (Enterprise vs Standard licensing)
SQLEditionOptimisation_CL
| where TimeGenerated > ago(7d)
| where DowngradeEligibility == "Eligible"
| where Edition has "Enterprise"
| distinct InstanceName, VisibleCPUs
| extend EstimatedAnnualSaving = VisibleCPUs * 3945  // Approx per-core Enterprise vs Standard delta
| summarize TotalCores = sum(VisibleCPUs), TotalEstimatedSaving = sum(EstimatedAnnualSaving)

// Failed executions
SQLEditionOptimisation_CL
| where TimeGenerated > ago(7d)
| where DowngradeEligibility == "Error"
| project TimeGenerated, MachineName, EnterpriseFeatures
```

---

## Configuration Reference

### Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `DCE_ENDPOINT` | Data Collection Endpoint URI | `https://dce-sqleditionopt.uksouth-1.ingest.monitor.azure.com` |
| `DCR_IMMUTABLE_ID` | Immutable ID of the Data Collection Rule | `dcr-abc123def456...` |
| `LOG_STREAM_NAME` | Stream name in the DCR | `Custom-SQLEditionOptimisation_CL` |
| `RESOURCE_GRAPH_QUERY` | KQL query for machine discovery | See below |

### Resource Graph Query Examples

All connected Arc machines:
```kusto
resources
| where type == 'microsoft.hybridcompute/machines'
| where properties.status == 'Connected'
| project id, name, resourceGroup, subscriptionId, location, tags
```

Only tagged SQL servers:
```kusto
resources
| where type == 'microsoft.hybridcompute/machines'
| where properties.status == 'Connected'
| where tags['Role'] == 'SQLServer'
| project id, name, resourceGroup, subscriptionId, location, tags
```

---

## Project Structure

```
SQL-Optimization/
├── infrastructure/
│   ├── main.bicep                 # Function App, Storage, App Insights (Bicep)
│   └── role-assignments.bicep     # RBAC assignments for Managed Identity
├── src/
│   ├── host.json                  # Function host configuration
│   ├── local.settings.json        # Local dev settings (not deployed)
│   ├── profile.ps1                # Managed Identity login on startup
│   ├── requirements.psd1          # Az module dependencies
│   ├── modules/
│   │   └── LogsIngestion.ps1      # Logs Ingestion API client (batched, token-based)
│   ├── OrchestratorFunction/
│   │   ├── function.json          # HTTP POST trigger
│   │   └── run.ps1                # Main orchestrator with filtering support
│   └── ScheduledTrigger/
│       ├── function.json          # Timer trigger (CRON)
│       └── run.ps1                # Scheduled variant
└── README.md
```

---

## Troubleshooting

| Issue | Resolution |
|-------|------------|
| Resource Graph returns 0 results | Verify Arc machines are **Connected**. Test query in Resource Graph Explorer. |
| 403 on Run Command | Assign **Azure Connected Machine Resource Administrator** to the MI on the target scope. |
| 403 on Logs Ingestion | Assign **Monitoring Metrics Publisher** on the **DCR** (not DCE or workspace). |
| SqlServer module not found | Run `Install-Module SqlServer -Force` on target machines. |
| `sys.dm_db_persisted_sku_features` returns empty | This is expected for Standard Edition or databases with no Enterprise features — it means the DB is eligible for downgrade. |
| Function timeout | Increase `functionTimeout` in `host.json` for large estates. Consider batching. |

---

## Limitations & Next Steps

- **Sequential processing**: For 100+ machines, consider Durable Functions fan-out/fan-in
- **Linux**: Current scripts are Windows/PowerShell. Add bash variant for Linux Arc machines
- **Power BI**: Connect Power BI directly to the Log Analytics workspace for live dashboards
- **Cost modelling**: Enhance the KQL queries with actual licensing cost data for accurate savings projections
- **Retry/resilience**: Add exponential backoff for transient Arc Run Command failures
