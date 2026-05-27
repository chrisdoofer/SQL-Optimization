using namespace System.Net

param($Request, $TriggerMetadata)

<#
.SYNOPSIS
    Orchestrator Function - Discovers SQL Server instances on Arc-enabled servers
    via Resource Graph, executes DMV queries to detect Enterprise feature usage,
    and ingests results into Log Analytics via the Logs Ingestion API.

.DESCRIPTION
    This function supports SQL Server Edition Optimisation by:
    1. Querying Azure Resource Graph for Arc-enabled SQL Server instances
    2. Executing DMV scripts via Arc Run Command to detect Enterprise-only features
    3. Collecting structured results centrally
    4. Pushing data to Log Analytics via the Logs Ingestion API
    5. Enabling downstream analysis (KQL/Power BI) for downgrade eligibility
#>

# Import shared module
. "$PSScriptRoot\..\modules\LogsIngestion.ps1"

#region Configuration
$resourceGraphQuery = $env:RESOURCE_GRAPH_QUERY
$dceEndpoint        = $env:DCE_ENDPOINT
$dcrImmutableId     = $env:DCR_IMMUTABLE_ID
$logStreamName      = $env:LOG_STREAM_NAME
#endregion

#region Input Validation
$body = $Request.Body

# Allow optional filters from the request body
$subscriptionFilter = $body.subscriptionIds   # Array of subscription IDs to scope
$tagFilter          = $body.tagFilter         # e.g., @{ "Environment" = "Production" }
$scriptContent      = $body.scriptContent     # Custom script to run (optional)

