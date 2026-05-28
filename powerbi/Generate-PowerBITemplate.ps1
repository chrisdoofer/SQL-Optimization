<#
.SYNOPSIS
    Generates Power Query M scripts for the SQL Edition Optimisation Power BI report.

.DESCRIPTION
    Run this script to generate ready-to-paste M (Power Query) expressions for Power BI.
    The output uses the Azure Data Explorer (Kusto) connector to query Log Analytics.

    After running, open Power BI Desktop → Get Data → Blank Query → Advanced Editor
    and paste the generated M expressions.

.PARAMETER SubscriptionId
    Azure subscription ID containing the Log Analytics workspace.

.PARAMETER ResourceGroupName
    Resource group name containing the Log Analytics workspace.

.PARAMETER WorkspaceName
    Log Analytics workspace name.

.EXAMPLE
    .\Generate-PowerBITemplate.ps1 -SubscriptionId "xxxx" -ResourceGroupName "rg-sqleditionopt" -WorkspaceName "func-sqleditionopt-doofer-law"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$WorkspaceName
)

$clusterUrl = "https://ade.loganalytics.io/subscriptions/$SubscriptionId/resourcegroups/$ResourceGroupName/providers/microsoft.operationalinsights/workspaces/$WorkspaceName"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Power BI Setup - SQL Server Edition Optimisation" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Connector: Azure Data Explorer (Kusto)" -ForegroundColor Yellow
Write-Host "Cluster:   $clusterUrl" -ForegroundColor White
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " QUERY 1: SQLEditionData (Main Data)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Get Data → Azure Data Explorer (Kusto)" -ForegroundColor Gray
Write-Host " Paste the Cluster URL above, leave Database blank" -ForegroundColor Gray
Write-Host " Paste this KQL in the Query box:" -ForegroundColor Gray
Write-Host ""

$mainQuery = @"
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
"@

Write-Host $mainQuery -ForegroundColor Green
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " QUERY 2: CostModel (Blank Query → Advanced Editor)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

$costModelQuery = @"
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
"@

Write-Host $costModelQuery -ForegroundColor Green
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Next Steps" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Create both queries above in Power BI Desktop" -ForegroundColor White
Write-Host "  2. Add DAX measures from powerbi/DAX-Measures.dax" -ForegroundColor White
Write-Host "  3. Build visuals (see README-PowerBI.md for layout guide)" -ForegroundColor White
Write-Host "  4. Save as template: File → Export → Power BI Template (.pbit)" -ForegroundColor White
Write-Host "     Share the .pbit with consumers — they just re-enter the cluster URL" -ForegroundColor White
Write-Host ""

# Save to file for easy reference
$outputPath = Join-Path $PSScriptRoot "PowerBI-Connection-Details.txt"
@"
SQL Server Edition Optimisation - Power BI Connection Details
=============================================================

Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Connector: Azure Data Explorer (Kusto)
Cluster URL: $clusterUrl
Database: (leave blank)
Authentication: Entra ID (Azure AD)

KQL Query (main data):
$mainQuery

Cost Model (Blank Query → Advanced Editor):
$costModelQuery
"@ | Out-File -FilePath $outputPath -Encoding UTF8

Write-Host "  Connection details saved to: $outputPath" -ForegroundColor Gray
Write-Host ""
