$ErrorActionPreference = 'Continue'
$results = @()

# Use sqlcmd (installed with SQL Server by default) instead of SqlServer PS module
try {
    $instances = Get-Service -Name 'MSSQL*' | Where-Object { $_.Status -eq 'Running' }
    foreach ($svc in $instances) {
        $serverInstance = if ($svc.Name -eq 'MSSQLSERVER') { '.' } else { ".\$($svc.Name -replace 'MSSQL\$','')" }

        # Get instance info
        $infoQuery = @"
SET NOCOUNT ON
SELECT SERVERPROPERTY('MachineName') AS MachineName,
       SERVERPROPERTY('ServerName') AS ServerName,
       SERVERPROPERTY('Edition') AS Edition,
       SERVERPROPERTY('ProductVersion') AS ProductVersion,
       SERVERPROPERTY('ProductLevel') AS ProductLevel,
       (SELECT COUNT(*) FROM sys.dm_os_schedulers WHERE status = 'VISIBLE ONLINE') AS VisibleCPUs
"@
        $infoRaw = sqlcmd -S $serverInstance -Q $infoQuery -h -1 -W -s "|" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed for instance info: $infoRaw" }

        $infoParts = ($infoRaw | Where-Object { $_ -match '\|' } | Select-Object -First 1) -split '\|'
        $machineName = $infoParts[0].Trim()
        $serverName = $infoParts[1].Trim()
        $edition = $infoParts[2].Trim()
        $productVersion = $infoParts[3].Trim()
        $productLevel = $infoParts[4].Trim()
        $visibleCPUs = [int]$infoParts[5].Trim()

        # Get user databases
        $dbQuery = @"
SET NOCOUNT ON
SELECT name, compatibility_level FROM sys.databases
WHERE state_desc = 'ONLINE' AND name NOT IN ('master','tempdb','model','msdb')
"@
        $dbRaw = sqlcmd -S $serverInstance -Q $dbQuery -h -1 -W -s "|" 2>&1
        $dbLines = $dbRaw | Where-Object { $_ -match '\|' }

        if (-not $dbLines -or $dbLines.Count -eq 0) {
            # No user databases — report instance as eligible
            $results += [PSCustomObject]@{
                MachineName = $machineName; InstanceName = $serverName
                Edition = $edition; ProductVersion = $productVersion
                ProductLevel = $productLevel; VisibleCPUs = $visibleCPUs
                DatabaseName = '(No user databases)'; CompatibilityLevel = 0
                EnterpriseFeatures = ''; FeatureCount = 0
                HasBlockingFeatures = $false; DowngradeEligibility = 'Eligible'
                Timestamp = (Get-Date -Format 'o')
            }
            continue
        }

        foreach ($dbLine in $dbLines) {
            $dbParts = $dbLine -split '\|'
            $dbName = $dbParts[0].Trim()
            $compatLevel = [int]$dbParts[1].Trim()

            $featureList = @()

            # Check enterprise-only features (sys.dm_db_persisted_sku_features)
            $featQuery = "SET NOCOUNT ON; SELECT feature_name FROM [$dbName].sys.dm_db_persisted_sku_features"
            $featRaw = sqlcmd -S $serverInstance -Q $featQuery -h -1 -W 2>&1
            if ($LASTEXITCODE -eq 0 -and $featRaw) {
                $featLines = $featRaw | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^\(' }
                foreach ($f in $featLines) { if ($f.Trim()) { $featureList += $f.Trim() } }
            }

            # Check data compression
            $compQuery = "SET NOCOUNT ON; SELECT COUNT(*) FROM [$dbName].sys.partitions WHERE data_compression > 0"
            $compRaw = sqlcmd -S $serverInstance -Q $compQuery -h -1 -W 2>&1
            if ($LASTEXITCODE -eq 0 -and [int]($compRaw | Select-Object -First 1).Trim() -gt 0) {
                $featureList += 'DataCompression'
            }

            # Check table partitioning
            $partQuery = "SET NOCOUNT ON; SELECT COUNT(DISTINCT object_id) FROM [$dbName].sys.partitions WHERE partition_number > 1"
            $partRaw = sqlcmd -S $serverInstance -Q $partQuery -h -1 -W 2>&1
            if ($LASTEXITCODE -eq 0 -and [int]($partRaw | Select-Object -First 1).Trim() -gt 0) {
                $featureList += 'TablePartitioning'
            }

            $hasBlocking = ($featRaw | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^\(' }).Count -gt 0
            $eligibility = if ($hasBlocking) { 'Blocked' } elseif ($featureList.Count -gt 0) { 'ReviewRequired' } else { 'Eligible' }

            $results += [PSCustomObject]@{
                MachineName = $machineName; InstanceName = $serverName
                Edition = $edition; ProductVersion = $productVersion
                ProductLevel = $productLevel; VisibleCPUs = $visibleCPUs
                DatabaseName = $dbName; CompatibilityLevel = $compatLevel
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