# Default script: Detect Enterprise-only feature usage via DMVs
if (-not $scriptContent) {
    $scriptContent = @'
# SQL Server Edition Optimisation - Enterprise Feature Detection
# Identifies Enterprise-only features in use via sys.dm_db_persisted_sku_features
# and collects edition/version metadata for downgrade eligibility analysis.
$ErrorActionPreference = 'Continue'
$results = @()

try {
    Import-Module SqlServer -ErrorAction Stop

    $instances = Get-Service -Name 'MSSQL*' | Where-Object { $_.Status -eq 'Running' }

    foreach ($svc in $instances) {
        $instanceName = if ($svc.Name -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$($svc.Name -replace 'MSSQL\$','')" }

        # Collect instance-level metadata
        $instanceInfo = Invoke-Sqlcmd -ServerInstance $instanceName -Query "
            SELECT
                SERVERPROPERTY('MachineName') AS MachineName,
                SERVERPROPERTY('ServerName') AS ServerName,
                SERVERPROPERTY('InstanceName') AS InstanceName,
                SERVERPROPERTY('Edition') AS Edition,
                SERVERPROPERTY('ProductVersion') AS ProductVersion,
                SERVERPROPERTY('ProductLevel') AS ProductLevel,
                SERVERPROPERTY('ProductMajorVersion') AS MajorVersion,
                SERVERPROPERTY('LicenseType') AS LicenseType,
                SERVERPROPERTY('NumLicenses') AS NumLicenses,
                (SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE') AS VisibleCPUs
        " -ErrorAction Stop

        # Get databases
        $databases = Invoke-Sqlcmd -ServerInstance $instanceName -Query "
            SELECT name, database_id, compatibility_level, state_desc
            FROM sys.databases
            WHERE state_desc = 'ONLINE'
            AND name NOT IN ('master','tempdb','model','msdb')
        " -ErrorAction Stop

        foreach ($db in $databases) {
            # Core check: Enterprise-only persisted SKU features
            $enterpriseFeatures = Invoke-Sqlcmd -ServerInstance $instanceName -Database $db.name -Query "
                SELECT
                    DB_NAME() AS DatabaseName,
                    feature_name AS FeatureName,
                    feature_id AS FeatureId
                FROM sys.dm_db_persisted_sku_features
            " -ErrorAction SilentlyContinue

            # Additional checks for common Enterprise features
            $compressionUsage = Invoke-Sqlcmd -ServerInstance $instanceName -Database $db.name -Query "
                SELECT
                    OBJECT_SCHEMA_NAME(object_id) AS SchemaName,
                    OBJECT_NAME(object_id) AS TableName,
                    data_compression_desc AS CompressionType
                FROM sys.partitions
                WHERE data_compression > 0
            " -ErrorAction SilentlyContinue

            $partitionUsage = Invoke-Sqlcmd -ServerInstance $instanceName -Database $db.name -Query "
                SELECT
                    OBJECT_SCHEMA_NAME(p.object_id) AS SchemaName,
                    OBJECT_NAME(p.object_id) AS TableName,
                    COUNT(DISTINCT p.partition_number) AS PartitionCount
                FROM sys.partitions p
                WHERE p.partition_number > 1
                GROUP BY p.object_id
            " -ErrorAction SilentlyContinue

            # Determine downgrade eligibility
            $hasEnterpriseFeatures = ($enterpriseFeatures | Measure-Object).Count -gt 0
            $hasCompression = ($compressionUsage | Measure-Object).Count -gt 0
            $hasPartitioning = ($partitionUsage | Measure-Object).Count -gt 0

            $featureList = @()
            if ($enterpriseFeatures) { $featureList += $enterpriseFeatures.FeatureName }
            if ($hasCompression) { $featureList += "DataCompression" }
            if ($hasPartitioning) { $featureList += "TablePartitioning" }

            $eligibility = if ($hasEnterpriseFeatures) { 'Blocked' }
                          elseif ($hasCompression -or $hasPartitioning) { 'ReviewRequired' }
                          else { 'Eligible' }

            $results += [PSCustomObject]@{
                MachineName          = $instanceInfo.MachineName
                InstanceName         = $instanceInfo.ServerName
                Edition              = $instanceInfo.Edition
                ProductVersion       = $instanceInfo.ProductVersion
                ProductLevel         = $instanceInfo.ProductLevel
                VisibleCPUs          = $instanceInfo.VisibleCPUs
                DatabaseName         = $db.name
                CompatibilityLevel   = $db.compatibility_level
                EnterpriseFeatures   = ($featureList -join ';')
                FeatureCount         = $featureList.Count
                HasBlockingFeatures  = $hasEnterpriseFeatures
                DowngradeEligibility = $eligibility
                Timestamp            = (Get-Date -Format 'o')
            }
        }
    }
} catch {
    $results += [PSCustomObject]@{
        MachineName          = $env:COMPUTERNAME
        InstanceName         = 'Unknown'
        Edition              = 'Unknown'
        ProductVersion       = 'Unknown'
        ProductLevel         = 'Unknown'
        VisibleCPUs          = 0
        DatabaseName         = 'N/A'
        CompatibilityLevel   = 0
        EnterpriseFeatures   = "ERROR: $($_.Exception.Message)"
        FeatureCount         = 0
        HasBlockingFeatures  = $false
        DowngradeEligibility = 'Error'
        Timestamp            = (Get-Date -Format 'o')
    }
}

$results | ConvertTo-Json -Depth 5
'@
}
#endregion

#region Step 1: Query Azure Resource Graph
Write-Host "Querying Azure Resource Graph for Arc-enabled servers..."

$graphParams = @{
    Query = $resourceGraphQuery
}

if ($subscriptionFilter) {
    $graphParams.Subscription = $subscriptionFilter
}

try {
    $arcMachines = Search-AzGraph @graphParams

    if ($tagFilter -and $tagFilter.Count -gt 0) {
        $arcMachines = $arcMachines | Where-Object {
            $machine = $_
            $matchAll = $true
            foreach ($key in $tagFilter.Keys) {
                if ($machine.tags.$key -ne $tagFilter[$key]) {
                    $matchAll = $false
                    break
                }
            }
            $matchAll
        }
    }

    Write-Host "Found $($arcMachines.Count) Arc-enabled server(s)"
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = @{ error = "Resource Graph query failed: $($_.Exception.Message)" } | ConvertTo-Json
    })
    return
}

if ($arcMachines.Count -eq 0) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = @{ message = "No connected Arc-enabled servers found matching criteria." } | ConvertTo-Json
    })
    return
}
#endregion

#region Step 2: Execute Run Command on Each Arc Machine
Write-Host "Executing Run Commands on $($arcMachines.Count) machine(s)..."

$allResults = [System.Collections.Generic.List[object]]::new()

