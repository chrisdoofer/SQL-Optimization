param($Timer)

<#
.SYNOPSIS
    Timer-triggered variant that runs SQL Server Edition Optimisation analysis on a schedule.
    Detects Enterprise-only feature usage to identify downgrade opportunities.
    Default: Every Sunday at 02:00 UTC.
#>

# Import shared module
. "$PSScriptRoot\..\modules\LogsIngestion.ps1"

#region Configuration
$resourceGraphQuery = $env:RESOURCE_GRAPH_QUERY
$dceEndpoint        = $env:DCE_ENDPOINT
$dcrImmutableId     = $env:DCR_IMMUTABLE_ID
$logStreamName      = $env:LOG_STREAM_NAME
#endregion

Write-Host "Timer trigger fired at: $(Get-Date -Format 'o')"

if ($Timer.IsPastDue) {
    Write-Host "Timer is running late - executing anyway"
}

#region Query Resource Graph
$arcMachines = Search-AzGraph -Query $resourceGraphQuery

Write-Host "Discovered $($arcMachines.Count) Arc-enabled server(s)"

if ($arcMachines.Count -eq 0) {
    Write-Host "No machines found. Exiting."
    return
}
#endregion

#region Enterprise Feature Detection Script
$scriptContent = @'
$ErrorActionPreference = 'Continue'
$results = @()
try {
    Import-Module SqlServer -ErrorAction Stop
    $instances = Get-Service -Name 'MSSQL*' | Where-Object { $_.Status -eq 'Running' }
    foreach ($svc in $instances) {
        $instanceName = if ($svc.Name -eq 'MSSQLSERVER') { 'localhost' } else { "localhost\$($svc.Name -replace 'MSSQL\$','')" }
        $instanceInfo = Invoke-Sqlcmd -ServerInstance $instanceName -Query "
            SELECT SERVERPROPERTY('MachineName') AS MachineName, SERVERPROPERTY('ServerName') AS ServerName,
                   SERVERPROPERTY('Edition') AS Edition, SERVERPROPERTY('ProductVersion') AS ProductVersion,
                   SERVERPROPERTY('ProductLevel') AS ProductLevel,
                   (SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE') AS VisibleCPUs"
        $databases = Invoke-Sqlcmd -ServerInstance $instanceName -Query "
            SELECT name, compatibility_level FROM sys.databases
            WHERE state_desc = 'ONLINE' AND name NOT IN ('master','tempdb','model','msdb')"
        foreach ($db in $databases) {
            $enterpriseFeatures = Invoke-Sqlcmd -ServerInstance $instanceName -Database $db.name -Query "
                SELECT feature_name AS FeatureName FROM sys.dm_db_persisted_sku_features" -ErrorAction SilentlyContinue
            $compression = Invoke-Sqlcmd -ServerInstance $instanceName -Database $db.name -Query "
                SELECT COUNT(*) AS Cnt FROM sys.partitions WHERE data_compression > 0" -ErrorAction SilentlyContinue
            $partitioning = Invoke-Sqlcmd -ServerInstance $instanceName -Database $db.name -Query "
                SELECT COUNT(DISTINCT object_id) AS Cnt FROM sys.partitions WHERE partition_number > 1" -ErrorAction SilentlyContinue

            $featureList = @()
            if ($enterpriseFeatures) { $featureList += $enterpriseFeatures.FeatureName }
            if ($compression.Cnt -gt 0) { $featureList += "DataCompression" }
            if ($partitioning.Cnt -gt 0) { $featureList += "TablePartitioning" }

            $hasBlocking = ($enterpriseFeatures | Measure-Object).Count -gt 0
            $eligibility = if ($hasBlocking) { 'Blocked' } elseif ($featureList.Count -gt 0) { 'ReviewRequired' } else { 'Eligible' }

            $results += [PSCustomObject]@{
                MachineName = $instanceInfo.MachineName; InstanceName = $instanceInfo.ServerName
                Edition = $instanceInfo.Edition; ProductVersion = $instanceInfo.ProductVersion
                ProductLevel = $instanceInfo.ProductLevel; VisibleCPUs = $instanceInfo.VisibleCPUs
                DatabaseName = $db.name; CompatibilityLevel = $db.compatibility_level
                EnterpriseFeatures = ($featureList -join ';'); FeatureCount = $featureList.Count
                HasBlockingFeatures = $hasBlocking; DowngradeEligibility = $eligibility
                Timestamp = (Get-Date -Format 'o')
            }
        }
    }
} catch {
    $results += [PSCustomObject]@{
        MachineName = $env:COMPUTERNAME; InstanceName = 'Unknown'; Edition = 'Unknown'
        ProductVersion = 'Unknown'; ProductLevel = 'Unknown'; VisibleCPUs = 0
        DatabaseName = 'N/A'; CompatibilityLevel = 0
        EnterpriseFeatures = "ERROR: $($_.Exception.Message)"; FeatureCount = 0
        HasBlockingFeatures = $false; DowngradeEligibility = 'Error'; Timestamp = (Get-Date -Format 'o')
    }
}
$results | ConvertTo-Json -Depth 5
'@
#endregion

#region Execute Run Commands
$allResults = [System.Collections.Generic.List[object]]::new()

foreach ($machine in $arcMachines) {
    try {
        Set-AzContext -SubscriptionId $machine.subscriptionId -ErrorAction Stop | Out-Null

        $runCommandName = "sqlopt-scheduled-$(Get-Date -Format 'yyyyMMddHHmmss')"
        $runResult = New-AzConnectedMachineRunCommand `
            -ResourceGroupName $machine.resourceGroup `
            -MachineName $machine.name `
            -RunCommandName $runCommandName `
            -Location $machine.location `
            -SourceScript $scriptContent `
            -TimeoutInSeconds 600 `
            -AsyncExecution $false

        $machineResult = @{
            MachineName    = $machine.name
            ResourceGroup  = $machine.resourceGroup
            SubscriptionId = $machine.subscriptionId
            ExecutionState = $runResult.InstanceViewExecutionState
            Timestamp      = (Get-Date -Format 'o')
            Output         = $runResult.InstanceViewOutput
            Error          = $runResult.InstanceViewError
        }
        $allResults.Add($machineResult)
        Write-Host "  Completed: $($machine.name)"
    } catch {
        $allResults.Add(@{
            MachineName    = $machine.name
            ResourceGroup  = $machine.resourceGroup
            SubscriptionId = $machine.subscriptionId
            ExecutionState = 'Failed'
            Timestamp      = (Get-Date -Format 'o')
            Output         = $null
            Error          = $_.Exception.Message
        })
        Write-Warning "  Failed: $($machine.name) - $($_.Exception.Message)"
    }
}
#endregion

#region Ingest to Log Analytics
$logEntries = [System.Collections.Generic.List[object]]::new()

foreach ($result in $allResults) {
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
                })
            }
        } catch {
            Write-Warning "Failed to parse output from $($result.MachineName): $($_.Exception.Message)"
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
        })
    }
}

try {
    if ($logEntries.Count -gt 0) {
        $ingestionResult = Send-LogsIngestion `
            -DceEndpoint $dceEndpoint `
            -DcrImmutableId $dcrImmutableId `
            -StreamName $logStreamName `
            -LogEntries $logEntries

        Write-Host "Logs ingestion: $($ingestionResult.Status) ($($logEntries.Count) entries, $($ingestionResult.BatchesSent) batches)"
    }
} catch {
    Write-Warning "Logs ingestion failed: $($_.Exception.Message)"
}
#endregion

Write-Host "Scheduled execution complete. Processed $($allResults.Count) machine(s)."
