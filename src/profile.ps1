# Azure Functions profile.ps1
# Authenticate with Managed Identity on function app startup
if ($env:IDENTITY_ENDPOINT) {
    try {
        Disable-AzContextAutosave -Scope Process | Out-Null
        Connect-AzAccount -Identity -WarningAction SilentlyContinue -ErrorAction Stop | Out-Null
        Write-Host "Connected to Azure using Managed Identity"
    }
    catch {
        Write-Host "WARNING: Managed Identity connection failed: $($_.Exception.Message)"
    }
}
