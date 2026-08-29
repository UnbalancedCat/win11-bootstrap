#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$failures = New-Object 'System.Collections.Generic.List[string]'

function Add-ValidationFailure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [void]$script:failures.Add($Message)
}

function Test-RequiredPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $path = Join-Path -Path $script:repositoryRoot -ChildPath $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        Add-ValidationFailure "Required path is missing: $RelativePath"
    }
}

function Test-EqualStringSequence {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Actual,

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Expected
    )

    $actualText = @($Actual) -join '|'
    $expectedText = @($Expected) -join '|'
    if ($actualText -cne $expectedText) {
        Add-ValidationFailure "$Label mismatch. Expected [$expectedText], found [$actualText]."
    }
}

function Get-CatalogApplication {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Applications,

        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    return @($Applications | Where-Object { [string]$_.Key -ceq $Key } | Select-Object -First 1)
}

$requiredPaths = @(
    'bootstrap.ps1'
    'src\Win11Bootstrap.psm1'
    'catalog\apps.psd1'
    'schemas\config.schema.json'
    'resources\strings.zh-CN.json'
    'bootstrap.example.json'
    'tests\Get-RuntimeFingerprint.ps1'
    'tests\New-ReleaseBundle.ps1'
    'tests\Invoke-StaticAnalysis.ps1'
    'tests\acceptance\AcceptanceTools.psm1'
    'tests\acceptance\README.md'
    'tests\acceptance\Invoke-SelfElevationProbe.ps1'
    'tests\acceptance\Compare-StableStatuses.ps1'
    'tests\acceptance\evidence.schema.json'
    'tests\acceptance\gateway\fault_proxy.py'
    'PSScriptAnalyzerSettings.psd1'
    'docs\index.md'
    '.github\workflows\ci.yml'
    '.github\workflows\candidate.yml'
    '.github\workflows\release.yml'
    'AGENTS.md'
    'README.md'
    'CONTRIBUTING.md'
    'SECURITY.md'
    'LICENSE'
)
foreach ($requiredPath in $requiredPaths) {
    Test-RequiredPath -RelativePath $requiredPath
}

$bundleScriptPath = Join-Path -Path $repositoryRoot -ChildPath 'tests\New-ReleaseBundle.ps1'
if (Test-Path -LiteralPath $bundleScriptPath -PathType Leaf) {
    $bundleCheckRoot = Join-Path ([IO.Path]::GetTempPath()) ('w11b-validator-' + [Guid]::NewGuid().ToString('N'))
    try {
        $firstBundle = & $bundleScriptPath -Version v0.1.0 -OutputDirectory (Join-Path $bundleCheckRoot 'first')
        $secondBundle = & $bundleScriptPath -Version v0.1.0 -OutputDirectory (Join-Path $bundleCheckRoot 'second')
        if ($firstBundle.ArchiveSha256 -cnotmatch '^[0-9a-f]{64}$' -or
            $firstBundle.ArchiveSha256 -cne $secondBundle.ArchiveSha256 -or
            -not [Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($firstBundle.ArchivePath), [byte[]][IO.File]::ReadAllBytes($secondBundle.ArchivePath))) {
            Add-ValidationFailure 'Release bundle builder is not byte-for-byte deterministic.'
        }
    }
    catch {
        Add-ValidationFailure "Release bundle validation failed: $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $bundleCheckRoot) { [IO.Directory]::Delete($bundleCheckRoot, $true) }
    }
}

$fingerprintScriptPath = Join-Path -Path $repositoryRoot -ChildPath 'tests\Get-RuntimeFingerprint.ps1'
if (Test-Path -LiteralPath $fingerprintScriptPath -PathType Leaf) {
    try {
        $firstFingerprint = @(& $fingerprintScriptPath)
        $secondFingerprint = @(& $fingerprintScriptPath)
        if ($firstFingerprint.Count -ne 1 -or
            [string]$firstFingerprint[0] -cnotmatch '^sha256:[0-9a-f]{64}$') {
            Add-ValidationFailure 'Runtime fingerprint script must emit exactly one canonical lowercase sha256 value.'
        }
        elseif ($secondFingerprint.Count -ne 1 -or
            [string]$firstFingerprint[0] -cne [string]$secondFingerprint[0]) {
            Add-ValidationFailure 'Runtime fingerprint script is not deterministic for an unchanged repository.'
        }
    }
    catch {
        Add-ValidationFailure "Runtime fingerprint generation failed: $($_.Exception.Message)"
    }
}

$readmePath = Join-Path -Path $repositoryRoot -ChildPath 'README.md'
if (Test-Path -LiteralPath $readmePath -PathType Leaf) {
    $readmeText = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
    $requiredSecureBootstrapFragments = @(
        'Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/latest"'
        'if (-not [bool]$release.immutable) {'
        '$tag = [string]$release.tag_name'
        '$canonicalTagPattern = ''^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'''
        'if ($tag -cnotmatch $canonicalTagPattern) {'
        '$expectedAssetName = "win11-bootstrap-$tag.zip"'
        '$assetMatches = @($release.assets | Where-Object { [string]$_.name -ceq $expectedAssetName })'
        'if ($assetMatches.Count -ne 1) {'
        '$asset = $assetMatches[0]'
        '$downloadRoot = Join-Path $env:TEMP (''win11-bootstrap-download-'' + [Guid]::NewGuid().ToString(''N''))'
        'if (Test-Path -LiteralPath $downloadRoot) {'
        '$downloadRootItem = New-Item -ItemType Directory -Path $downloadRoot -ErrorAction Stop'
        '$zip = Join-Path $downloadRoot $asset.name'
        'if (Test-Path -LiteralPath $zip) {'
        '$zipItem = Get-Item -LiteralPath $zip -Force -ErrorAction Stop'
        '$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash'
        '$gh = Get-Command gh.exe -ErrorAction SilentlyContinue'
        '& $gh.Source attestation verify $zip --repo $repository'
        'if ($LASTEXITCODE -ne 0) { throw ''Release ZIP build provenance verification failed.'' }'
        '$destination = Join-Path $downloadRoot ''expanded'''
    )
    foreach ($fragment in $requiredSecureBootstrapFragments) {
        if ($readmeText.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
            Add-ValidationFailure "README secure bootstrap is missing required fail-closed logic: $fragment"
        }
    }
}

