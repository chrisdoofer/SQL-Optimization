param($Timer)

<#
.SYNOPSIS
    Timer-triggered starter that kicks off the SQL Edition Optimisation workflow.
    Default: Every Sunday at 02:00 UTC.
    Calls the HTTP endpoint to trigger the workflow.
#>

Write-Host "Scheduled trigger fired at: $(Get-Date -Format 'o')"

if ($Timer.IsPastDue) {
    Write-Host "Timer is running late - executing anyway"
}

# Trigger the HTTP function internally
$functionAppUrl = "http://localhost/api/orchestrate"
try {
    $result = Invoke-RestMethod -Uri $functionAppUrl -Method Post -ContentType 'application/json' -Body '{}' -ErrorAction Stop
    Write-Host "Scheduled workflow completed: $($result | ConvertTo-Json -Compress)"
} catch {
    Write-Host "Scheduled workflow failed: $($_.Exception.Message)"
}
