<#
.SYNOPSIS
    One-step deployment script for SQL Server Edition Optimisation solution.
    Clone the repo, run this script, done.

.DESCRIPTION
    This script deploys the entire solution end-to-end:
    1. Creates or validates the resource group (in the dedicated deployment subscription)
    2. Deploys all infrastructure via Bicep (Function App, custom table, DCE, DCR)
    3. Assigns RBAC roles at Management Group scope (covers all child subscriptions)
    4. Deploys the Function App code

    RBAC at Management Group level means:
    - No need to list individual subscriptions
    - Automatically covers future subscriptions added to the management group
    - The Function App discovers Arc machines across ALL child subscriptions via Resource Graph

    No CI/CD platform required. Works from any machine with Azure CLI and
    Azure Functions Core Tools installed.

.PARAMETER ResourceGroupName
    Name of the resource group to deploy into (created if it doesn't exist).

.PARAMETER Location
    Azure region for deployment. Default: uksouth.

.PARAMETER FunctionAppName
    Globally unique name for the Function App.

.PARAMETER DeploymentSubscriptionId
    Subscription ID where the Function App infrastructure is deployed.
    This should be a dedicated subscription for the tooling.

.PARAMETER LogAnalyticsWorkspaceName
    Name for the Log Analytics Workspace. Created by the deployment if it doesn't exist.
    Defaults to '<FunctionAppName>-law'.

.PARAMETER ManagementGroupId
    Management Group ID to assign RBAC roles on. The Function App's Managed Identity
    will receive Reader and Arc Run Command roles at this scope, giving it access to
    all Arc-enabled servers in any child subscription.
    If not specified, defaults to the Tenant Root Management Group.

.EXAMPLE
    # Deploy with RBAC at a specific management group
    .\Deploy.ps1 `
        -DeploymentSubscriptionId "xxxx-xxxx-xxxx" `
        -ResourceGroupName "rg-sqleditionopt" `
        -FunctionAppName "func-sqleditionopt-contoso" `
        -ManagementGroupId "mg-production"

.EXAMPLE
    # Deploy with RBAC at Tenant Root (scans entire tenant)
    .\Deploy.ps1 `
        -DeploymentSubscriptionId "xxxx-xxxx-xxxx" `
        -ResourceGroupName "rg-sqleditionopt" `
        -FunctionAppName "func-sqleditionopt-contoso"

.NOTES
    Prerequisites:
    - Azure CLI (az) v2.50+ installed and logged in
    - Azure Functions Core Tools (func) v4.x installed
    - Contributor on the deployment subscription/resource group
    - User Access Administrator (or Owner) at the Management Group scope for RBAC
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$DeploymentSubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$Location = "uksouth",

    [Parameter(Mandatory)]
    [string]$FunctionAppName,

    [Parameter()]
    [string]$LogAnalyticsWorkspaceName,

    [Parameter()]
    [string]$ManagementGroupId
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

# Set the deployment subscription context
Write-Info "Setting subscription context to: $DeploymentSubscriptionId"
az account set --subscription $DeploymentSubscriptionId --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription context. Check the DeploymentSubscriptionId." }
Write-Success "Subscription context set"

# Resolve Management Group
if (-not $ManagementGroupId) {
    Write-Info "No ManagementGroupId specified — resolving Tenant Root Management Group..."
    $tenantId = (az account show --query tenantId -o tsv)
    $ManagementGroupId = $tenantId
    Write-Info "Using Tenant Root Management Group: $ManagementGroupId"
}

$mgScope = "/providers/Microsoft.Management/managementGroups/$ManagementGroupId"
Write-Success "RBAC scope: $mgScope"
#endregion

#region Step 1: Resource Group
Write-Step "Step 1/5: Resource Group"

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
Write-Step "Step 2/5: Deploy Infrastructure (Bicep)"

$scriptRoot = $PSScriptRoot
$bicepPath = Join-Path $scriptRoot "infrastructure" "main.bicep"

if (-not (Test-Path $bicepPath)) {
    throw "Bicep template not found at: $bicepPath"
}

Write-Info "Deploying Bicep template (this may take 2-3 minutes)..."

$bicepParams = "functionAppName=$FunctionAppName"
if ($LogAnalyticsWorkspaceName) {
    $bicepParams += " logAnalyticsWorkspaceName=$LogAnalyticsWorkspaceName"
}

$deployOutput = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file $bicepPath `
    --parameters $bicepParams `
    --query "properties.outputs" `
    --output json 2>$null

if ($LASTEXITCODE -ne 0) {
    # Re-run to capture error message
    $errorOutput = az deployment group create `
        --resource-group $ResourceGroupName `
        --template-file $bicepPath `
        --parameters $bicepParams `
        --output json 2>&1
    Write-Host ($errorOutput -join "`n") -ForegroundColor Red
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
Write-Step "Step 3/5: RBAC Role Assignments (Management Group scope)"

Write-Info "Assigning roles at: $mgScope"
Write-Info "This gives the Function App access to ALL Arc machines in child subscriptions"

# Reader (for Resource Graph across all child subscriptions)
Write-Info "Assigning Reader..."
az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role "Reader" `
    --scope $mgScope `
    --output none 2>$null
Write-Success "Reader assigned at Management Group scope"

# Arc Run Command (execute commands on any Arc machine in scope)
Write-Info "Assigning Azure Connected Machine Resource Administrator..."
az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role "Azure Connected Machine Resource Administrator" `
    --scope $mgScope `
    --output none 2>$null
Write-Success "Connected Machine Resource Administrator assigned at Management Group scope"

# Monitoring Metrics Publisher on DCR (scoped to DCR only — least privilege)
Write-Info "Assigning Monitoring Metrics Publisher on DCR..."
az role assignment create `
    --assignee-object-id $principalId `
    --assignee-principal-type ServicePrincipal `
    --role "Monitoring Metrics Publisher" `
    --scope $dcrResourceId `
    --output none 2>$null
Write-Success "Monitoring Metrics Publisher assigned on DCR"
#endregion

#region Step 4: Deploy Function Code
Write-Step "Step 4/5: Deploy Function Code"

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

#region Step 5: Trigger Initial Scan
Write-Step "Step 5/5: Triggering Initial Scan"

Write-Info "Waiting 30 seconds for Function App to warm up..."
Start-Sleep -Seconds 30

$triggerUrl = "https://$FunctionAppName.azurewebsites.net/api/orchestrate"
Write-Info "Triggering scan: POST $triggerUrl"

$maxRetries = 3
$retryCount = 0
$triggered = $false

while (-not $triggered -and $retryCount -lt $maxRetries) {
    try {
        $response = Invoke-RestMethod -Uri $triggerUrl -Method Post -ContentType 'application/json' -Body '{}' -ErrorAction Stop
        $triggered = $true
        Write-Success "Initial scan triggered successfully"
        if ($response.id) {
            Write-Info "Orchestration ID: $($response.id)"
            Write-Info "Status URL: $($response.statusQueryGetUri)"
        }
    } catch {
        $retryCount++
        if ($retryCount -lt $maxRetries) {
            Write-Info "Function App not ready yet, retrying in 15 seconds... (attempt $retryCount/$maxRetries)"
            Start-Sleep -Seconds 15
        } else {
            Write-Host "  [WARN] Could not trigger initial scan automatically." -ForegroundColor Yellow
            Write-Host "         The Function App may still be starting. Trigger manually:" -ForegroundColor Yellow
            Write-Host "         POST $triggerUrl" -ForegroundColor Yellow
        }
    }
}
#endregion

#region Summary
Write-Step "Deployment Complete!"

Write-Host ""
Write-Host "  Resource Group:      $ResourceGroupName" -ForegroundColor White
Write-Host "  Function App:        $FunctionAppName" -ForegroundColor White
Write-Host "  Location:            $Location" -ForegroundColor White
Write-Host "  Deployment Sub:      $DeploymentSubscriptionId" -ForegroundColor White
Write-Host "  Log Analytics:       $($outputs.logAnalyticsWorkspaceName.value)" -ForegroundColor White
Write-Host "  Management Group:    $ManagementGroupId" -ForegroundColor White
Write-Host "  RBAC Scope:          $mgScope" -ForegroundColor White
Write-Host ""
Write-Host "  The Function App can now discover and scan Arc-enabled SQL Servers" -ForegroundColor Green
Write-Host "  across ALL subscriptions under: $ManagementGroupId" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Yellow
Write-Host "    1. Monitor scan progress in Azure Portal (Function App > Monitor)" -ForegroundColor Yellow
Write-Host "    2. Set up Power BI (see powerbi/README-PowerBI.md)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  On-demand trigger (future scans):" -ForegroundColor Cyan
Write-Host "    POST https://$FunctionAppName.azurewebsites.net/api/orchestrate" -ForegroundColor Cyan
Write-Host "  Scheduled: Automatic weekly scan every Sunday at 02:00 UTC" -ForegroundColor Cyan
Write-Host ""
#endregion