$workflowDirectory = Join-Path -Path $repositoryRoot -ChildPath '.github\workflows'
if (Test-Path -LiteralPath $workflowDirectory -PathType Container) {
    foreach ($workflowFile in @(Get-ChildItem -LiteralPath $workflowDirectory -File -Include '*.yml', '*.yaml')) {
        $workflowText = Get-Content -LiteralPath $workflowFile.FullName -Raw -Encoding UTF8
        foreach ($usesMatch in [regex]::Matches($workflowText, '(?m)^\s*uses:\s*(?<target>\S+)\s*(?:#.*)?$')) {
            $target = [string]$usesMatch.Groups['target'].Value
            if ($target -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$') {
                Add-ValidationFailure "Workflow action is not pinned to one full lowercase commit SHA in '$($workflowFile.Name)': $target"
            }
        }
    }
}

$ciWorkflowPath = Join-Path -Path $repositoryRoot -ChildPath '.github\workflows\ci.yml'
if (Test-Path -LiteralPath $ciWorkflowPath -PathType Leaf) {
    $ciWorkflowText = Get-Content -LiteralPath $ciWorkflowPath -Raw -Encoding UTF8
    if ($ciWorkflowText -match '(?m)^\s*contents:\s*write\s*$' -or $ciWorkflowText -match '(?m)^\s*release\s*:') {
        Add-ValidationFailure 'PR CI must not receive write permission or publish a release.'
    }
    if ($ciWorkflowText.IndexOf('tests/Invoke-StaticAnalysis.ps1', [StringComparison]::Ordinal) -lt 0) {
        Add-ValidationFailure 'PR CI must run the repository static-analysis entry point.'
    }
    if ($ciWorkflowText.IndexOf('Import-Module Pester -RequiredVersion 5.7.1 -Force -ErrorAction Stop', [StringComparison]::Ordinal) -lt 0) {
        Add-ValidationFailure 'PR CI must explicitly import the reviewed Pester version before running tests.'
    }
    foreach ($fragment in @('acceptance-tools:', 'python3 -B -m unittest discover', 'bash -n tests/acceptance/gateway/configure_gateway.sh')) {
        if ($ciWorkflowText.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
            Add-ValidationFailure "PR CI is missing acceptance-tool validation: $fragment"
        }
    }
    if ($ciWorkflowText -match 'actions/attest@') {
        Add-ValidationFailure 'PR CI must not create an artifact attestation.'
    }
}

$candidateWorkflowPath = Join-Path -Path $repositoryRoot -ChildPath '.github\workflows\candidate.yml'
if (Test-Path -LiteralPath $candidateWorkflowPath -PathType Leaf) {
    $candidateWorkflowText = Get-Content -LiteralPath $candidateWorkflowPath -Raw -Encoding UTF8
    foreach ($fragment in @(
        'workflow_dispatch:', "'refs/heads/main'", 'tests/New-ReleaseBundle.ps1',
        'Consecutive candidate builds are not byte-for-byte deterministic.',
        'actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6',
        'id-token: write', 'attestations: write', 'artifact-metadata: write', 'retention-days: 30'
    )) {
        if ($candidateWorkflowText.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
            Add-ValidationFailure "Candidate workflow is missing required policy: $fragment"
        }
    }
    if ($candidateWorkflowText -match '(?m)^\s*push\s*:|(?m)^\s*pull_request\s*:|(?m)^\s*contents:\s*write\s*$') {
        Add-ValidationFailure 'Candidate workflow must be manual-only and must not write repository contents.'
    }
}

