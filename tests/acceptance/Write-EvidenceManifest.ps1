#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AcceptanceTools.psm1') -Force
if (Test-Path -LiteralPath $OutputPath) { throw "Evidence output already exists: $OutputPath" }
$raw = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8
if (-not (Test-AcceptanceSecretText -Text $raw)) { throw 'Input evidence contains a possible secret.' }
$manifest = $raw | ConvertFrom-Json
$validation = Test-AcceptanceEvidence -Manifest $manifest
if (-not $validation.valid) { throw ('Evidence manifest is invalid; missing: ' + ($validation.missing -join ', ')) }
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), (ConvertTo-AcceptanceJson -InputObject $manifest), $utf8)
Get-AcceptanceSha256 -LiteralPath ([IO.Path]::GetFullPath($OutputPath))
