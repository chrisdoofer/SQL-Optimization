param($Input)

<#
.SYNOPSIS
    Activity Function - Ingests all collected results into Log Analytics
    via the Logs Ingestion API. Handles batching for large result sets.
#>

. "$PSScriptRoot\..\modules\LogsIngestion.ps1"

$payload = $Input | ConvertFrom-Json
$results = $payload.results

$dceEndpoint    = $env:DCE_ENDPOINT
$dcrImmutableId = $env:DCR_IMMUTABLE_ID
$logStreamName  = $env:LOG_STREAM_NAME

$logEntries = [System.Collections.Generic.List[object]]::new()

foreach ($result in $results) {
    if ($result.ExecutionState -ne 'Failed' -and $result.Output) {
        try {
            $parsed = if ($result.Output -is [string]) { $result.Output | ConvertFrom-Json } else { $result.Output }
            foreach ($entry in $parsed) {
                $logEntries.Add(@{
                    TimeGenerated        = if ($entry.Timestamp) { $entry.Timestamp } else { $result.Timestamp }
                    MachineName          = if ($entry.MachineName) { $entry.MachineName } else { $result.MachineName }
                    InstanceName         = $entry.InstanceName
                    Edition              = $entry.Edition
                    ProductVersion       = $entry.ProductVersion
                    ProductLevel         = $entry.ProductLevel
                    VisibleCPUs          = $entry.VisibleCPUs
                    DatabaseName         = $entry.DatabaseName
                    CompatibilityLevel   = $entry.CompatibilityLevel
                    EnterpriseFeatures   = $entry.EnterpriseFeatures
                    FeatureCount         = $entry.FeatureCount
                    HasBlockingFeatures  = $entry.HasBlockingFeatures
                    DowngradeEligibility = $entry.DowngradeEligibility
                    ResourceGroup        = $result.ResourceGroup
                    SubscriptionId       = $result.SubscriptionId
                    Location             = $result.Location
                })
            }
        } catch {
            $logEntries.Add(@{
                TimeGenerated        = $result.Timestamp
                MachineName          = $result.MachineName
                InstanceName         = 'ParseError'
                Edition              = 'Unknown'
                ProductVersion       = 'Unknown'
                ProductLevel         = 'Unknown'
                VisibleCPUs          = 0
                DatabaseName         = 'N/A'
                CompatibilityLevel   = 0
                EnterpriseFeatures   = "PARSE_ERROR: $($_.Exception.Message)"
                FeatureCount         = 0
                HasBlockingFeatures  = $false
                DowngradeEligibility = 'Error'
                ResourceGroup        = $result.ResourceGroup
                SubscriptionId       = $result.SubscriptionId
                Location             = $result.Location
            })
        }
    } elseif ($result.ExecutionState -eq 'Failed') {
        $logEntries.Add(@{
            TimeGenerated        = $result.Timestamp
            MachineName          = $result.MachineName
            InstanceName         = 'ExecutionFailed'
            Edition              = 'Unknown'
            ProductVersion       = 'Unknown'
            ProductLevel         = 'Unknown'
            VisibleCPUs          = 0
            DatabaseName         = 'N/A'
            CompatibilityLevel   = 0
            EnterpriseFeatures   = "ERROR: $($result.Error)"
            FeatureCount         = 0
            HasBlockingFeatures  = $false
            DowngradeEligibility = 'Error'
            ResourceGroup        = $result.ResourceGroup
            SubscriptionId       = $result.SubscriptionId
            Location             = $result.Location
        })
    }
}

Write-Host "ActivityIngestLogs: Ingesting $($logEntries.Count) entries"

if ($logEntries.Count -eq 0) {
    return @{ Status = 'NoData'; EntriesIngested = 0 }
}

$ingestionResult = Send-LogsIngestion `
    -DceEndpoint $dceEndpoint `
    -DcrImmutableId $dcrImmutableId `
    -StreamName $logStreamName `
    -LogEntries $logEntries

return @{
    Status          = $ingestionResult.Status
    EntriesIngested = $logEntries.Count
    BatchesSent     = $ingestionResult.BatchesSent
    Errors          = $ingestionResult.Errors
}
