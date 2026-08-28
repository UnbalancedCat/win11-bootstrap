#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $repositoryRoot -PathType Container)) {
    throw "Repository root does not exist: $repositoryRoot"
}
$requiredFiles = @(
    'bootstrap.ps1'
    'bootstrap.example.json'
)
$requiredDirectories = @(
    'src'
    'catalog'
    'schemas'
    'resources'
)

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $algorithm.ComputeHash($Bytes)
    }
    finally {
        $algorithm.Dispose()
    }

    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

$relativePaths = New-Object 'System.Collections.Generic.List[string]'
foreach ($relativePath in $requiredFiles) {
    $fullPath = Join-Path -Path $repositoryRoot -ChildPath $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Runtime fingerprint input is missing: $relativePath"
    }
    [void]$relativePaths.Add($relativePath.Replace('\', '/'))
}

foreach ($relativeDirectory in $requiredDirectories) {
    $fullDirectory = Join-Path -Path $repositoryRoot -ChildPath $relativeDirectory
    if (-not (Test-Path -LiteralPath $fullDirectory -PathType Container)) {
        throw "Runtime fingerprint directory is missing: $relativeDirectory"
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $fullDirectory -Recurse -File -Force)) {
        $relativePath = $file.FullName.Substring($repositoryRoot.Length).TrimStart('\').Replace('\', '/')
        [void]$relativePaths.Add($relativePath)
    }
}

$paths = $relativePaths.ToArray()
[Array]::Sort($paths, [StringComparer]::Ordinal)
for ($index = 1; $index -lt $paths.Length; $index++) {
    if ([string]::Equals($paths[$index - 1], $paths[$index], [StringComparison]::Ordinal)) {
        throw "Runtime fingerprint input is duplicated: $($paths[$index])"
    }
}

$manifestLines = New-Object 'System.Collections.Generic.List[string]'
foreach ($relativePath in $paths) {
    $platformPath = $relativePath.Replace('/', '\')
    $fullPath = Join-Path -Path $repositoryRoot -ChildPath $platformPath
    $fileHash = Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($fullPath))
    [void]$manifestLines.Add(("{0}`t{1}" -f $relativePath, $fileHash))
}

# The canonical manifest uses ordinal path order, forward slashes, lowercase
# per-file hashes, UTF-8 without a BOM, and one LF after every record.
$manifest = (($manifestLines.ToArray() -join "`n") + "`n")
$utf8 = New-Object System.Text.UTF8Encoding($false)
$fingerprint = Get-Sha256Hex -Bytes $utf8.GetBytes($manifest)
Write-Output ('sha256:{0}' -f $fingerprint)
