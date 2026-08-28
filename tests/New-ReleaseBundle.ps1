#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$')]
    [string]$Version,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepositoryRoot = (Split-Path -Path $PSScriptRoot -Parent),

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F]{64}$')]
    [string]$ExpectedArchiveSha256
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRootPath = [System.IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\', '/')
$outputDirectoryPath = [System.IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\', '/')
$requiredFiles = @(
    'bootstrap.ps1'
    'bootstrap.example.json'
    'docs/index.md'
    'README.md'
    'CONTRIBUTING.md'
    'SECURITY.md'
    'LICENSE'
)
$requiredDirectories = @('src', 'catalog', 'schemas', 'resources', 'docs/en', 'docs/zh-CN')
$allowedExtensions = @('.ps1', '.psm1', '.psd1', '.json', '.md')
$forbiddenExtensions = @(
    '.exe', '.dll', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle',
    '.iso', '.vhd', '.vhdx', '.zip', '.7z', '.rar', '.cab', '.nupkg', '.sys',
    '.pfx', '.p12', '.pem', '.key', '.log', '.tmp', '.cache'
)

function Get-CanonicalTextBytes {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string]$DisplayPath
    )

    $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $text = $strictUtf8.GetString($bytes)
    }
    catch [System.Text.DecoderFallbackException] {
        throw "Release input is not valid UTF-8: $DisplayPath"
    }

    if ($text.Length -gt 0 -and $text[0] -eq [char]0xfeff) {
        $text = $text.Substring(1)
    }
    if ($text.IndexOf([char]0) -ge 0) {
        throw "Release input contains NUL text: $DisplayPath"
    }

    $canonicalText = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    return ,$utf8WithoutBom.GetBytes($canonicalText)
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$LiteralPath)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($LiteralPath)
        try {
            $hash = $algorithm.ComputeHash($stream)
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $algorithm.Dispose()
    }
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}

$crc32Table = New-Object 'uint32[]' 256
[uint32]$crc32Polynomial = [Convert]::ToUInt32('edb88320', 16)
for ($tableIndex = 0; $tableIndex -lt $crc32Table.Length; $tableIndex++) {
    [uint32]$value = $tableIndex
    foreach ($bit in 1..8) {
        if (($value -band [uint32]1) -ne 0) {
            $value = [uint32](($value -shr 1) -bxor $crc32Polynomial)
        }
        else {
            $value = [uint32]($value -shr 1)
        }
    }
    $crc32Table[$tableIndex] = $value
}

function Get-Crc32 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    [uint32]$crc = [uint32]::MaxValue
    foreach ($byte in $Bytes) {
        $tableIndex = [int](($crc -bxor [uint32]$byte) -band [uint32]0xff)
        $crc = [uint32](($crc -shr 8) -bxor $crc32Table[$tableIndex])
    }
    return [uint32]($crc -bxor [uint32]::MaxValue)
}