foreach ($machine in $arcMachines) {
    $machineName    = $machine.name
    $resourceGroup  = $machine.resourceGroup
    $subscriptionId = $machine.subscriptionId

    Write-Host "  -> Processing: $machineName (RG: $resourceGroup)"

    try {
        # Set context to the machine's subscription
        Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null

        # Build the Run Command resource
        $runCommandName = "sqlopt-$(Get-Date -Format 'yyyyMMddHHmmss')"

        $runCommandParams = @{
            ResourceGroupName = $resourceGroup
            MachineName       = $machineName
            RunCommandName    = $runCommandName
            Location          = $machine.location
            SourceScript      = $scriptContent
            TimeoutInSeconds  = 600
            AsyncExecution    = $false
        }

        # Execute via Arc Run Command (Az.ConnectedMachine module)
        $runResult = New-AzConnectedMachineRunCommand @runCommandParams

        # Parse output
        $output = $runResult.InstanceViewOutput
        $exitCode = $runResult.InstanceViewExecutionState

        $machineResult = @{
            MachineName     = $machineName
            ResourceGroup   = $resourceGroup
            SubscriptionId  = $subscriptionId
            Location        = $machine.location
            ExecutionState  = $exitCode
            Timestamp       = (Get-Date -Format 'o')
            Output          = $null
            Error           = $null
        }

        if ($output) {
            try {
                $parsedOutput = $output | ConvertFrom-Json
                $machineResult.Output = $parsedOutput
            } catch {
                $machineResult.Output = $output
            }
        }

        if ($runResult.InstanceViewError) {
            $machineResult.Error = $runResult.InstanceViewError
        }

        $allResults.Add($machineResult)
        Write-Host "    Completed: $machineName (State: $exitCode)"

    } catch {
        $errorResult = @{
            MachineName    = $machineName
            ResourceGroup  = $resourceGroup
            SubscriptionId = $subscriptionId
            Location       = $machine.location
            ExecutionState = 'Failed'
            Timestamp      = (Get-Date -Format 'o')
            Output         = $null
            Error          = $_.Exception.Message
        }
        $allResults.Add($errorResult)
        Write-Warning "    Failed: $machineName - $($_.Exception.Message)"
    }
}
#endregion

#region Step 3: Ingest Results via Logs Ingestion API
Write-Host "Sending results to Log Analytics via Logs Ingestion API..."

try {
    # Flatten results: each database/instance combination becomes a log entry
    $logEntries = [System.Collections.Generic.List[object]]::new()

    foreach ($result in $allResults) {
        $output = $result.Output
        if ($output -and $result.ExecutionState -ne 'Failed') {
            try {
                $parsed = if ($output -is [string]) { $output | ConvertFrom-Json } else { $output }
                foreach ($entry in $parsed) {
                    $logEntries.Add(@{
                        TimeGenerated        = $entry.Timestamp ?? $result.Timestamp
                        MachineName          = $entry.MachineName ?? $result.MachineName
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
                # If parsing fails, log raw output
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
                EnterpriseFeatures   = "EXECUTION_ERROR: $($result.Error)"
                FeatureCount         = 0
                HasBlockingFeatures  = $false
                DowngradeEligibility = 'Error'
                ResourceGroup        = $result.ResourceGroup
                SubscriptionId       = $result.SubscriptionId
                Location             = $result.Location
            })
        }
    }

    if ($logEntries.Count -gt 0) {
        $ingestionResult = Send-LogsIngestion `
            -DceEndpoint $dceEndpoint `
            -DcrImmutableId $dcrImmutableId `
            -StreamName $logStreamName `
            -LogEntries $logEntries

        Write-Host "Logs ingestion complete. Status: $($ingestionResult.Status) ($($logEntries.Count) entries)"
    } else {
        Write-Host "No log entries to ingest."
    }
} catch {
    Write-Warning "Logs ingestion failed: $($_.Exception.Message)"
}
#endregion

#region Response
$summary = @{
    totalMachines   = $arcMachines.Count
    successful      = ($allResults | Where-Object { $_.ExecutionState -ne 'Failed' }).Count
    failed          = ($allResults | Where-Object { $_.ExecutionState -eq 'Failed' }).Count
    timestamp       = (Get-Date -Format 'o')
    results         = $allResults
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode  = [HttpStatusCode]::OK
    ContentType = 'application/json'
    Body        = ($summary | ConvertTo-Json -Depth 10)
})
#endregion
