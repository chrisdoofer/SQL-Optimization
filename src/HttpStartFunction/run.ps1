using namespace System.Net

param($Request, $TriggerMetadata)

<#
.SYNOPSIS
    HTTP Trigger - Accepts a scan request, queues it for async processing,
    and returns 202 Accepted immediately (avoids HTTP gateway 230s timeout).
#>

Write-Host "HttpStartFunction: Received scan request"

try {
    $body = if ($Request.Body) { $Request.Body } else { '{}' }

    # Write message to the output queue binding - triggers WorkerFunction
    Push-OutputBinding -Name QueueMessage -Value $body

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::Accepted
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{
            status  = 'Accepted'
            message = 'Scan queued for processing. Check Log Analytics for results.'
            timestamp = (Get-Date -Format 'o')
        } | ConvertTo-Json)
    })
}
catch {
    Write-Host "HttpStartFunction ERROR: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{ error = $_.Exception.Message } | ConvertTo-Json)
    })
}
