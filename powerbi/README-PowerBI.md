# Power BI Setup Guide - SQL Server Edition Optimisation

## Quick Start (2 minutes)

### Step 1: Open Power BI Desktop and Connect

1. Open **Power BI Desktop** (free download from Microsoft Store)
2. Click **Get Data** → **Azure** → **Azure Data Explorer (Kusto)**
3. In the connection dialog, enter:
   - **Cluster**: `https://ade.loganalytics.io/subscriptions/<subscription-id>/resourcegroups/<resource-group>/providers/microsoft.operationalinsights/workspaces`
   - **Database**: `<workspace-id>` — this is the **Workspace ID (GUID)**, NOT the workspace name
   
   > **⚠️ Important:** Do NOT include the workspace name in the Cluster URL. The Database field requires the Log Analytics **Workspace ID** (a GUID like `a1b2c3d4-e5f6-7890-abcd-ef1234567890`). Find it in: **Azure Portal → Log Analytics workspace → Properties → Workspace ID**
   
   > **Tip:** Run `powerbi\Generate-PowerBITemplate.ps1` to get your exact cluster URL, workspace ID, and queries pre-formatted.

4. Authenticate with your **Entra ID (Azure AD)** credentials
5. For the **Query**, paste the following KQL:

```kusto
SQLEditionOptimisation_CL
| where TimeGenerated > ago(30d)
| summarize arg_max(TimeGenerated, *) by MachineName, InstanceName, DatabaseName
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

### Step 5: Build Report Visuals

Below are detailed instructions for building each visual. All fields referenced come from your main dataset query loaded in Step 1.

---

#### 5a. Card Visuals — KPI Summary Row (top of page)

Create **5 card visuals** arranged horizontally across the top:

**Card 1: Machines Scanned**
1. Click a blank area of the canvas
2. In the **Visualizations** pane, click the **Card** icon (looks like a single number)
3. From the **Fields** pane, drag `MachineName` into the **Fields** well
4. In the **Fields** well dropdown, change from "Count" to **"Count (Distinct)"**
5. In the **Format** pane (paint roller icon):
   - Data label → Font size: **28**
   - Category label → Text: `Machines Scanned`
6. Resize to approximately 1/5 of page width

**Card 2: Databases Assessed**
1. Add another **Card** visual
2. Drag `DatabaseName` into the **Fields** well
3. Change aggregation to **"Count (Distinct)"**
4. Category label: `Databases Assessed`

**Card 3: Eligible to Downgrade**
1. Add another **Card** visual
2. Drag `DatabaseName` into the **Fields** well
3. Change aggregation to **"Count (Distinct)"**
4. Now add a **Visual level filter**: In the **Filters** pane (for this visual), drag `DowngradeEligibility` → set filter to **"Eligible"** only
5. Category label: `Eligible`
6. Format → Data label → Font color: **Green**

**Card 4: Review Required**
1. Add another **Card** visual
2. Drag `DatabaseName` into **Fields**, set to **"Count (Distinct)"**
3. Visual level filter: `DowngradeEligibility` = **"ReviewRequired"**
4. Category label: `Review Required`
5. Format → Data label → Font color: **Amber/Orange**

**Card 5: Total Potential Saving**
1. Add another **Card** visual
2. Drag `PotentialSavingPerYear` into the **Fields** well (it will auto-sum)
3. Format → Data label:
   - Display units: **None** (to show full number)
   - Value decimal places: **0**
   - Font size: **28**
4. Format → Category label: `Potential Annual Saving`
5. Format → Data label → Font color: **Green**

> **Tip:** Select all 5 cards → **Format** tab in ribbon → **Align** → **Distribute Horizontally** to space them evenly.

---

#### 5b. Donut Chart — Eligibility Breakdown

1. Click a blank area below the cards
2. In **Visualizations**, click the **Donut chart** icon
3. Drag `DowngradeEligibility` into the **Legend** well
4. Drag `DatabaseName` into the **Values** well → set aggregation to **"Count (Distinct)"**
5. Resize to about 1/3 page width, positioned bottom-left below the cards
6. Format colours (click the donut → Format → Data colors):
   - Eligible: **#2ECC71** (green)
   - ReviewRequired: **#F39C12** (amber)
   - Blocked: **#E74C3C** (red)
7. Format → Title → Text: `Downgrade Eligibility`
8. Format → Detail labels → Label style: **"Category, percent of total"**

---

#### 5c. Bar Chart — Enterprise Features Usage

1. Click a blank area to the right of the donut
2. In **Visualizations**, click the **Clustered bar chart** icon (horizontal bars)
3. Drag `EnterpriseFeatures` into the **Y-axis** well
4. Drag `DatabaseName` into the **X-axis** well → set to **"Count (Distinct)"**
5. Add a **Visual level filter**: `EnterpriseFeatures` → is not blank (tick all values except blank/empty)
6. Format → Title → Text: `Enterprise Features in Use`
7. Format → Data colors: all bars **#3498DB** (blue)
8. Format → X-axis title: `Number of Databases`
9. Resize to fill remaining space next to donut

---

#### 5d. Detail Table (you already have this)

1. Below the charts, add a **Table** visual
2. Drag columns in this order:
   - `MachineName`
   - `VisibleCPUs`
   - `Edition`
   - `DatabaseName`
   - `EnterpriseFeatures`
   - `HasBlockingFeatures`
   - `DowngradeEligibility`
   - `LicensedCores`
   - `PotentialSavingPerYear`
3. Format → Style: **Alternating rows**
4. Format → Conditional formatting on `DowngradeEligibility`:
   - Click the column dropdown → **Conditional formatting** → **Background color**
   - Format by: **Rules**
   - If value **contains** `Eligible` then **green** (#D5F5E3)
   - If value **contains** `ReviewRequired` then **amber** (#FEF9E7)
   - If value **contains** `Blocked` then **red** (#FADBD8)

---

#### 5e. (Optional) Slicer — Filter by Location/Resource Group

1. Add a **Slicer** visual in the top-right corner
2. Drag `ResourceGroup` into the **Field** well
3. Format → Slicer settings → Style: **Dropdown**
4. This lets users filter the entire page by resource group

---

#### Final Page Layout

```
┌──────────┬──────────┬──────────┬──────────┬──────────────┐
│ Machines │   DBs    │ Eligible │  Review  │ 💰 Saving/yr │  ← Cards
│    1     │    4     │    0     │    4     │   $0.00      │
└──────────┴──────────┴──────────┴──────────┴──────────────┘
┌─────────────────┬──────────────────────────────────────────┐
│   🍩 Donut      │   📊 Enterprise Features Bar Chart       │  ← Charts
│  Eligibility    │   DataCompression ████████ 4             │
└─────────────────┴──────────────────────────────────────────┘
┌────────────────────────────────────────────────────────────┐
│ MachineName │ CPUs │ Edition │ Database │ Features │ ... │  ← Table
│ ArcBox-SQL  │  8   │ Ent...  │ Adven..  │ DataCom. │ ... │
└────────────────────────────────────────────────────────────┘
```

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
