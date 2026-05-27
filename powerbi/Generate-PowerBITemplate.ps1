<#
.SYNOPSIS
    Generates a Power BI Template (.pbit) file for SQL Edition Optimisation.

.DESCRIPTION
    Run this script to generate the .pbit file. The template connects to your
    Log Analytics workspace using Entra ID authentication and includes:
    - Edition breakdown dashboard
    - Enterprise feature usage analysis
    - Downgrade eligibility summary
    - Cost savings estimation (SQL Server 2022 pricing)

.PARAMETER WorkspaceId
    Log Analytics Workspace ID (GUID). Leave blank to be prompted on first use.

.EXAMPLE
    .\Generate-PowerBITemplate.ps1
#>

# Power BI template uses M (Power Query) expressions that connect to Log Analytics
# The template will prompt for WorkspaceId on first open

$templateDefinition = @{
    Version = "1.0"
    Description = "SQL Server Edition Optimisation - Downgrade Eligibility Analysis"
    Parameters = @(
        @{
            Name = "WorkspaceId"
            Type = "Text"
            Description = "Your Log Analytics Workspace ID (GUID)"
            Required = $true
        }
    )
    Queries = @(
        @{
            Name = "SQLEditionData"
            Description = "Raw edition optimisation data from Log Analytics"
            MExpression = @'
let
    WorkspaceId = #"WorkspaceId",
    Source = AzureDataExplorer.Contents("https://api.loganalytics.io/v1/workspaces/" & WorkspaceId & "/query", null, null),
    Query = "SQLEditionOptimisation_CL
| where TimeGenerated > ago(30d)
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
| order by TimeGenerated desc",
    Result = Json.Document(Web.Contents("https://api.loganalytics.io/v1/workspaces/" & WorkspaceId & "/query", [Content=Text.ToBinary("{""query"":""" & Query & """}"), Headers=[#"Content-Type"="application/json"]]))
in
    Result
'@
        }
        @{
            Name = "CostModel"
            Description = "SQL Server 2022 licensing cost model"
            MExpression = @'
let
    Source = Table.FromRecords({
        [Edition = "Enterprise", PricePerTwoCorePack = 15123, PricePerCore = 7561.50, MinCores = 4],
        [Edition = "Standard", PricePerTwoCorePack = 3945, PricePerCore = 1972.50, MinCores = 4]
    }),
    Types = Table.TransformColumnTypes(Source, {
        {"PricePerTwoCorePack", type number},
        {"PricePerCore", type number},
        {"MinCores", Int64.Type}
    })
in
    Types
'@
        }
    )
}

$templateDefinition | ConvertTo-Json -Depth 10 | Out-File -FilePath "$PSScriptRoot\template-definition.json" -Encoding UTF8
Write-Host "Template definition saved. See README for Power BI setup instructions."
