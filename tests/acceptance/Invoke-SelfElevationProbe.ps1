#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CandidateRoot
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
$arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Only chrome -Skip chrome -Yes' -f $bootstrapPath

Write-Host 'This probe triggers one UAC prompt but selects and skips the same application, so no provider may install anything.'
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

if ($exitCode -ne 0) {
    throw "The self-elevation probe failed with exit code $exitCode. Do not bypass it by starting bootstrap.ps1 as administrator."
}

Write-Host 'Self-elevation probe passed: the skipped selection returned exit code 0.' -ForegroundColor Green
exit 0
