param($Context)

<#
.SYNOPSIS
    Durable Orchestrator - Fan-out/Fan-in pattern for large-scale SQL Edition analysis.
    Designed to handle 100+ Arc-enabled servers by parallelising Run Command execution.

.DESCRIPTION
    1. Discovers Arc machines via Resource Graph (single activity)
    2. Fans out: one activity per machine to execute DMV scripts via Run Command
    3. Fans in: collects all results
    4. Batches results into the Logs Ingestion API
#>

$input = $Context.Input | ConvertFrom-Json

# Step 1: Discover machines via Resource Graph
$machines = Invoke-DurableActivity -FunctionName 'ActivityDiscoverMachines' -Input $input

Write-Host "Orchestrator: Discovered $($machines.Count) machines. Fanning out..."

if ($machines.Count -eq 0) {
    return @{ status = 'Complete'; machinesProcessed = 0; message = 'No connected Arc machines found.' }
}

# Step 2: Fan-out — execute Run Command on each machine in parallel
$parallelTasks = @()
foreach ($machine in $machines) {
    $taskInput = @{
        machine       = $machine
        scriptContent = $input.scriptContent
    } | ConvertTo-Json -Depth 5

    $parallelTasks += Invoke-DurableActivity -FunctionName 'ActivityRunCommand' -Input $taskInput -NoWait
}

# Wait for all parallel activities to complete
$results = Wait-DurableTask -Task $parallelTasks

Write-Host "Orchestrator: All $($results.Count) Run Command activities completed. Ingesting logs..."

# Step 3: Fan-in — batch ingest results to Log Analytics
$ingestionInput = @{
    results = $results
} | ConvertTo-Json -Depth 10

$ingestionResult = Invoke-DurableActivity -FunctionName 'ActivityIngestLogs' -Input $ingestionInput

# Summary
$successful = ($results | Where-Object { $_.ExecutionState -ne 'Failed' }).Count
$failed = ($results | Where-Object { $_.ExecutionState -eq 'Failed' }).Count

return @{
    status            = 'Complete'
    machinesProcessed = $machines.Count
    successful        = $successful
    failed            = $failed
    ingestionStatus   = $ingestionResult.Status
    timestamp         = (Get-Date -Format 'o')
}
