<#
.SYNOPSIS
    One-step deployment script for SQL Server Edition Optimisation solution.
    Clone the repo, run this script, done.

.DESCRIPTION
    This script deploys the entire solution end-to-end:
    1. Creates or validates the resource group
    2. Deploys all infrastructure via Bicep (Function App, custom table, DCE, DCR)
    3. Assigns RBAC roles to the Function App's Managed Identity
    4. Deploys the Function App code

    No CI/CD platform required. Works from any machine with Azure CLI and
    Azure Functions Core Tools installed.

.PARAMETER ResourceGroupName
    Name of the resource group to deploy into (created if it doesn't exist).

.PARAMETER Location
    Azure region for deployment. Default: uksouth.

.PARAMETER FunctionAppName
    Globally unique name for the Function App.

.PARAMETER LogAnalyticsWorkspaceId
    Full resource ID of an existing Log Analytics Workspace.

.PARAMETER TargetSubscriptionIds
    One or more subscription IDs containing the Arc-enabled machines to scan.

.EXAMPLE
    .\Deploy.ps1 `
        -ResourceGroupName "rg-sqleditionopt" `
        -FunctionAppName "func-sqleditionopt-contoso" `
        -LogAnalyticsWorkspaceId "/subscriptions/xxxx/resourceGroups/rg-monitoring/providers/Microsoft.OperationalInsights/workspaces/law-contoso" `
        -TargetSubscriptionIds @("subscription-id-1", "subscription-id-2")

.NOTES
    Prerequisites:
    - Azure CLI (az) v2.50+ installed and logged in
    - Azure Functions Core Tools (func) v4.x installed
    - Contributor role on the target resource group
    - User Access Administrator (or Owner) on target subscriptions for RBAC
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$Location = "uksouth",

    [Parameter(Mandatory)]
    [string]$FunctionAppName,

    [Parameter(Mandatory)]
    [string]$LogAnalyticsWorkspaceId,

    [Parameter(Mandatory)]
    [string[]]$TargetSubscriptionIds
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Helper Functions
function Write-Step {
    param([string]$Message)
    Write-Host "`n===================================================" -ForegroundColor Cyan
    Write-Host " $Message" -ForegroundColor Cyan
    Write-Host "===================================================" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [..] $Message" -ForegroundColor Gray
}

function Test-AzCliInstalled {
    $null = Get-Command az -ErrorAction SilentlyContinue
    if (-not $?) { throw "Azure CLI (az) is not installed. Install from: https://aka.ms/install-azure-cli" }
}

function Test-FuncCoreToolsInstalled {
    $null = Get-Command func -ErrorAction SilentlyContinue
    if (-not $?) { throw "Azure Functions Core Tools (func) is not installed. Install from: https://aka.ms/azure-functions-core-tools" }
}

function Test-AzLoggedIn {
    $account = az account show 2>$null | ConvertFrom-Json
    if (-not $account) { throw "Not logged in to Azure CLI. Run 'az login' first." }
    Write-Info "Logged in as: $($account.user.name) (Subscription: $($account.name))"
}
#endregion

#region Preflight Checks
Write-Step "Preflight Checks"

Test-AzCliInstalled
Write-Success "Azure CLI found"

Test-FuncCoreToolsInstalled
Write-Success "Azure Functions Core Tools found"

Test-AzLoggedIn

# Validate workspace exists
Write-Info "Validating Log Analytics Workspace..."
$wsCheck = az resource show --ids $LogAnalyticsWorkspaceId 2>$null
if (-not $wsCheck) { throw "Log Analytics Workspace not found: $LogAnalyticsWorkspaceId" }
Write-Success "Workspace validated"
#endregion

#region Step 1: Resource Group
Write-Step "Step 1/4: Resource Group"

$rgExists = az group exists --name $ResourceGroupName 2>$null
if ($rgExists -eq 'true') {
    Write-Info "Resource group '$ResourceGroupName' already exists"
} else {
    Write-Info "Creating resource group '$ResourceGroupName' in '$Location'..."
    az group create --name $ResourceGroupName --location $Location --output none
}
Write-Success "Resource group ready: $ResourceGroupName"
#endregion

#region Step 2: Deploy Infrastructure
Write-Step "Step 2/4: Deploy Infrastructure (Bicep)"

$scriptRoot = $PSScriptRoot
$bicepPath = Join-Path $scriptRoot "infrastructure" "main.bicep"

if (-not (Test-Path $bicepPath)) {
    throw "Bicep template not found at: $bicepPath"
}

Write-Info "Deploying Bicep template (this may take 2-3 minutes)..."

$deployOutput = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $bicepPath `
    --parameters functionAppName=$FunctionAppName `
    --parameters logAnalyticsWorkspaceId=$LogAnalyticsWorkspaceId `
    --query "properties.outputs" `
    --output json 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host $deployOutput -ForegroundColor Red
    throw "Bicep deployment failed"
}

