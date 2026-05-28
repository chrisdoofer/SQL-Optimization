using namespace System.Net

param($Request, $TriggerMetadata)

<#
.SYNOPSIS
    HTTP Starter - Kicks off the Durable Orchestrator for SQL Edition Optimisation.
    Returns a management payload with status/termination URLs.
#>

Write-Host "HttpStartFunction: Script starting..."

try {
    # Check if Durable SDK is available
    $durableCmd = Get-Command 'Start-DurableOrchestration' -ErrorAction SilentlyContinue
    if (-not $durableCmd) {
        throw "Start-DurableOrchestration cmdlet not found. Durable SDK may not be installed. Check requirements.psd1 and ExternalDurablePowerShellSDK app setting."
    }

    $body = if ($Request.Body) { $Request.Body | ConvertTo-Json -Depth 10 -Compress } else { '{}' }
    Write-Host "HttpStartFunction: Starting orchestration with body: $body"

    $instanceId = Start-DurableOrchestration -FunctionName 'DurableOrchestrator' -InputObject $body
    Write-Host "HttpStartFunction: Started orchestration with ID = '$instanceId'"

    $response = New-DurableOrchestrationCheckStatusResponse -Request $Request -InstanceId $instanceId
    Push-OutputBinding -Name Response -Value $response
}
catch {
    Write-Host "HttpStartFunction ERROR: $($_.Exception.Message)"
    Write-Host "HttpStartFunction STACK: $($_.ScriptStackTrace)"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{ error = $_.Exception.Message; stack = $_.ScriptStackTrace } | ConvertTo-Json)
    })
}
