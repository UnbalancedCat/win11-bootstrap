#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ExpectedPath,
    [Parameter(Mandatory = $true)][string]$ActualPath,
    [Parameter(Mandatory = $true)][string]$OutputPath
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AcceptanceTools.psm1') -Force
if (Test-Path -LiteralPath $OutputPath) { throw "Evidence output already exists: $OutputPath" }
$expectedObject = Get-Content -LiteralPath $ExpectedPath -Raw -Encoding UTF8 | ConvertFrom-Json
$actualObject = Get-Content -LiteralPath $ActualPath -Raw -Encoding UTF8 | ConvertFrom-Json
$expected = @{}
$actual = @{}
foreach ($property in $expectedObject.PSObject.Properties) { $expected[$property.Name] = [string]$property.Value }
foreach ($property in $actualObject.PSObject.Properties) { $actual[$property.Name] = [string]$property.Value }
$comparison = Compare-AcceptanceStatuses -Expected $expected -Actual $actual
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), (ConvertTo-AcceptanceJson -InputObject $comparison), $utf8)
$comparison
