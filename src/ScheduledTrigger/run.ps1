param($Timer)

<#
.SYNOPSIS
    Timer-triggered starter that kicks off the Durable Orchestrator.
    Default: Every Sunday at 02:00 UTC.
#>

Write-Host "Scheduled trigger fired at: $(Get-Date -Format 'o')"

if ($Timer.IsPastDue) {
    Write-Host "Timer is running late - executing anyway"
}

# Start the durable orchestration with no filters (process all machines)
$input = @{} | ConvertTo-Json

$instanceId = Start-DurableOrchestration -FunctionName 'DurableOrchestrator' -InputObject $input
Write-Host "Started scheduled orchestration with ID = '$instanceId'"
