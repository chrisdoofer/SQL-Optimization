param($Input)

<#
.SYNOPSIS
    Activity Function - Queries Azure Resource Graph to discover all connected
    Arc-enabled machines. Handles pagination for large estates (1000+ machines).
#>

$payload = if ($Input -is [string]) { $Input | ConvertFrom-Json } else { $Input }

$resourceGraphQuery = $env:RESOURCE_GRAPH_QUERY
$subscriptionFilter = $payload.subscriptionIds
$tagFilter          = $payload.tagFilter

Write-Host "ActivityDiscoverMachines: Querying Resource Graph..."

# Resource Graph returns max 1000 results per page — handle pagination
$allMachines = [System.Collections.Generic.List[object]]::new()
$skipToken = $null

do {
    $graphParams = @{
        Query = $resourceGraphQuery
        First = 1000
    }

    if ($subscriptionFilter) {
        $graphParams.Subscription = $subscriptionFilter
    }

    if ($skipToken) {
        $graphParams.SkipToken = $skipToken
    }

    $response = Search-AzGraph @graphParams
    $skipToken = $response.SkipToken

    foreach ($machine in $response.Data) {
        $allMachines.Add($machine)
    }

    Write-Host "  Fetched $($allMachines.Count) machines so far..."

} while ($skipToken)

# Apply tag filter if specified
if ($tagFilter -and $tagFilter.Count -gt 0) {
    $filtered = [System.Collections.Generic.List[object]]::new()
    foreach ($machine in $allMachines) {
        $matchAll = $true
        foreach ($key in $tagFilter.PSObject.Properties.Name) {
            if ($machine.tags.$key -ne $tagFilter.$key) {
                $matchAll = $false
                break
            }
        }
        if ($matchAll) { $filtered.Add($machine) }
    }
    $allMachines = $filtered
}

Write-Host "ActivityDiscoverMachines: Returning $($allMachines.Count) machines"

return $allMachines.ToArray()
