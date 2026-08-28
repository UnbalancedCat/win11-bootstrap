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

function Get-CanonicalTextBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $true)]
        [string]$DisplayPath
    )

    $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $text = $strictUtf8.GetString($bytes)
    }
    catch [System.Text.DecoderFallbackException] {
        throw "Runtime fingerprint input is not valid UTF-8: $DisplayPath"
    }

    if ($text.Length -gt 0 -and $text[0] -eq [char]0xfeff) {
        $text = $text.Substring(1)
    }
    if ($text.IndexOf([char]0) -ge 0) {
        throw "Runtime fingerprint input contains NUL text: $DisplayPath"
    }

    $canonicalText = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    return ,$utf8WithoutBom.GetBytes($canonicalText)
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
    $canonicalBytes = Get-CanonicalTextBytes -LiteralPath $fullPath -DisplayPath $relativePath
    $fileHash = Get-Sha256Hex -Bytes $canonicalBytes
    [void]$manifestLines.Add(("{0}`t{1}" -f $relativePath, $fileHash))
}

# Each runtime text file is fingerprinted as strict UTF-8 without a BOM and
# with LF line endings. The manifest uses ordinal path order, forward slashes,
# lowercase per-file hashes, UTF-8 without a BOM, and one LF per record.
$manifest = (($manifestLines.ToArray() -join "`n") + "`n")
$utf8 = New-Object System.Text.UTF8Encoding($false)
$fingerprint = Get-Sha256Hex -Bytes $utf8.GetBytes($manifest)
Write-Output ('sha256:{0}' -f $fingerprint)
