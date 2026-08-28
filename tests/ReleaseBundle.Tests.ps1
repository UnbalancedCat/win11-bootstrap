#requires -Version 5.1

Describe 'Deterministic minimal release bundle' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path $PSScriptRoot -Parent
        $script:Builder = Join-Path $PSScriptRoot 'New-ReleaseBundle.ps1'
        $script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('w11b-bundle-tests-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:TestRoot)

        function New-BundleFixture {
            param([Parameter(Mandatory = $true)][string]$Destination)
            [void][IO.Directory]::CreateDirectory($Destination)
            foreach ($relativePath in @('bootstrap.ps1', 'bootstrap.example.json', 'README.md', 'CONTRIBUTING.md', 'SECURITY.md', 'LICENSE')) {
                Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $relativePath) -Destination (Join-Path $Destination $relativePath)
            }
            foreach ($relativeDirectory in @('src', 'catalog', 'schemas', 'resources')) {
                Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $relativeDirectory) -Destination $Destination -Recurse
            }
            [void][IO.Directory]::CreateDirectory((Join-Path $Destination 'docs'))
            foreach ($relativeDirectory in @('docs\en', 'docs\zh-CN')) {
                Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot $relativeDirectory) -Destination (Join-Path $Destination 'docs') -Recurse
            }
            Copy-Item -LiteralPath (Join-Path $script:RepositoryRoot 'docs\index.md') -Destination (Join-Path $Destination 'docs\index.md')
        }

        function Set-FixtureTextFormat {
            param(
                [Parameter(Mandatory = $true)][string]$Destination,
                [Parameter(Mandatory = $true)][ValidateSet('LF', 'CRLF')][string]$LineEnding,
                [Parameter(Mandatory = $true)][bool]$EmitBom
            )

            $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $encoding = New-Object System.Text.UTF8Encoding($EmitBom)
            foreach ($file in @(Get-ChildItem -LiteralPath $Destination -File -Recurse -Force)) {
                $text = $strictUtf8.GetString([IO.File]::ReadAllBytes($file.FullName))
                if ($text.Length -gt 0 -and $text[0] -eq [char]0xfeff) {
                    $text = $text.Substring(1)
                }
                $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
                if ($LineEnding -eq 'CRLF') {
                    $text = $text.Replace("`n", "`r`n")
                }
                [IO.File]::WriteAllText($file.FullName, $text, $encoding)
            }
        }

        function Get-ZipCentralDirectoryMethods {
            param([Parameter(Mandatory = $true)][string]$LiteralPath)

            $bytes = [IO.File]::ReadAllBytes($LiteralPath)
            function Read-UInt16([int]$Offset) { return [BitConverter]::ToUInt16($bytes, $Offset) }
            function Read-UInt32([int]$Offset) { return [BitConverter]::ToUInt32($bytes, $Offset) }

            $minimumEocdOffset = [Math]::Max(0, $bytes.Length - 65557)
            $eocdOffset = -1
            for ($offset = $bytes.Length - 22; $offset -ge $minimumEocdOffset; $offset--) {
                if ((Read-UInt32 $offset) -eq 0x06054b50) {
                    $eocdOffset = $offset
                    break
                }
            }
            if ($eocdOffset -lt 0) { throw 'ZIP end-of-central-directory record is missing.' }

            $entryCount = Read-UInt16 ($eocdOffset + 10)
            $centralOffset = [int](Read-UInt32 ($eocdOffset + 16))
            $methods = New-Object 'System.Collections.Generic.List[uint16]'
            foreach ($entryIndex in 1..$entryCount) {
                if ((Read-UInt32 $centralOffset) -ne 0x02014b50) {
                    throw 'ZIP central-directory entry is invalid.'
                }
                [void]$methods.Add((Read-UInt16 ($centralOffset + 10)))
                $nameLength = Read-UInt16 ($centralOffset + 28)
                $extraLength = Read-UInt16 ($centralOffset + 30)
                $commentLength = Read-UInt16 ($centralOffset + 32)
                $centralOffset += 46 + $nameLength + $extraLength + $commentLength
            }
            return $methods.ToArray()
        }
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:TestRoot) { [IO.Directory]::Delete($script:TestRoot, $true) }
    }

    It 'produces identical bytes and only the minimal allowlist' {
        $first = & $script:Builder -Version v0.1.0 -OutputDirectory (Join-Path $script:TestRoot 'first')
        $second = & $script:Builder -Version v0.1.0 -OutputDirectory (Join-Path $script:TestRoot 'second')
        $first.ArchiveSha256 | Should -BeExactly $second.ArchiveSha256
        [Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($first.ArchivePath), [byte[]][IO.File]::ReadAllBytes($second.ArchivePath)) | Should -BeTrue

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($first.ArchivePath)
        try {
            $paths = @($archive.Entries | ForEach-Object { $_.FullName })
            @($paths | Where-Object { $_ -match '^(?:tests|\.github|docs/acceptance|docs/releases)/|^AGENTS\.md$' }).Count | Should -Be 0
            @($paths | Where-Object { $_ -eq 'bootstrap.ps1' }).Count | Should -Be 1
            @($archive.Entries | Where-Object { $_.LastWriteTime.DateTime -ne [datetime]'1980-01-01T00:00:00' }).Count | Should -Be 0
            @($archive.Entries | Where-Object { $_.CompressedLength -ne $_.Length }).Count | Should -Be 0
            @($archive.Entries | Where-Object { $_.ExternalAttributes -ne 0 }).Count | Should -Be 0
            $methods = @(Get-ZipCentralDirectoryMethods -LiteralPath $first.ArchivePath)
            $methods.Count | Should -Be $paths.Count
            @($methods | Where-Object { $_ -ne 0 }).Count | Should -Be 0
        }
        finally { $archive.Dispose() }
    }

    It 'fails when the output directory already exists or accepted hash differs' {
        $existing = Join-Path $script:TestRoot 'existing'
        [void][IO.Directory]::CreateDirectory($existing)
        { & $script:Builder -Version v0.1.0 -OutputDirectory $existing } | Should -Throw '*already exists*'
        { & $script:Builder -Version v0.1.0 -OutputDirectory (Join-Path $script:TestRoot 'wrong-hash') -ExpectedArchiveSha256 ('0' * 64) } | Should -Throw '*does not match accepted*'
    }

    It 'canonicalizes checkout line endings and UTF-8 BOMs before fingerprinting and packaging' {
        $lfFixture = Join-Path $script:TestRoot 'lf-fixture'
        $crlfFixture = Join-Path $script:TestRoot 'crlf-fixture'
        New-BundleFixture -Destination $lfFixture
        New-BundleFixture -Destination $crlfFixture
        Set-FixtureTextFormat -Destination $lfFixture -LineEnding LF -EmitBom $false
        Set-FixtureTextFormat -Destination $crlfFixture -LineEnding CRLF -EmitBom $true

        $lf = & $script:Builder -Version v0.1.0 -RepositoryRoot $lfFixture -OutputDirectory (Join-Path $script:TestRoot 'lf-out')
        $crlf = & $script:Builder -Version v0.1.0 -RepositoryRoot $crlfFixture -OutputDirectory (Join-Path $script:TestRoot 'crlf-out')
        $lf.ArchiveSha256 | Should -BeExactly $crlf.ArchiveSha256
        $lf.RuntimeFingerprint | Should -BeExactly $crlf.RuntimeFingerprint
        [Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($lf.ArchivePath), [byte[]][IO.File]::ReadAllBytes($crlf.ArchivePath)) | Should -BeTrue

        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($crlf.ArchivePath)
        try {
            $entry = $archive.GetEntry('bootstrap.ps1')
            $stream = $entry.Open()
            try {
                $memory = New-Object IO.MemoryStream
                try {
                    $stream.CopyTo($memory)
                    $bytes = $memory.ToArray()
                }
                finally { $memory.Dispose() }
            }
            finally { $stream.Dispose() }
            ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) | Should -BeFalse
            ([Text.Encoding]::UTF8.GetString($bytes).Contains("`r")) | Should -BeFalse
        }
        finally { $archive.Dispose() }
    }

    It 'rejects forbidden extensions and executable magic even under a text name' {
        $extensionFixture = Join-Path $script:TestRoot 'extension-fixture'
        New-BundleFixture -Destination $extensionFixture
        [IO.File]::WriteAllBytes((Join-Path $extensionFixture 'resources\payload.exe'), [byte[]](0x4d, 0x5a))
        { & $script:Builder -Version v0.1.0 -RepositoryRoot $extensionFixture -OutputDirectory (Join-Path $script:TestRoot 'extension-out') } | Should -Throw '*forbidden extension*'

        $magicFixture = Join-Path $script:TestRoot 'magic-fixture'
        New-BundleFixture -Destination $magicFixture
        [IO.File]::WriteAllBytes((Join-Path $magicFixture 'resources\payload.md'), [byte[]](0x4d, 0x5a, 0x41, 0x42))
        { & $script:Builder -Version v0.1.0 -RepositoryRoot $magicFixture -OutputDirectory (Join-Path $script:TestRoot 'magic-out') } | Should -Throw '*forbidden Windows PE*'

        $encodingFixture = Join-Path $script:TestRoot 'encoding-fixture'
        New-BundleFixture -Destination $encodingFixture
        [IO.File]::WriteAllBytes((Join-Path $encodingFixture 'resources\payload.md'), [byte[]](0xc3, 0x28))
        { & $script:Builder -Version v0.1.0 -RepositoryRoot $encodingFixture -OutputDirectory (Join-Path $script:TestRoot 'encoding-out') } | Should -Throw '*not valid UTF-8*'
    }
}
