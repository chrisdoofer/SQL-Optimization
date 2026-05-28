using namespace System.Net

param($Request, $TriggerMetadata)

<#
.SYNOPSIS
    HTTP Trigger - Executes the SQL Edition Optimisation workflow directly.
    Discovers Arc machines, runs the analysis script, and ingests results.
    For small estates this runs synchronously; for large estates consider
    re-enabling Durable Functions orchestration.
#>

Write-Host "HttpStartFunction: Starting SQL Edition Optimisation workflow..."

try {
    # Parse input
    $payload = if ($Request.Body) {
        try { $Request.Body | ConvertFrom-Json } catch { @{} }
    } else { @{} }

    # Step 1: Discover machines via Resource Graph
    Write-Host "Step 1: Querying Resource Graph..."
    $resourceGraphQuery = $env:RESOURCE_GRAPH_QUERY
    $allMachines = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null

    do {
        $graphParams = @{
            Query = $resourceGraphQuery
            First = 1000
        }
        if ($payload.subscriptionIds) { $graphParams.Subscription = $payload.subscriptionIds }
        if ($skipToken) { $graphParams.SkipToken = $skipToken }

        $response = Search-AzGraph @graphParams
        $skipToken = $response.SkipToken
        foreach ($machine in $response.Data) { $allMachines.Add($machine) }
    } while ($skipToken)

    Write-Host "Step 1 complete: Found $($allMachines.Count) connected Arc machines"

    if ($allMachines.Count -eq 0) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = (@{ status = 'Complete'; machinesProcessed = 0; message = 'No connected Arc machines found.' } | ConvertTo-Json)
        })
        return
    }

    # Step 2: Execute Run Command on each machine
    Write-Host "Step 2: Running analysis on $($allMachines.Count) machines..."
    $results = [System.Collections.Generic.List[object]]::new()

    # DMV extraction script
    $scriptContent = if ($payload.scriptContent) { $payload.scriptContent } else { $null }

    foreach ($machine in $allMachines) {
        $machineName    = $machine.name
        $resourceGroup  = $machine.resourceGroup
        $subscriptionId = $machine.subscriptionId
        $location       = $machine.location

        Write-Host "  Processing: $machineName ($resourceGroup)"

        # Set subscription context
        try { Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null } catch {
            Write-Warning "  Failed to set context for $machineName : $($_.Exception.Message)"
            $results.Add(@{ MachineName = $machineName; ResourceGroup = $resourceGroup; SubscriptionId = $subscriptionId; Location = $location; ExecutionState = 'Failed'; Output = $null; Error = $_.Exception.Message; Timestamp = (Get-Date -Format 'o'); Attempts = 0 })
            continue
        }

        $maxRetries = 3
        $baseDelay = 5
        $attempt = 0
        $success = $false
        $lastError = $null

        while ($attempt -lt $maxRetries -and -not $success) {
            $attempt++
            try {
                $runCommandName = "sqledopt-$(Get-Date -Format 'yyyyMMddHHmmss')-$attempt"
                $cmdParams = @{
                    ResourceGroupName = $resourceGroup
                    MachineName       = $machineName
                    RunCommandName    = $runCommandName
                    Location          = $location
                    TimeoutInSecond   = 600
                }
                if ($scriptContent) { $cmdParams.SourceScript = $scriptContent }
                else {
                    # Use the default DMV script from ActivityRunCommand
                    $defaultScript = Get-Content (Join-Path $PSScriptRoot '..\ActivityRunCommand\dmv-script.ps1') -Raw -ErrorAction SilentlyContinue
                    if (-not $defaultScript) { $defaultScript = "Get-Service -Name 'MSSQL*' | Select-Object Name, Status | ConvertTo-Json" }
                    $cmdParams.SourceScript = $defaultScript
                }

                $runResult = New-AzConnectedMachineRunCommand @cmdParams
                $success = $true
                $results.Add(@{ MachineName = $machineName; ResourceGroup = $resourceGroup; SubscriptionId = $subscriptionId; Location = $location; ExecutionState = $runResult.InstanceViewExecutionState; Output = $runResult.InstanceViewOutput; Error = $runResult.InstanceViewError; Timestamp = (Get-Date -Format 'o'); Attempts = $attempt })
            }
            catch {
                $lastError = $_.Exception.Message
                Write-Warning "  Attempt $attempt/$maxRetries failed for $machineName : $lastError"
                if ($attempt -lt $maxRetries) { Start-Sleep -Seconds ($baseDelay * [Math]::Pow(2, $attempt - 1)) }
            }
        }

        if (-not $success) {
            $results.Add(@{ MachineName = $machineName; ResourceGroup = $resourceGroup; SubscriptionId = $subscriptionId; Location = $location; ExecutionState = 'Failed'; Output = $null; Error = "All $maxRetries attempts failed. Last error: $lastError"; Timestamp = (Get-Date -Format 'o'); Attempts = $attempt })
        }
    }

    Write-Host "Step 2 complete: Processed $($results.Count) machines"

    # Step 3: Ingest results to Log Analytics
    Write-Host "Step 3: Ingesting results..."
    . (Join-Path $PSScriptRoot '..\modules\LogsIngestion.ps1')

    $dceEndpoint    = $env:DCE_ENDPOINT
    $dcrImmutableId = $env:DCR_IMMUTABLE_ID
    $logStreamName  = $env:LOG_STREAM_NAME

    $logEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($result in $results) {
        if ($result.ExecutionState -ne 'Failed' -and $result.Output) {
            try {
                $parsed = if ($result.Output -is [string]) { $result.Output | ConvertFrom-Json } else { $result.Output }
                foreach ($entry in @($parsed)) {
                    $logEntries.Add(@{
                        TimeGenerated        = if ($entry.Timestamp) { $entry.Timestamp } else { $result.Timestamp }
                        MachineName          = if ($entry.MachineName) { $entry.MachineName } else { $result.MachineName }
                        InstanceName         = $entry.InstanceName; Edition = $entry.Edition
                        ProductVersion       = $entry.ProductVersion; ProductLevel = $entry.ProductLevel
                        VisibleCPUs          = $entry.VisibleCPUs; DatabaseName = $entry.DatabaseName
                        CompatibilityLevel   = $entry.CompatibilityLevel; EnterpriseFeatures = $entry.EnterpriseFeatures
                        FeatureCount         = $entry.FeatureCount; HasBlockingFeatures = $entry.HasBlockingFeatures
                        DowngradeEligibility = $entry.DowngradeEligibility
                        ResourceGroup        = $result.ResourceGroup; SubscriptionId = $result.SubscriptionId
                        Location             = $result.Location
                    })
                }
            } catch {
                $logEntries.Add(@{ TimeGenerated = $result.Timestamp; MachineName = $result.MachineName; InstanceName = 'ParseError'; Edition = 'Unknown'; EnterpriseFeatures = "PARSE_ERROR: $($_.Exception.Message)"; DowngradeEligibility = 'Error'; ResourceGroup = $result.ResourceGroup; SubscriptionId = $result.SubscriptionId; Location = $result.Location })
            }
        } elseif ($result.ExecutionState -eq 'Failed') {
            $logEntries.Add(@{ TimeGenerated = $result.Timestamp; MachineName = $result.MachineName; InstanceName = 'ExecutionFailed'; Edition = 'Unknown'; EnterpriseFeatures = "ERROR: $($result.Error)"; DowngradeEligibility = 'Error'; ResourceGroup = $result.ResourceGroup; SubscriptionId = $result.SubscriptionId; Location = $result.Location })
        }
    }

    Write-Host "  Prepared $($logEntries.Count) log entries"

    $ingestionResult = @{ Status = 'NoData'; EntriesIngested = 0 }
    if ($logEntries.Count -gt 0) {
        $ingestionResult = Send-LogsIngestion -DceEndpoint $dceEndpoint -DcrImmutableId $dcrImmutableId -StreamName $logStreamName -LogEntries $logEntries
    }

    # Summary
    $successful = ($results | Where-Object { $_.ExecutionState -ne 'Failed' }).Count
    $failed = ($results | Where-Object { $_.ExecutionState -eq 'Failed' }).Count

    $summary = @{
        status            = 'Complete'
        machinesProcessed = $allMachines.Count
        successful        = $successful
        failed            = $failed
        ingestionStatus   = $ingestionResult.Status
        timestamp         = (Get-Date -Format 'o')
    }

    Write-Host "Workflow complete: $successful successful, $failed failed"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = ($summary | ConvertTo-Json)
    })
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
