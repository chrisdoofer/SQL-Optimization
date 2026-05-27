<#
.SYNOPSIS
    Shared module for Azure Monitor Logs Ingestion API.

.DESCRIPTION
    Sends log entries to a custom table in Log Analytics via the
    Data Collection Endpoint (DCE) and Data Collection Rule (DCR).
    Uses Managed Identity for authentication.
#>

function Send-LogsIngestion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DceEndpoint,

        [Parameter(Mandatory)]
        [string]$DcrImmutableId,

        [Parameter(Mandatory)]
        [string]$StreamName,

        [Parameter(Mandatory)]
        [array]$LogEntries,

        [int]$BatchSize = 500
    )

    # Acquire token for Azure Monitor ingestion scope using Managed Identity
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://monitor.azure.com/" -ErrorAction Stop
    $accessToken = $tokenResponse.Token

    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type"  = "application/json"
    }

    $uri = "$DceEndpoint/dataCollectionRules/$DcrImmutableId/streams/${StreamName}?api-version=2023-01-01"

    $results = @{
        Status       = 'Success'
        TotalEntries = $LogEntries.Count
        BatchesSent  = 0
        Errors       = @()
    }

    # Send in batches to respect API limits (1MB per request)
    for ($i = 0; $i -lt $LogEntries.Count; $i += $BatchSize) {
        $batch = $LogEntries[$i..([Math]::Min($i + $BatchSize - 1, $LogEntries.Count - 1))]
        $jsonBody = $batch | ConvertTo-Json -Depth 10 -AsArray

        # Check payload size (max 1MB)
        $bodyBytes = [System.Text.Encoding]::UTF8.GetByteCount($jsonBody)
        if ($bodyBytes -gt 1048576) {
            # Split batch in half and retry
            $halfSize = [Math]::Floor($batch.Count / 2)
            $firstHalf = $batch[0..($halfSize - 1)] | ConvertTo-Json -Depth 10 -AsArray
            $secondHalf = $batch[$halfSize..($batch.Count - 1)] | ConvertTo-Json -Depth 10 -AsArray

            try {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $firstHalf -ErrorAction Stop
                $results.BatchesSent++
            } catch {
                $results.Errors += "Batch $($results.BatchesSent + 1) (first half): $($_.Exception.Message)"
                $results.Status = 'PartialFailure'
            }

            try {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $secondHalf -ErrorAction Stop
                $results.BatchesSent++
            } catch {
                $results.Errors += "Batch $($results.BatchesSent + 1) (second half): $($_.Exception.Message)"
                $results.Status = 'PartialFailure'
            }
        } else {
            try {
                Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $jsonBody -ErrorAction Stop
                $results.BatchesSent++
            } catch {
                $results.Errors += "Batch $($results.BatchesSent + 1): $($_.Exception.Message)"
                $results.Status = 'PartialFailure'
            }
        }
    }

    if ($results.Errors.Count -eq $results.BatchesSent + $results.Errors.Count -and $results.Errors.Count -gt 0) {
        $results.Status = 'Failed'
    }

    return $results
}

function Get-FormattedLogEntry {
    <#
    .SYNOPSIS
        Formats a hashtable into a log entry with required TimeGenerated field.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Entry
    )

    if (-not $Entry.ContainsKey('TimeGenerated')) {
        $Entry['TimeGenerated'] = (Get-Date -Format 'o')
    }

    return $Entry
}
