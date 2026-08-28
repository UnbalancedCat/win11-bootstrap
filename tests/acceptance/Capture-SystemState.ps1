#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$OutputPath)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AcceptanceTools.psm1') -Force
if (Test-Path -LiteralPath $OutputPath) { throw "Evidence output already exists: $OutputPath" }
$parent = Split-Path -Path ([System.IO.Path]::GetFullPath($OutputPath)) -Parent
[void][System.IO.Directory]::CreateDirectory($parent)
$json = ConvertTo-AcceptanceJson -InputObject (Get-AcceptanceSystemState)
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutputPath), $json, $utf8)
Get-AcceptanceSha256 -LiteralPath ([System.IO.Path]::GetFullPath($OutputPath))
