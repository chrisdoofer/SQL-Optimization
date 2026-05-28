using namespace System.Net

param($Request, $TriggerMetadata)

<#
.SYNOPSIS
    HTTP Starter - Kicks off the Durable Orchestrator for SQL Edition Optimisation.
    Returns a management payload with status/termination URLs.
#>

$body = $Request.Body | ConvertTo-Json -Depth 10

$instanceId = Start-NewOrchestration -FunctionName 'DurableOrchestrator' -InputObject $body
Write-Host "Started orchestration with ID = '$instanceId'"

$response = New-OrchestrationCheckStatusResponse -Request $Request -InstanceId $instanceId
Push-OutputBinding -Name Response -Value $response
