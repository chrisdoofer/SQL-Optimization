param($Timer)

<#
.SYNOPSIS
    Timer-triggered starter that queues a scan request.
    Default: Every Sunday at 02:00 UTC.
#>

Write-Host "Scheduled trigger fired at: $(Get-Date -Format 'o')"

if ($Timer.IsPastDue) {
    Write-Host "Timer is running late - executing anyway"
}

# Queue a scan request - WorkerFunction will pick it up
Push-OutputBinding -Name QueueMessage -Value '{}'
Write-Host "Scan request queued successfully"
