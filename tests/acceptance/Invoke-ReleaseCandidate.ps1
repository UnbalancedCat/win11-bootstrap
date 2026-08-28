#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$CandidateRoot,
    [Parameter(Mandatory = $true)][ValidatePattern('^VM-0(?:0[1-9]|10|11)$')][string]$ScenarioId,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$BootstrapArguments = @()
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AcceptanceTools.psm1') -Force

$candidatePath = (Resolve-Path -LiteralPath $CandidateRoot -ErrorAction Stop).Path.TrimEnd('\', '/')
$candidateItem = Get-Item -LiteralPath $candidatePath -Force
if (-not $candidateItem.PSIsContainer -or (($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw 'CandidateRoot must be a plain directory.'
}
$bootstrap = Join-Path $candidatePath 'bootstrap.ps1'
if (-not (Test-Path -LiteralPath $bootstrap -PathType Leaf)) { throw 'CandidateRoot does not contain bootstrap.ps1.' }
$bootstrapItem = Get-Item -LiteralPath $bootstrap -Force
if (($bootstrapItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Candidate bootstrap.ps1 must not be a reparse point.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw "Evidence output directory already exists: $OutputDirectory" }
foreach ($argument in $BootstrapArguments) {
    if ($argument -match '(?i)(?:authorization|bearer|token|secret|password|subscription)' -or
        $argument -match '(?i)^(?:https?|socks5?)://[^/@\s]+@') {
        throw 'Secrets and credential-bearing URIs must never be passed to the evidence runner.'
    }
}

[void][IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory))
$stdoutPath = Join-Path $OutputDirectory 'stdout.txt'
$stderrPath = Join-Path $OutputDirectory 'stderr.txt'
$summaryPath = Join-Path $OutputDirectory 'run.json'
$started = [DateTime]::UtcNow
$process = New-Object Diagnostics.Process
$process.StartInfo = New-Object Diagnostics.ProcessStartInfo
$process.StartInfo.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
function ConvertTo-NativeArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 8192) { throw 'Candidate argument exceeds the evidence-runner limit.' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}
$nativeArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $bootstrap) + @($BootstrapArguments)
$process.StartInfo.Arguments = (@($nativeArguments | ForEach-Object { ConvertTo-NativeArgument -Value $_ }) -join ' ')
$process.StartInfo.WorkingDirectory = $candidatePath
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.CreateNoWindow = $true
$process.StartInfo.RedirectStandardOutput = $true
$process.StartInfo.RedirectStandardError = $true
if (-not $process.Start()) { throw 'Unable to start the candidate process.' }
$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$process.WaitForExit()
$stdout = Protect-AcceptanceText -Text $stdoutTask.GetAwaiter().GetResult()
$stderr = Protect-AcceptanceText -Text $stderrTask.GetAwaiter().GetResult()
$exitCode = $process.ExitCode
$process.Dispose()
$ended = [DateTime]::UtcNow

$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($stdoutPath, $stdout, $utf8)
[IO.File]::WriteAllText($stderrPath, $stderr, $utf8)
$commandSummary = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File bootstrap.ps1 ' + ($BootstrapArguments -join ' ')
$summary = [ordered]@{
    schemaVersion = 1; scenarioId = $ScenarioId
    startedAtUtc = $started.ToString('o'); endedAtUtc = $ended.ToString('o')
    commandSha256 = Get-AcceptanceSha256 -Text $commandSummary
    exitCode = $exitCode
    stdoutSha256 = Get-AcceptanceSha256 -LiteralPath $stdoutPath
    stderrSha256 = Get-AcceptanceSha256 -LiteralPath $stderrPath
}
[IO.File]::WriteAllText($summaryPath, (ConvertTo-AcceptanceJson -InputObject $summary), $utf8)
$summary
exit $exitCode
