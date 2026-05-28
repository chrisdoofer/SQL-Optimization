# Power BI Setup Guide - SQL Server Edition Optimisation

## Quick Start (2 minutes)

### Step 1: Open Power BI Desktop and Connect

1. Open **Power BI Desktop** (free download from Microsoft Store)
2. Click **Get Data** → **Azure** → **Azure Data Explorer (Kusto)**
3. In the connection dialog, enter:
   - **Cluster**: `https://ade.loganalytics.io/subscriptions/<subscription-id>/resourcegroups/<resource-group>/providers/microsoft.operationalinsights/workspaces/<workspace-name>`
   - **Database**: `<workspace-name>` (same as the last segment of the cluster URL)
   
   > **Tip:** Run `powerbi\Generate-PowerBITemplate.ps1` to get your exact cluster URL and queries pre-formatted.
   
   > **Finding your values:** Azure Portal → Log Analytics workspace → Overview → Properties

4. Authenticate with your **Entra ID (Azure AD)** credentials
5. For the **Query**, paste the following KQL:

```kusto
SQLEditionOptimisation_CL
| where TimeGenerated > ago(30d)
| summarize arg_max(TimeGenerated, *) by InstanceName, DatabaseName
| project
    TimeGenerated,
    MachineName,
    InstanceName,
    Edition,
    ProductVersion,
    ProductLevel,
    VisibleCPUs = toint(VisibleCPUs),
    DatabaseName,
    CompatibilityLevel = toint(CompatibilityLevel),
    EnterpriseFeatures,
    FeatureCount = toint(FeatureCount),
    HasBlockingFeatures = tobool(HasBlockingFeatures),
    DowngradeEligibility,
    ResourceGroup,
    SubscriptionId,
    Location
```

4. Click **Load**

### Step 3: Add the Cost Model Table

1. **Get Data** → **Blank Query** → Open **Advanced Editor**
2. Paste:

```m
let
    Source = Table.FromRecords({
        [Edition = "Enterprise", PricePerTwoCorePack = 15123, PricePerCore = 7561.50, MinCores = 4, SAPercentage = 0.25],
        [Edition = "Standard", PricePerTwoCorePack = 3945, PricePerCore = 1972.50, MinCores = 4, SAPercentage = 0.25]
    }),
    Types = Table.TransformColumnTypes(Source, {
        {"PricePerTwoCorePack", type number},
        {"PricePerCore", type number},
        {"MinCores", Int64.Type},
        {"SAPercentage", type number}
    })
in
    Types
```

3. Name the query **CostModel** → Click **Close & Apply**

### Step 4: Add DAX Measures

Open `powerbi/DAX-Measures.dax` and add each measure to your model.
The key measures are:

| Measure | Purpose |
|---------|---------|
| `Estimated Annual Saving (License Only)` | Core savings from Enterprise → Standard |
| `Estimated Annual Saving with SA` | Includes Software Assurance savings |
| `Eligible for Downgrade` | Count of instances with no blocking features |
| `Eligibility Rate` | % of Enterprise instances eligible |

### Step 5: Build Report Pages

**Recommended pages:**

1. **Executive Summary**
   - Card: Total Instances, Enterprise Instances, Eligible for Downgrade
   - Card: Estimated Annual Saving
   - Donut: Eligibility breakdown (Eligible / Blocked / Review Required)

2. **Instance Detail**
   - Table: Instance, Edition, Cores, Databases, Eligibility, Features
   - Slicer: Edition, Location, ResourceGroup

3. **Cost Analysis**
   - Bar chart: Current Cost vs Projected Cost by Instance
   - Card: Total Potential Saving
   - Waterfall: Savings breakdown by instance

4. **Feature Usage**
   - Bar chart: Feature frequency across estate
   - Matrix: Instance × Feature usage

5. **Scan History**
   - Line chart: Machines scanned over time
   - Line chart: Eligibility trend

### Step 6: Save and Share as Template

1. **File** → **Export** → **Power BI Template (.pbit)**
2. When prompted, add a description: *"SQL Server Edition Optimisation — Enter your Log Analytics cluster URL"*
3. Share the `.pbit` file — recipients open it, enter their cluster URL, authenticate, and the report loads immediately

> **Note:** A `.pbit` template can only be created from within Power BI Desktop — it cannot be generated programmatically. Once you've built your report, export it as a template to share with other consumers.

---

## Prerequisites for Consumers

### RBAC Requirements

Any user opening this report needs:

| Role | Scope | Purpose |
|------|-------|---------|
| **Log Analytics Reader** | Log Analytics Workspace | Read query results |

Assign via:
```bash
az role assignment create \
  --assignee "<user-email-or-objectid>" \
  --role "Log Analytics Reader" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace>"
```

### Authentication

- Users authenticate via **Entra ID** (Azure AD) — no service accounts or API keys
- The Power BI Log Analytics connector uses delegated permissions
- No additional app registrations required

### Software Required

- [Power BI Desktop](https://powerbi.microsoft.com/desktop/) (free)
- Entra ID account with workspace access

---

## SQL Server 2022 Pricing (Embedded in Cost Model)

| Edition | Per 2-Core Pack | Per Core | Min Cores |
|---------|----------------|----------|-----------|
| **Enterprise** | $15,123 | $7,561.50 | 4 |
| **Standard** | $3,945 | $1,972.50 | 4 |

**Saving per core on downgrade: $5,589.00**

- Licences sold in 2-core packs
- Minimum 4 cores per physical processor
- Software Assurance: ~25% of licence cost per annum

Source: [Microsoft SQL Server 2022 Pricing](https://www.microsoft.com/en-us/sql-server/sql-server-2022-pricing)

---

## Alternative: KQL Queries for Ad-Hoc Analysis

If you don't need Power BI, use the queries in `powerbi/KQL-Queries.kql` directly in:
- Azure Portal → Log Analytics → Logs
- Azure Data Explorer web UI
- Azure Workbooks
