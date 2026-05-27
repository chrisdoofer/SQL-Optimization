# Azure Functions profile.ps1
# Authenticate with Managed Identity on function app startup
if ($env:MSI_SECRET) {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity | Out-Null
    Write-Host "Connected to Azure using Managed Identity"
}