function Write-StoredZipArchive {
    param(
        [Parameter(Mandatory = $true)][string]$LiteralPath,
        [Parameter(Mandatory = $true)][string[]]$EntryPaths,
        [Parameter(Mandatory = $true)][hashtable]$BytesByPath
    )

    if ($EntryPaths.Count -gt [uint16]::MaxValue) {
        throw 'Release archive exceeds the ZIP32 entry-count limit.'
    }

    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    $records = New-Object 'System.Collections.Generic.List[object]'
    $stream = [System.IO.File]::Open(
        $LiteralPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    $writer = $null
    try {
        $writer = New-Object System.IO.BinaryWriter($stream, $utf8WithoutBom, $true)
        foreach ($entryPath in $EntryPaths) {
            $nameBytes = $utf8WithoutBom.GetBytes($entryPath)
            $contentBytes = [byte[]]$BytesByPath[$entryPath]
            if ($nameBytes.Length -gt [uint16]::MaxValue) {
                throw "Release archive path exceeds the ZIP32 name limit: $entryPath"
            }
            if ($contentBytes.LongLength -gt [uint32]::MaxValue) {
                throw "Release archive entry exceeds the ZIP32 size limit: $entryPath"
            }
            if ($stream.Position -gt [uint32]::MaxValue) {
                throw 'Release archive exceeds the ZIP32 offset limit.'
            }

            [uint32]$crc32 = Get-Crc32 -Bytes $contentBytes
            [uint32]$contentLength = $contentBytes.Length
            [uint32]$localHeaderOffset = $stream.Position

            # Local file header: UTF-8 flag, Store method, fixed DOS epoch,
            # no extra field, and no data descriptor.
            $writer.Write([uint32]0x04034b50)
            $writer.Write([uint16]20)
            $writer.Write([uint16]0x0800)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0x0021)
            $writer.Write($crc32)
            $writer.Write($contentLength)
            $writer.Write($contentLength)
            $writer.Write([uint16]$nameBytes.Length)
            $writer.Write([uint16]0)
            $writer.Write($nameBytes)
            $writer.Write($contentBytes)

            [void]$records.Add([pscustomobject]@{
                NameBytes         = $nameBytes
                Crc32             = $crc32
                ContentLength     = $contentLength
                LocalHeaderOffset = $localHeaderOffset
            })
        }

        if ($stream.Position -gt [uint32]::MaxValue) {
            throw 'Release archive exceeds the ZIP32 central-directory offset limit.'
        }
        [uint32]$centralDirectoryOffset = $stream.Position
        foreach ($record in $records) {
            # Central directory header. Version-made-by uses the DOS platform
            # and all internal/external attributes remain zero.
            $writer.Write([uint32]0x02014b50)
            $writer.Write([uint16]20)
            $writer.Write([uint16]20)
            $writer.Write([uint16]0x0800)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0x0021)
            $writer.Write([uint32]$record.Crc32)
            $writer.Write([uint32]$record.ContentLength)
            $writer.Write([uint32]$record.ContentLength)
            $writer.Write([uint16]$record.NameBytes.Length)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint16]0)
            $writer.Write([uint32]0)
            $writer.Write([uint32]$record.LocalHeaderOffset)
            $writer.Write([byte[]]$record.NameBytes)
        }

        $centralDirectorySize = $stream.Position - $centralDirectoryOffset
        if ($centralDirectorySize -gt [uint32]::MaxValue) {
            throw 'Release archive exceeds the ZIP32 central-directory size limit.'
        }

        # End of central directory: one disk, no ZIP comment.
        $writer.Write([uint32]0x06054b50)
        $writer.Write([uint16]0)
        $writer.Write([uint16]0)
        $writer.Write([uint16]$records.Count)
        $writer.Write([uint16]$records.Count)
        $writer.Write([uint32]$centralDirectorySize)
        $writer.Write($centralDirectoryOffset)
        $writer.Write([uint16]0)
        $writer.Flush()
    }
    finally {
        if ($null -ne $writer) {
            $writer.Dispose()
        }
        $stream.Dispose()
    }
}