$releaseWorkflowPath = Join-Path -Path $repositoryRoot -ChildPath '.github\workflows\release.yml'
if (Test-Path -LiteralPath $releaseWorkflowPath -PathType Leaf) {
    $releaseWorkflowText = Get-Content -LiteralPath $releaseWorkflowPath -Raw -Encoding UTF8
    $requiredReleasePolicyFragments = @(
        "      - 'v*.*.*'"
        'needs: [validate, build]'
        'git merge-base --is-ancestor HEAD refs/remotes/origin/main'
        'GH_REPO: ${{ github.repository }}'
        'BUILD_COMMIT: ${{ needs.build.outputs.commit-sha }}'
        'tests/Invoke-StaticAnalysis.ps1'
        "'Runtime fingerprint'"
        "'Accepted archive SHA-256'"
        "'Candidate workflow run URL'"
        "'Acceptance toolkit commit'"
        "'Attestation verification'"
        "'Test date range'"
        '''VM-{0:d3}'' -f $_'
        'Get-RuntimeFingerprint.ps1'
        'tests/New-ReleaseBundle.ps1'
        '-ExpectedArchiveSha256'
        'actions/attest@1e69f48acb82d1966a394da916b4c1698aa569d6'
        'Import-Module Pester -RequiredVersion 5.7.1 -Force -ErrorAction Stop'
        'releases/tags/$version'
        'releases/$ReleaseId'
        'releases/$releaseId'
        'if ($expectedAssets.Count -ne 2)'
        'if ($actualAssets.Count -ne $expectedAssets.Count)'
        "[string]`$actualAsset.state -cne 'uploaded'"
        '[long]$actualAsset.size -ne $expected.Size'
        '[string]$actualAsset.digest -cne $expected.Digest'
        'Assert-ExpectedTagCommit'
        '& gh release create $version $archive $checksum `'
        '--verify-tag --draft --notes-file $notes --title $version'
        "--method PATCH `"repos/`$env:GH_REPO/releases/`$releaseId`" -F 'draft=false'"
        '--method DELETE "repos/$env:GH_REPO/releases/$releaseId"'
        'if ([bool]$cleanupRelease.immutable)'
        'no deletion was attempted and maintainer action is required'
    )
    foreach ($fragment in $requiredReleasePolicyFragments) {
        if ($releaseWorkflowText.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
            Add-ValidationFailure "Release workflow is missing required fail-closed policy: $fragment"
        }
    }
    if ([regex]::Matches($releaseWorkflowText, '(?m)^\s*contents:\s*write\s*$').Count -ne 1) {
        Add-ValidationFailure 'Release workflow must grant contents: write exactly once, in the publish job.'
    }
    if ($releaseWorkflowText -match '(?i)\bSelect-Object\s+-First\b|\bSelect\s+-First\b|gh\s+release\s+delete\b') {
        Add-ValidationFailure 'Release workflow must not use ambiguous first-match selection or tag-based Release deletion.'
    }
    if ([regex]::Matches($releaseWorkflowText, [regex]::Escape('releases/tags/$version')).Count -ne 1) {
        Add-ValidationFailure 'Release workflow must capture the Release ID exactly once from the exact-tag endpoint.'
    }
    $releaseCreatePattern = '(?m)^\s*& gh release create \$version \$archive \$checksum `\s*$'
    if ([regex]::Matches($releaseWorkflowText, $releaseCreatePattern).Count -ne 1) {
        Add-ValidationFailure 'Release creation must upload exactly the ZIP and checksum; release notes are body text only.'
    }
}

$codeFiles = @(
    Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') }
)
foreach ($file in $codeFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    foreach ($parseError in @($parseErrors)) {
        $relative = $file.FullName.Substring($repositoryRoot.Length).TrimStart('\')
        Add-ValidationFailure ("PowerShell parse error in {0} at {1}:{2}: {3}" -f
            $relative,
            $parseError.Extent.StartLineNumber,
            $parseError.Extent.StartColumnNumber,
            $parseError.Message)
    }
}

# Windows PowerShell 5.1 treats UTF-8 without a BOM as the active ANSI code
# page. Keep executable PowerShell and JSON resources ASCII-only; localized
# strings belong in JSON as Unicode escape sequences.
$asciiFiles = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
foreach ($file in $codeFiles) {
    [void]$asciiFiles.Add($file)
}
foreach ($directory in @('resources', 'schemas')) {
    $path = Join-Path -Path $repositoryRoot -ChildPath $directory
    if (Test-Path -LiteralPath $path -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $path -Recurse -File -Filter '*.json')) {
            [void]$asciiFiles.Add($file)
        }
    }
}
foreach ($file in $asciiFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $firstNonAscii = -1
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -gt 127) {
            $firstNonAscii = $index
            break
        }
    }
    if ($firstNonAscii -ge 0) {
        $relative = $file.FullName.Substring($repositoryRoot.Length).TrimStart('\')
        Add-ValidationFailure "Non-ASCII byte found in PS5.1-safe file '$relative' at byte offset $firstNonAscii."
    }
}

$catalog = $null
$catalogPath = Join-Path -Path $repositoryRoot -ChildPath 'catalog\apps.psd1'
if (Test-Path -LiteralPath $catalogPath -PathType Leaf) {
    try {
        $catalog = Import-PowerShellDataFile -LiteralPath $catalogPath -ErrorAction Stop
    }
    catch {
        Add-ValidationFailure "catalog/apps.psd1 cannot be imported by Windows PowerShell 5.1: $($_.Exception.Message)"
    }
}

$expectedActiveKeys = @(
    'chrome'
    'clash-verge-rev'
    'xftp'
    'xshell'
    'git'
    'codex-desktop'
    'vscode'
    'intellij-idea'
    'realvnc-server'
    'realvnc-viewer'
    'netease-cloudmusic'
    'nomachine-client'
    'bandizip'
    'bing-wallpaper'
    'wsl2-ubuntu'
    'obsidian'
    'cc-switch'
)
$expectedKeys = @($expectedActiveKeys + 'nomachine')

$applications = @()
if ($null -ne $catalog) {
    if ([string]$catalog.SchemaVersion -ne '1.1.0') {
        Add-ValidationFailure "Catalog SchemaVersion must be 1.1.0; found '$($catalog.SchemaVersion)'."
    }

    $applications = @($catalog.Applications)
    if ($applications.Count -ne 18) {
        Add-ValidationFailure "Catalog must contain 17 active applications and one deprecated compatibility key; found $($applications.Count)."
    }

    $orderedApplications = @($applications | Sort-Object { [int]$_.Order })
    $orderedKeys = @($orderedApplications | ForEach-Object { [string]$_.Key })
    Test-EqualStringSequence -Label 'Catalog key order' -Actual $orderedKeys -Expected $expectedKeys

    $activeApplications = @($orderedApplications | Where-Object {
        -not $_.ContainsKey('Lifecycle') -or [string]$_.Lifecycle.State -eq 'Active'
    })
    Test-EqualStringSequence -Label 'Active menu key order' -Actual @($activeApplications.Key) -Expected $expectedActiveKeys

    $orders = @($orderedApplications | ForEach-Object { [int]$_.Order })
    $expectedOrders = @(1..18 | ForEach-Object { [string]$_ })
    Test-EqualStringSequence -Label 'Catalog order values' -Actual @($orders | ForEach-Object { [string]$_ }) -Expected $expectedOrders

    $uniqueKeys = @($applications | ForEach-Object { [string]$_.Key } | Sort-Object -Unique)
    if ($uniqueKeys.Count -ne $applications.Count) {
        Add-ValidationFailure 'Catalog application keys must be unique.'
    }
    $uniqueOrders = @($applications | ForEach-Object { [int]$_.Order } | Sort-Object -Unique)
    if ($uniqueOrders.Count -ne $applications.Count) {
        Add-ValidationFailure 'Catalog menu Order values must be unique.'
    }
    $uniqueInstallOrders = @($applications | ForEach-Object { [int]$_.InstallOrder } | Sort-Object -Unique)
    if ($uniqueInstallOrders.Count -ne $applications.Count) {
        Add-ValidationFailure 'Catalog InstallOrder values must be unique.'
    }

    $requiredApplicationFields = @(
        'Key', 'Name', 'Order', 'InstallOrder', 'InstallPhase', 'InstallerType',
        'RequiresNetwork', 'ProxyPolicy', 'WingetId', 'WingetSource',
        'WingetVersion', 'StoreProductId', 'Detection', 'WindowsFeatures',
        'VersionPolicy', 'ManualActions', 'Safety'
    )
    $requiredDetectionFields = @(
        'DisplayNamePatterns', 'Commands', 'AppxNames', 'Services', 'WslDistribution'
    )
    $requiredVersionFields = @(
        'Mode', 'TargetVersion', 'AllowedMajor', 'RejectMajorAtOrAbove'
    )

    foreach ($app in $applications) {
        $key = [string]$app.Key
        if ($key -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
            Add-ValidationFailure "Catalog key is not lower kebab-case: '$key'."
        }
        foreach ($field in $requiredApplicationFields) {
            if (-not $app.ContainsKey($field)) {
                Add-ValidationFailure "Catalog application '$key' is missing required field '$field'."
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$app.Name)) {
            Add-ValidationFailure "Catalog application '$key' has an empty Name."
        }
        if ([int]$app.InstallOrder -lt 1) {
            Add-ValidationFailure "Catalog application '$key' has an invalid InstallOrder."
        }
        if ([string]$app.InstallPhase -notin @('ProxyBootstrap', 'Standard', 'Final')) {
            Add-ValidationFailure "Catalog application '$key' has an invalid InstallPhase '$($app.InstallPhase)'."
        }
        if ([string]$app.InstallerType -notin @('Winget', 'Store', 'ManualOrSeed', 'Wsl')) {
            Add-ValidationFailure "Catalog application '$key' has an invalid InstallerType '$($app.InstallerType)'."
        }
        if (-not ($app.RequiresNetwork -is [bool])) {
            Add-ValidationFailure "Catalog application '$key' RequiresNetwork must be boolean."
        }
        if ([string]$app.ProxyPolicy -ne 'DirectThenAutoProxy') {
            Add-ValidationFailure "Catalog application '$key' must use DirectThenAutoProxy."
        }
        if (-not ($app.WindowsFeatures -is [System.Array])) {
            Add-ValidationFailure "Catalog application '$key' WindowsFeatures must be an array."
        }
        if (-not ($app.ManualActions -is [System.Array])) {
            Add-ValidationFailure "Catalog application '$key' ManualActions must be an array."
        }

        if (-not ($app.Detection -is [System.Collections.IDictionary])) {
            Add-ValidationFailure "Catalog application '$key' Detection must be a data hashtable."
        }
        else {
            foreach ($field in $requiredDetectionFields) {
                if (-not $app.Detection.ContainsKey($field)) {
                    Add-ValidationFailure "Catalog application '$key' Detection is missing '$field'."
                }
            }
            foreach ($arrayField in @('DisplayNamePatterns', 'Commands', 'AppxNames', 'Services')) {
                if (-not ($app.Detection[$arrayField] -is [System.Array])) {
                    Add-ValidationFailure "Catalog application '$key' Detection.$arrayField must be an array."
                }
            }
            if ($app.Detection.ContainsKey('ExcludedDisplayNamePatterns') -and
                -not ($app.Detection.ExcludedDisplayNamePatterns -is [System.Array])) {
                Add-ValidationFailure "Catalog application '$key' Detection.ExcludedDisplayNamePatterns must be an array."
            }
        }

        if ($app.ContainsKey('PolicyGuardKeys')) {
            if (-not ($app.PolicyGuardKeys -is [System.Array])) {
                Add-ValidationFailure "Catalog application '$key' PolicyGuardKeys must be an array."
            }
            else {
                foreach ($guardKey in @($app.PolicyGuardKeys)) {
                    $guard = @(Get-CatalogApplication -Applications $applications -Key ([string]$guardKey))
                    if ([string]::IsNullOrWhiteSpace([string]$guardKey) -or
                        [string]$guardKey -ieq $key -or
                        $guard.Count -ne 1 -or
                        [string]$guard[0].VersionPolicy.RejectMajorAtOrAbove -notmatch '^\d+$') {
                        Add-ValidationFailure "Catalog application '$key' has invalid policy guard '$guardKey'."
                    }
                }
            }
        }

        if (-not ($app.VersionPolicy -is [System.Collections.IDictionary])) {
            Add-ValidationFailure "Catalog application '$key' VersionPolicy must be a data hashtable."
        }
        else {
            foreach ($field in $requiredVersionFields) {
                if (-not $app.VersionPolicy.ContainsKey($field)) {
                    Add-ValidationFailure "Catalog application '$key' VersionPolicy is missing '$field'."
                }
            }
            if ([string]$app.VersionPolicy.Mode -notin @('AnyInstalled', 'ProtectedMajor')) {
                Add-ValidationFailure "Catalog application '$key' has an invalid version policy mode."
            }
        }

        if (-not ($app.Safety -is [System.Collections.IDictionary]) -or
            -not $app.Safety.ContainsKey('Ready') -or
            -not ($app.Safety.Ready -is [bool])) {
            Add-ValidationFailure "Catalog application '$key' Safety.Ready must be boolean."
        }

        if ($app.ContainsKey('Lifecycle')) {
            if (-not ($app.Lifecycle -is [System.Collections.IDictionary])) {
                Add-ValidationFailure "Catalog application '$key' Lifecycle must be a data hashtable."
            }
            else {
                $lifecycleFields = @($app.Lifecycle.Keys | ForEach-Object { [string]$_ } | Sort-Object)
                $unknownLifecycleFields = @($lifecycleFields | Where-Object { $_ -notin @('ReplacementKey', 'State') })
                if ($unknownLifecycleFields.Count -gt 0) {
                    Add-ValidationFailure "Catalog application '$key' has unknown Lifecycle fields: $($unknownLifecycleFields -join ', ')."
                }
                $state = [string]$app.Lifecycle.State
                if ($state -notin @('Active', 'Deprecated')) {
                    Add-ValidationFailure "Catalog application '$key' has invalid Lifecycle.State '$state'."
                }
                $replacementKey = [string]$app.Lifecycle.ReplacementKey
                if ($state -eq 'Deprecated') {
                    $replacement = @(Get-CatalogApplication -Applications $applications -Key $replacementKey)
                    if ([string]::IsNullOrWhiteSpace($replacementKey) -or
                        $replacementKey -ieq $key -or
                        $replacement.Count -ne 1 -or
                        ($replacement[0].ContainsKey('Lifecycle') -and [string]$replacement[0].Lifecycle.State -eq 'Deprecated') -or
                        [bool]$app.Safety.Ready) {
                        Add-ValidationFailure "Deprecated catalog application '$key' must be unready and reference a different active replacement."
                    }
                }
                elseif (-not [string]::IsNullOrWhiteSpace($replacementKey)) {
                    Add-ValidationFailure "Active catalog application '$key' cannot declare a replacement key."
                }
            }
        }

        switch ([string]$app.InstallerType) {
            'Winget' {
                if ([string]::IsNullOrWhiteSpace([string]$app.WingetId)) {
                    Add-ValidationFailure "WinGet application '$key' has no WingetId."
                }
                if ([string]$app.WingetSource -ne 'winget') {
                    Add-ValidationFailure "WinGet application '$key' must use source 'winget'."
                }
                if (-not [bool]$app.Safety.Ready) {
                    Add-ValidationFailure "WinGet application '$key' unexpectedly has Safety.Ready=false."
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$app.WingetVersion) -and
                    [string]$app.WingetVersion -ne [string]$app.VersionPolicy.TargetVersion) {
                    Add-ValidationFailure "Pinned WinGet version and target version differ for '$key'."
                }
            }
            'Store' {
                if ([string]::IsNullOrWhiteSpace([string]$app.StoreProductId) -or
                    [string]$app.StoreProductId -cne [string]$app.WingetId) {
                    Add-ValidationFailure "Store application '$key' must have matching StoreProductId and WingetId."
                }
                if (@($app.Detection.AppxNames).Count -eq 0) {
                    Add-ValidationFailure "Store application '$key' needs a local AppX identity for side-effect-free detection."
                }
                if ([string]$app.WingetSource -ne 'msstore') {
                    Add-ValidationFailure "Store application '$key' must use source 'msstore'."
                }
                if (-not [bool]$app.Safety.Ready) {
                    Add-ValidationFailure "Store application '$key' unexpectedly has Safety.Ready=false."
                }
            }
            'ManualOrSeed' {
                if (-not $app.ContainsKey('Seed')) {
                    Add-ValidationFailure "ManualOrSeed application '$key' is missing its Seed contract."
                }
                else {
                    foreach ($field in @('FileName', 'Sha256', 'SignerSubject', 'SilentArgs')) {
                        if (-not $app.Seed.ContainsKey($field)) {
                            Add-ValidationFailure "ManualOrSeed application '$key' Seed is missing '$field'."
                        }
                    }
                    if ($app.Seed.ContainsKey('SilentArgs') -and -not ($app.Seed.SilentArgs -is [System.Array])) {
                        Add-ValidationFailure "ManualOrSeed application '$key' Seed.SilentArgs must be an array."
                    }
                    $seedValues = @([string]$app.Seed.FileName, [string]$app.Seed.Sha256, [string]$app.Seed.SignerSubject)
                    $metadataCount = @($seedValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
                    if ($metadataCount -notin @(0, 3)) {
                        Add-ValidationFailure "ManualOrSeed application '$key' has partial seed trust metadata."
                    }
                    if ([bool]$app.Safety.Ready -and $metadataCount -ne 3) {
                        Add-ValidationFailure "ManualOrSeed application '$key' cannot be ready without complete seed trust metadata."
                    }
                    if ($metadataCount -eq 3 -and [string]$app.Seed.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
                        Add-ValidationFailure "ManualOrSeed application '$key' has an invalid seed SHA-256."
                    }
                    if ([bool]$app.Safety.Ready) {
                        $seedExtension = [IO.Path]::GetExtension([string]$app.Seed.FileName).ToLowerInvariant()
                        if ($seedExtension -notin @('.exe', '.msi')) {
                            Add-ValidationFailure "Ready ManualOrSeed application '$key' must use a reviewed EXE or MSI filename."
                        }
                        $silentArgs = if ($app.Seed.ContainsKey('SilentArgs')) { @($app.Seed.SilentArgs) } else { @() }
                        if ($seedExtension -eq '.exe' -and $silentArgs.Count -eq 0) {
                            Add-ValidationFailure "Ready EXE seed application '$key' needs reviewed silent arguments."
                        }
                    }
                    elseif ([string]$app.Safety.FailureStatus -ne 'ManualActionRequired' -or
                        [string]::IsNullOrWhiteSpace([string]$app.Safety.FailureReason)) {
                        Add-ValidationFailure "Unready ManualOrSeed application '$key' must fail closed with an explanation."
                    }
                }
            }
            'Wsl' {
                if ([string]::IsNullOrWhiteSpace([string]$app.Detection.WslDistribution)) {
                    Add-ValidationFailure "WSL application '$key' has no distribution name."
                }
                if (@($app.Detection.Commands).Count -ne 0) {
                    Add-ValidationFailure "WSL application '$key' must not treat the inbox wsl.exe command as installed-state evidence."
                }
                $requiredFeatures = @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')
                Test-EqualStringSequence -Label "WSL features for $key" -Actual @($app.WindowsFeatures | Sort-Object) -Expected @($requiredFeatures | Sort-Object)
                if (-not [bool]$app.Safety.Ready) {
                    Add-ValidationFailure "WSL application '$key' unexpectedly has Safety.Ready=false."
                }
            }
        }
    }

    $notReadyKeys = @(
        $applications |
            Where-Object { -not [bool]$_.Safety.Ready } |
            ForEach-Object { [string]$_.Key } |
            Sort-Object
    )
    $expectedNotReady = @('nomachine', 'realvnc-viewer', 'xftp', 'xshell' | Sort-Object)
    Test-EqualStringSequence -Label 'Fail-closed application keys' -Actual $notReadyKeys -Expected $expectedNotReady
    foreach ($app in @($applications | Where-Object { -not [bool]$_.Safety.Ready })) {
        if ([string]$app.Safety.FailureStatus -ne 'ManualActionRequired') {
            Add-ValidationFailure "Fail-closed application '$($app.Key)' must use ManualActionRequired."
        }
        if ([string]::IsNullOrWhiteSpace([string]$app.Safety.FailureReason)) {
            Add-ValidationFailure "Fail-closed application '$($app.Key)' needs a FailureReason."
        }
        $seedValues = @([string]$app.Seed.FileName, [string]$app.Seed.Sha256, [string]$app.Seed.SignerSubject)
        $nonEmptySeedValues = @($seedValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($nonEmptySeedValues.Count -notin @(0, 3)) {
            Add-ValidationFailure "Fail-closed application '$($app.Key)' has partial seed trust metadata."
        }
        if ($nonEmptySeedValues.Count -eq 3 -and [string]$app.Seed.Sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            Add-ValidationFailure "Fail-closed application '$($app.Key)' has an invalid seed SHA-256."
        }
    }

    $expectedMirrors = @('ghfast.top', 'gh-proxy.com')
    Test-EqualStringSequence -Label 'GitHub mirror allow-list' -Actual @($catalog.MirrorHosts) -Expected $expectedMirrors

    $realVncServer = @(Get-CatalogApplication -Applications $applications -Key 'realvnc-server')
    if ($realVncServer.Count -eq 1) {
        $app = $realVncServer[0]
        if ([string]$app.WingetId -ne 'RealVNC.VNCServer' -or
            [string]$app.WingetVersion -ne '7.18.0.14' -or
            [string]$app.VersionPolicy.TargetVersion -ne '7.18.0.14' -or
            [string]$app.VersionPolicy.AllowedMajor -ne '7' -or
            [string]$app.VersionPolicy.RejectMajorAtOrAbove -ne '8') {
            Add-ValidationFailure 'RealVNC Server must remain pinned to reviewed v7 package 7.18.0.14 and reject v8+.'
        }
    }

    $realVncViewer = @(Get-CatalogApplication -Applications $applications -Key 'realvnc-viewer')
    if ($realVncViewer.Count -eq 1) {
        $app = $realVncViewer[0]
        if ([string]$app.VersionPolicy.TargetVersion -ne '7.18.1' -or
            [string]$app.VersionPolicy.AllowedMajor -ne '7' -or
            [string]$app.VersionPolicy.RejectMajorAtOrAbove -ne '8' -or
            -not [string]::IsNullOrWhiteSpace([string]$app.WingetVersion) -or
            [bool]$app.Safety.Ready) {
            Add-ValidationFailure 'RealVNC Viewer must target 7.18.1, reject v8+, and remain fail-closed without a fabricated WinGet version.'
        }
    }

    $noMachineClient = @(Get-CatalogApplication -Applications $applications -Key 'nomachine-client')
    if ($noMachineClient.Count -eq 1) {
        $app = $noMachineClient[0]
        if ([string]$app.InstallerType -ne 'Winget' -or
            [string]$app.WingetId -ne 'NoMachine.NoMachine.EnterpriseClient' -or
            [string]$app.WingetVersion -ne '10.0.59' -or
            [string]$app.VersionPolicy.Mode -ne 'AnyInstalled' -or
            [string]$app.VersionPolicy.TargetVersion -ne '10.0.59' -or
            -not [string]::IsNullOrWhiteSpace([string]$app.VersionPolicy.RejectMajorAtOrAbove) -or
            (@($app.PolicyGuardKeys) -join '|') -cne 'nomachine' -or
            (@($app.Detection.DisplayNamePatterns) -join '|') -cne 'NoMachine Enterprise Client*' -or
            @($app.Detection.Commands).Count -ne 0) {
            Add-ValidationFailure 'NoMachine Enterprise Client must remain pinned to the reviewed dedicated WinGet package 10.0.59 with product-specific detection.'
        }
    }

    $legacyNoMachine = @(Get-CatalogApplication -Applications $applications -Key 'nomachine')
    if ($legacyNoMachine.Count -eq 1) {
        $app = $legacyNoMachine[0]
        if ([string]$app.InstallerType -ne 'ManualOrSeed' -or
            [string]$app.WingetId -ne 'NoMachine.NoMachine' -or
            -not [string]::IsNullOrWhiteSpace([string]$app.WingetVersion) -or
            [string]$app.VersionPolicy.TargetVersion -ne '9.8.2' -or
            [string]$app.VersionPolicy.AllowedMajor -ne '9' -or
            [string]$app.VersionPolicy.RejectMajorAtOrAbove -ne '10' -or
            [string]$app.Lifecycle.State -ne 'Deprecated' -or
            [string]$app.Lifecycle.ReplacementKey -ne 'nomachine-client' -or
            (@($app.Detection.ExcludedDisplayNamePatterns) -join '|') -cne 'NoMachine Enterprise Client*' -or
            @($app.Detection.Services).Count -ne 0 -or
            [bool]$app.Safety.Ready) {
            Add-ValidationFailure 'The legacy NoMachine server key must stay deprecated, unready, and gated against server v10+.'
        }
    }

    $clash = @(Get-CatalogApplication -Applications $applications -Key 'clash-verge-rev')
    if ($clash.Count -eq 1 -and [bool]$clash[0].Safety.DirectFallbackReady) {
        Add-ValidationFailure 'Clash direct-download fallback must stay disabled until immutable URL, SHA-256, and signer metadata are reviewed.'
    }
}

$schema = $null
$schemaPath = Join-Path -Path $repositoryRoot -ChildPath 'schemas\config.schema.json'
if (Test-Path -LiteralPath $schemaPath -PathType Leaf) {
    try {
        $schema = Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Add-ValidationFailure "schemas/config.schema.json is not valid JSON: $($_.Exception.Message)"
    }
}
if ($null -ne $schema) {
    if ([bool]$schema.additionalProperties) {
        Add-ValidationFailure 'Config schema additionalProperties must be false.'
    }
    $expectedProperties = @('noGitHubMirrors', 'only', 'proxyUri', 'seedDirectory', 'skip' | Sort-Object)
    $actualProperties = @($schema.properties.PSObject.Properties.Name | Sort-Object)
    Test-EqualStringSequence -Label 'Config schema properties' -Actual $actualProperties -Expected $expectedProperties
    $proxySchema = $schema.properties.proxyUri
    if ([string]$proxySchema.pattern -cne '^(?!.*[?#])(?!https?://[^/]*@)https?://') {
        Add-ValidationFailure 'Config schema must reject proxy user info, query, and fragment components before runtime.'
    }
    if ([int]$schema.properties.only.minItems -ne 1) {
        Add-ValidationFailure 'Config only array must require at least one application key.'
    }
    if ($null -ne $schema.properties.skip.PSObject.Properties['minItems'] -and
        [int]$schema.properties.skip.minItems -gt 0) {
        Add-ValidationFailure 'Config skip array must allow an empty array.'
    }

    $defsProperty = $schema.PSObject.Properties['$defs']
    if ($null -eq $defsProperty) {
        Add-ValidationFailure 'Config schema is missing $defs.'
    }
    else {
        $schemaKeys = @($defsProperty.Value.applicationKeys.items.enum | ForEach-Object { [string]$_ } | Sort-Object)
        Test-EqualStringSequence -Label 'Catalog/schema application keys' -Actual $schemaKeys -Expected @($expectedKeys | Sort-Object)
        if (-not [bool]$defsProperty.Value.applicationKeys.uniqueItems) {
            Add-ValidationFailure 'Config application key arrays must require uniqueItems.'
        }
    }
}

$zhDirectory = Join-Path -Path $repositoryRoot -ChildPath 'docs\zh-CN'
$enDirectory = Join-Path -Path $repositoryRoot -ChildPath 'docs\en'
$expectedDocNames = @(
    'acceptance.md'
    'adding-software.md'
    'architecture.md'
    'releasing.md'
    'security-model.md'
    'software-catalog.md'
    'troubleshooting.md'
    'user-guide.md'
)
if (-not (Test-Path -LiteralPath $zhDirectory -PathType Container)) {
    Add-ValidationFailure 'Chinese documentation directory docs/zh-CN is missing.'
}
if (-not (Test-Path -LiteralPath $enDirectory -PathType Container)) {
    Add-ValidationFailure 'English documentation directory docs/en is missing.'
}
if ((Test-Path -LiteralPath $zhDirectory -PathType Container) -and
    (Test-Path -LiteralPath $enDirectory -PathType Container)) {
    $zhDocs = @(Get-ChildItem -LiteralPath $zhDirectory -File -Filter '*.md' | ForEach-Object { $_.Name } | Sort-Object)
    $enDocs = @(Get-ChildItem -LiteralPath $enDirectory -File -Filter '*.md' | ForEach-Object { $_.Name } | Sort-Object)
    Test-EqualStringSequence -Label 'Chinese documentation filenames' -Actual $zhDocs -Expected @($expectedDocNames | Sort-Object)
    Test-EqualStringSequence -Label 'English documentation filenames' -Actual $enDocs -Expected @($expectedDocNames | Sort-Object)
    Test-EqualStringSequence -Label 'Bilingual documentation parity' -Actual $zhDocs -Expected $enDocs
    foreach ($file in @(Get-ChildItem -LiteralPath $zhDirectory, $enDirectory -File -Filter '*.md')) {
        if ($file.Length -eq 0) {
            Add-ValidationFailure "Documentation file is empty: $($file.FullName.Substring($repositoryRoot.Length).TrimStart('\'))"
        }
    }

    foreach ($catalogDocument in @(
        (Join-Path $zhDirectory 'software-catalog.md'),
        (Join-Path $enDirectory 'software-catalog.md')
    )) {
        if (-not (Test-Path -LiteralPath $catalogDocument -PathType Leaf)) {
            continue
        }
        $catalogText = Get-Content -LiteralPath $catalogDocument -Raw -Encoding UTF8
        foreach ($key in $expectedKeys) {
            if ($catalogText -notmatch [regex]::Escape(('`{0}`' -f $key))) {
                Add-ValidationFailure "Software catalog documentation '$catalogDocument' does not mention key '$key'."
            }
        }
    }
}

# Validate local Markdown links without requiring a network connection. Strip
# anchors before resolving targets; external schemes are intentionally skipped.
$markdownFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File -Filter '*.md')
foreach ($markdownFile in $markdownFiles) {
    $markdownText = Get-Content -LiteralPath $markdownFile.FullName -Raw -Encoding UTF8
    foreach ($linkMatch in [regex]::Matches($markdownText, '!?(?:\[[^\]]*\])\((?<target>[^)]+)\)')) {
        $target = [string]$linkMatch.Groups['target'].Value
        $target = $target.Trim().Trim('<', '>')
        if ([string]::IsNullOrWhiteSpace($target) -or
            $target.StartsWith('#') -or
            $target -match '^(?i:https?|mailto):') {
            continue
        }
        $pathPart = ($target -split '#', 2)[0]
        if ([string]::IsNullOrWhiteSpace($pathPart)) {
            continue
        }
        try {
            $pathPart = [Uri]::UnescapeDataString($pathPart)
        }
        catch {
            Write-Debug 'A Markdown link target could not be URI-decoded; validating its literal form.'
        }
        $resolvedTarget = Join-Path -Path $markdownFile.DirectoryName -ChildPath $pathPart
        if (-not (Test-Path -LiteralPath $resolvedTarget)) {
            $relativeSource = $markdownFile.FullName.Substring($repositoryRoot.Length).TrimStart('\')
            Add-ValidationFailure "Broken local Markdown link in '$relativeSource': '$target'."
        }
    }
}

$exampleConfigPath = Join-Path $repositoryRoot 'bootstrap.example.json'
if (Test-Path -LiteralPath $exampleConfigPath -PathType Leaf) {
    try {
        $exampleConfig = Get-Content -LiteralPath $exampleConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $allowedConfigProperties = @('only', 'skip', 'proxyUri', 'seedDirectory', 'noGitHubMirrors')
        foreach ($property in $exampleConfig.PSObject.Properties) {
            if ($property.Name -notin $allowedConfigProperties) {
                Add-ValidationFailure "Example config contains unsupported property '$($property.Name)'."
            }
        }
        foreach ($selectionProperty in @('only', 'skip')) {
            $property = $exampleConfig.PSObject.Properties[$selectionProperty]
            if ($null -eq $property) {
                continue
            }
            foreach ($key in @($property.Value)) {
                if ([string]$key -notin $expectedKeys) {
                    Add-ValidationFailure "Example config contains unknown application key '$key'."
                }
            }
        }
    }
    catch {
        Add-ValidationFailure "bootstrap.example.json is invalid: $($_.Exception.Message)"
    }
}

$stringsPath = Join-Path -Path $repositoryRoot -ChildPath 'resources\strings.zh-CN.json'
if (Test-Path -LiteralPath $stringsPath -PathType Leaf) {
    try {
        $strings = Get-Content -LiteralPath $stringsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $localizedKeys = @($strings.AppNames.PSObject.Properties.Name | Sort-Object)
        Test-EqualStringSequence -Label 'Localized application keys' -Actual $localizedKeys -Expected @($expectedKeys | Sort-Object)
        foreach ($property in $strings.AppNames.PSObject.Properties) {
            if ([string]::IsNullOrWhiteSpace([string]$property.Value)) {
                Add-ValidationFailure "Localized application name is empty for '$($property.Name)'."
            }
        }
    }
    catch {
        Add-ValidationFailure "resources/strings.zh-CN.json is not valid JSON: $($_.Exception.Message)"
    }
}

$forbiddenExtensions = @(
    '.exe', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle',
    '.zip', '.7z', '.rar', '.cab', '.nupkg', '.dll', '.sys', '.pfx',
    '.p12', '.pem', '.key'
)
$allFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File -Force -ErrorAction SilentlyContinue)
foreach ($file in $allFiles) {
    $relative = $file.FullName.Substring($repositoryRoot.Length).TrimStart('\')
    if ($file.Extension.ToLowerInvariant() -in $forbiddenExtensions) {
        Add-ValidationFailure "Forbidden binary, installer, archive, or key artifact is tracked in the repository: $relative"
    }
    if ($file.Name -eq '.env' -or
        $file.Name -like 'id_rsa*' -or
        $file.Name -like '*credential*' -or
        $file.Name -like '*subscription*' -or
        $file.Name -like '*access-token*' -or
        $file.Extension -in @('.pyc', '.pyo')) {
        Add-ValidationFailure "Potential secret-bearing file is present: $relative"
    }
}

$textExtensions = @('.md', '.ps1', '.psm1', '.psd1', '.json', '.yml', '.yaml', '.toml')
$secretPatterns = @(
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    '\bgithub_pat_[A-Za-z0-9_]{20,}'
    '\bgh[pousr]_[A-Za-z0-9]{20,}'
    '\bsk-[A-Za-z0-9]{20,}'
)
foreach ($file in @($allFiles | Where-Object { $_.Extension.ToLowerInvariant() -in $textExtensions })) {
    try {
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
        foreach ($pattern in $secretPatterns) {
            if ($content -match $pattern) {
                $relative = $file.FullName.Substring($repositoryRoot.Length).TrimStart('\')
                Add-ValidationFailure "Potential committed secret matched in: $relative"
                break
            }
        }
    }
    catch {
        Add-ValidationFailure "Unable to scan text file '$($file.FullName)' for secrets: $($_.Exception.Message)"
    }
}

if ($failures.Count -gt 0) {
    [Console]::Error.WriteLine("Repository validation failed with {0} issue(s):" -f $failures.Count)
    foreach ($failure in $failures) {
        [Console]::Error.WriteLine(" - {0}" -f $failure)
    }
    exit 1
}

Write-Output ("Repository validation passed: {0} applications, PS5.1-safe resources, paired documentation files, and no forbidden artifacts." -f $applications.Count)
exit 0
