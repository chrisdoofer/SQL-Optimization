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
