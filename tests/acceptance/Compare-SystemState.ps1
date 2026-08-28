#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BeforePath,
    [Parameter(Mandatory = $true)][string]$AfterPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AcceptanceTools.psm1') -Force
if (Test-Path -LiteralPath $OutputPath) { throw "Evidence output already exists: $OutputPath" }
$before = Get-Content -LiteralPath $BeforePath -Raw -Encoding UTF8 | ConvertFrom-Json
$after = Get-Content -LiteralPath $AfterPath -Raw -Encoding UTF8 | ConvertFrom-Json
$comparison = Compare-AcceptanceSystemState -Before $before -After $after
$json = ConvertTo-AcceptanceJson -InputObject $comparison
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutputPath), $json, $utf8)
$comparison