function New-ReleaseBundle {
param(
    [Parameter(Mandatory = $true)][string]$BundleVersion,
    [Parameter()][AllowEmptyString()][string]$AcceptedArchiveSha256
)
if (-not (Test-Path -LiteralPath $repositoryRootPath -PathType Container)) {
    throw "Repository root does not exist: $repositoryRootPath"
}
$repositoryRootItem = Get-Item -LiteralPath $repositoryRootPath -Force
if (($repositoryRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Repository root must not be a reparse point: $repositoryRootPath"
}
if (Test-Path -LiteralPath $outputDirectoryPath) {
    throw "Output directory already exists: $outputDirectoryPath"
}

$entriesByPath = @{}
foreach ($relativePath in $requiredFiles) {
    $fullPath = Join-Path -Path $repositoryRootPath -ChildPath $relativePath.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Required release input is missing: $relativePath"
    }
    $entriesByPath[$relativePath] = Get-Item -LiteralPath $fullPath -Force
}

foreach ($relativeDirectory in $requiredDirectories) {
    $fullDirectory = Join-Path -Path $repositoryRootPath -ChildPath $relativeDirectory.Replace('/', '\')
    if (-not (Test-Path -LiteralPath $fullDirectory -PathType Container)) {
        throw "Required release directory is missing: $relativeDirectory"
    }
    $directoryItem = Get-Item -LiteralPath $fullDirectory -Force
    if (($directoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Release directory must not be a reparse point: $fullDirectory"
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $fullDirectory -Directory -Recurse -Force)) {
        if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Release directory must not contain a reparse point: $($directory.FullName)"
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $fullDirectory -File -Recurse -Force)) {
        if (-not (Test-PathWithinRoot -Path $file.FullName -Root $repositoryRootPath)) {
            throw "Release input escaped the repository root: $($file.FullName)"
        }
        $relativePath = $file.FullName.Substring($repositoryRootPath.Length).TrimStart('\', '/').Replace('\', '/')
        if ($entriesByPath.ContainsKey($relativePath)) {
            throw "Release input is duplicated: $relativePath"
        }
        $entriesByPath[$relativePath] = $file
    }
}

$entryPaths = [string[]]$entriesByPath.Keys
[Array]::Sort($entryPaths, [StringComparer]::Ordinal)
$canonicalBytesByPath = @{}
foreach ($entryPath in $entryPaths) {
    Assert-PlainRuntimeFile -File $entriesByPath[$entryPath]
    $canonicalBytesByPath[$entryPath] = Get-CanonicalTextBytes `
        -LiteralPath $entriesByPath[$entryPath].FullName `
        -DisplayPath $entryPath
}

[void][System.IO.Directory]::CreateDirectory($outputDirectoryPath)
$archiveName = 'win11-bootstrap-{0}.zip' -f $BundleVersion
$archivePath = Join-Path -Path $outputDirectoryPath -ChildPath $archiveName
$checksumPath = $archivePath + '.sha256'
$temporaryDirectory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('win11-bootstrap-bundle-{0}' -f [Guid]::NewGuid().ToString('N'))

try {
    Write-StoredZipArchive -LiteralPath $archivePath -EntryPaths $entryPaths -BytesByPath $canonicalBytesByPath
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $archiveSha256 = Get-Sha256Hex -LiteralPath $archivePath
    if ($AcceptedArchiveSha256 -and $archiveSha256 -ne $AcceptedArchiveSha256.ToLowerInvariant()) {
        throw "Release archive SHA-256 '$archiveSha256' does not match accepted SHA-256 '$($AcceptedArchiveSha256.ToLowerInvariant())'."
    }
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($checksumPath, ("{0}  {1}`n" -f $archiveSha256, $archiveName), $utf8WithoutBom)

    [void][System.IO.Directory]::CreateDirectory($temporaryDirectory)
    [System.IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $temporaryDirectory)
    $extractedPaths = @(Get-ChildItem -LiteralPath $temporaryDirectory -File -Recurse -Force | ForEach-Object {
        $_.FullName.Substring($temporaryDirectory.Length).TrimStart('\', '/').Replace('\', '/')
    })
    [Array]::Sort($extractedPaths, [StringComparer]::Ordinal)
    if (($extractedPaths -join "`n") -cne ($entryPaths -join "`n")) {
        throw 'Extracted release archive does not match the runtime file allowlist.'
    }

    $fingerprintScript = Join-Path -Path $PSScriptRoot -ChildPath 'Get-RuntimeFingerprint.ps1'
    # The fingerprint helper canonicalizes the source checkout in the same way
    # as the archive writer, so Git line-ending settings cannot alter identity.
    $sourceFingerprint = (& $fingerprintScript -RepositoryRoot $repositoryRootPath | Select-Object -Last 1)
    $extractedFingerprint = (& $fingerprintScript -RepositoryRoot $temporaryDirectory | Select-Object -Last 1)
    if ($sourceFingerprint -cne $extractedFingerprint) {
        throw "Extracted runtime fingerprint '$extractedFingerprint' does not match source fingerprint '$sourceFingerprint'."
    }

    [pscustomobject]@{
        ArchivePath        = $archivePath
        ChecksumPath       = $checksumPath
        ArchiveSha256      = $archiveSha256
        RuntimeFingerprint = $sourceFingerprint
        FileCount          = $entryPaths.Count
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        [System.IO.Directory]::Delete($temporaryDirectory, $true)
    }
}
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $rootPrefix = $Root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-PlainRuntimeFile {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo]$File)

    if (($File.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Release input must not be a reparse point: $($File.FullName)"
    }

    $extension = $File.Extension.ToLowerInvariant()
    if ($forbiddenExtensions -contains $extension) {
        throw "Release input has a forbidden extension: $($File.FullName)"
    }
    if ($File.Name -ne 'LICENSE' -and $allowedExtensions -notcontains $extension) {
        throw "Release input is not an allowed runtime text file: $($File.FullName)"
    }

    try {
        $alternateStreams = @(Get-Item -LiteralPath $File.FullName -Stream * -ErrorAction Stop |
            Where-Object { $_.Stream -notin @(':$DATA', '$DATA') })
        if ($alternateStreams.Count -gt 0) {
            throw "Release input has an alternate data stream: $($File.FullName)"
        }
    }
    catch [System.Management.Automation.ParameterBindingException] {
        # Non-NTFS providers may not implement -Stream. Only the normal stream is archived.
        Write-Verbose "Alternate stream inspection is unavailable for $($File.FullName)."
    }

    $bytesToRead = [Math]::Min([int64]65536, $File.Length)
    $buffer = New-Object byte[] ([int]$bytesToRead)
    if ($bytesToRead -gt 0) {
        $stream = [System.IO.File]::OpenRead($File.FullName)
        try {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -ne $buffer.Length) {
                throw "Could not inspect the complete release input prefix: $($File.FullName)"
            }
        }
        finally {
            $stream.Dispose()
        }
    }

    $magicSignatures = @(
        [pscustomobject]@{ Offset = 0; Bytes = [byte[]](0x4d, 0x5a); Name = 'Windows PE' }
        [pscustomobject]@{ Offset = 0; Bytes = [byte[]](0xd0, 0xcf, 0x11, 0xe0); Name = 'OLE compound file' }
        [pscustomobject]@{ Offset = 0; Bytes = [byte[]](0x50, 0x4b, 0x03, 0x04); Name = 'ZIP archive' }
        [pscustomobject]@{ Offset = 0; Bytes = [byte[]](0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c); Name = '7-Zip archive' }
        [pscustomobject]@{ Offset = 0; Bytes = [byte[]](0x52, 0x61, 0x72, 0x21, 0x1a, 0x07); Name = 'RAR archive' }
        [pscustomobject]@{ Offset = 0; Bytes = [byte[]](0x4d, 0x53, 0x43, 0x46); Name = 'CAB archive' }
        [pscustomobject]@{ Offset = 0; Bytes = [byte[]](0x76, 0x68, 0x64, 0x78, 0x66, 0x69, 0x6c, 0x65); Name = 'VHDX image' }
        [pscustomobject]@{ Offset = 0; Bytes = [byte[]](0x7f, 0x45, 0x4c, 0x46); Name = 'ELF binary' }
        [pscustomobject]@{ Offset = 0x8001; Bytes = [byte[]](0x43, 0x44, 0x30, 0x30, 0x31); Name = 'ISO image' }
    )

    foreach ($signature in $magicSignatures) {
        if (($signature.Offset + $signature.Bytes.Length) -gt $buffer.Length) {
            continue
        }
        $signatureMatches = $true
        for ($index = 0; $index -lt $signature.Bytes.Length; $index++) {
            if ($buffer[$signature.Offset + $index] -ne $signature.Bytes[$index]) {
                $signatureMatches = $false
                break
            }
        }
        if ($signatureMatches) {
            throw "Release input contains forbidden $($signature.Name) content: $($File.FullName)"
        }
    }
    if ([Array]::IndexOf($buffer, [byte]0) -ge 0) {
        throw "Release input contains NUL bytes and is not treated as text: $($File.FullName)"
    }
}

New-ReleaseBundle -BundleVersion $Version -AcceptedArchiveSha256 $ExpectedArchiveSha256
