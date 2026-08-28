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
        }
        finally { $archive.Dispose() }
    }

    It 'fails when the output directory already exists or accepted hash differs' {
        $existing = Join-Path $script:TestRoot 'existing'
        [void][IO.Directory]::CreateDirectory($existing)
        { & $script:Builder -Version v0.1.0 -OutputDirectory $existing } | Should -Throw '*already exists*'
        { & $script:Builder -Version v0.1.0 -OutputDirectory (Join-Path $script:TestRoot 'wrong-hash') -ExpectedArchiveSha256 ('0' * 64) } | Should -Throw '*does not match accepted*'
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
    }
}
