#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][uri]$ProxyUri,
    [Parameter()][uri]$Uri = 'https://www.microsoft.com/favicon.ico',
    [Parameter()][ValidateRange(3, 60)][int]$TimeoutSeconds = 15
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
if ($ProxyUri.Scheme -notin @('http', 'https') -or -not [string]::IsNullOrEmpty($ProxyUri.UserInfo) -or
    -not [string]::IsNullOrEmpty($ProxyUri.Query) -or -not [string]::IsNullOrEmpty($ProxyUri.Fragment)) {
    throw 'ProxyUri must be an HTTP(S) authority without credentials, query, or fragment.'
}
if ($Uri.Scheme -ne 'https' -or -not [string]::IsNullOrEmpty($Uri.UserInfo)) { throw 'Probe URI must be credential-free HTTPS.' }
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.Proxy = New-Object System.Net.WebProxy($ProxyUri, $true)
$handler.UseProxy = $true
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
$started = [DateTime]::UtcNow
$response = $null
try {
    $response = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    [pscustomobject]@{ success = $response.IsSuccessStatusCode; statusCode = [int]$response.StatusCode; targetHost = $Uri.DnsSafeHost; elapsedMs = [int]([DateTime]::UtcNow - $started).TotalMilliseconds }
    if (-not $response.IsSuccessStatusCode) { exit 10 }
}
catch {
    [pscustomobject]@{ success = $false; statusCode = $null; targetHost = $Uri.DnsSafeHost; elapsedMs = [int]([DateTime]::UtcNow - $started).TotalMilliseconds; errorType = $_.Exception.GetType().FullName }
    exit 10
}
finally {
    if ($response) { $response.Dispose() }
    $client.Dispose()
    $handler.Dispose()
}