$outputs = $deployOutput | ConvertFrom-Json
$principalId = $outputs.functionAppPrincipalId.value
$dcrResourceId = $outputs.dcrResourceId.value

Write-Success "Infrastructure deployed"
Write-Success "Function App: $FunctionAppName"
Write-Success "Managed Identity: $principalId"
Write-Success "DCR: $dcrResourceId"
#endregion

#region Step 3: RBAC Assignments
Write-Step "Step 3/4: RBAC Role Assignments"

foreach ($subId in $TargetSubscriptionIds) {
    Write-Info "Assigning roles on subscription: $subId"

    # Reader (for Resource Graph)
    az role assignment create `
        --assignee-object-id $principalId `
        --assignee-principal-type ServicePrincipal `
        --role "Reader" `
        --scope "/subscriptions/$subId" `
        --output none 2>$null
    Write-Success "  Reader assigned"

    # Arc Run Command
    az role assignment create `
        --assignee-object-id $principalId `
        --assignee-principal-type ServicePrincipal `
        --role "Azure Connected Machine Resource Administrator" `
        --scope "/subscriptions/$subId" `
        --output none 2>$null
    Write-Success "  Connected Machine Resource Administrator assigned"
}

# Monitoring Metrics Publisher on DCR
az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role "Monitoring Metrics Publisher" `
    --scope $dcrResourceId `
    --output none 2>$null
Write-Success "Monitoring Metrics Publisher assigned on DCR"
#endregion

#region Step 4: Deploy Function Code
Write-Step "Step 4/4: Deploy Function Code"

$srcPath = Join-Path $scriptRoot "src"

if (-not (Test-Path (Join-Path $srcPath "host.json"))) {
    throw "Function source not found at: $srcPath"
}

Write-Info "Publishing function code (this may take 1-2 minutes)..."
Push-Location $srcPath
try {
    $publishOutput = func azure functionapp publish $FunctionAppName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($publishOutput -join "`n") -ForegroundColor Red
        throw "Function code deployment failed"
    }
    Write-Success "Function code deployed"
} finally {
    Pop-Location
}
#endregion

#region Summary
Write-Step "Deployment Complete!"

Write-Host ""
Write-Host "  Resource Group:    $ResourceGroupName" -ForegroundColor White
Write-Host "  Function App:      $FunctionAppName" -ForegroundColor White
Write-Host "  Location:          $Location" -ForegroundColor White
Write-Host "  Target Subs:       $($TargetSubscriptionIds -join ', ')" -ForegroundColor White
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Ensure 'SqlServer' module is installed on target machines" -ForegroundColor Yellow
Write-Host "    2. Trigger a scan: POST to https://$FunctionAppName.azurewebsites.net/api/orchestrate" -ForegroundColor Yellow
Write-Host "    3. Set up Power BI (see powerbi/README-PowerBI.md)" -ForegroundColor Yellow
Write-Host ""
#endregion
