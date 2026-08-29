#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CandidateRoot,

    [Parameter()]
    [ValidateSet('Exit0', 'Exit10')]
    [string]$Scenario = 'Exit0'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run the self-elevation probe from an ordinary, non-elevated Windows PowerShell window.'
}

$candidatePath = [IO.Path]::GetFullPath($CandidateRoot).TrimEnd('\', '/')
$candidateItem = Get-Item -LiteralPath $candidatePath -Force -ErrorAction Stop
if (-not $candidateItem.PSIsContainer -or (($candidateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw 'CandidateRoot must be a regular directory.'
}
$bootstrapPath = Join-Path $candidatePath 'bootstrap.ps1'
$bootstrapItem = Get-Item -LiteralPath $bootstrapPath -Force -ErrorAction Stop
if ($bootstrapItem.PSIsContainer -or (($bootstrapItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
    $bootstrapPath.Contains('"')) {
    throw 'The candidate bootstrap entry point is unsafe for the elevation probe.'
}

$powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$scenarioArguments = if ($Scenario -ceq 'Exit10') {
    '-Only realvnc-viewer -Yes'
}
else {
    '-Only chrome -Skip chrome -Yes'
}
$expectedExitCode = if ($Scenario -ceq 'Exit10') { 10 } else { 0 }
$arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $bootstrapPath, $scenarioArguments

Write-Host ('This {0} probe triggers one UAC prompt and must not invoke an installation provider.' -f $Scenario)
$process = Start-Process `
    -FilePath $powerShellPath `
    -ArgumentList $arguments `
    -WorkingDirectory ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) `
    -Wait `
    -PassThru `
    -ErrorAction Stop
try {
    $exitCode = [int]$process.ExitCode
}
finally {
    $process.Dispose()
}

if ($exitCode -ne $expectedExitCode) {
    throw "The $Scenario self-elevation probe expected candidate exit code $expectedExitCode but received $exitCode. Do not bypass it by starting bootstrap.ps1 as administrator."
}

Write-Host ("Self-elevation probe passed: $Scenario preserved candidate exit code $expectedExitCode.") -ForegroundColor Green
exit 0
