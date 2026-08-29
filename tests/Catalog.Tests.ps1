#requires -Version 5.1

Describe 'Application catalog contract' {
    BeforeAll {
        function Assert-TestEqual {
            param(
                [Parameter()]
                [AllowNull()]
                [object]$Actual,

                [Parameter()]
                [AllowNull()]
                [object]$Expected,

                [Parameter(Mandatory = $true)]
                [string]$Label
            )

            $equal = $false
            if ($null -eq $Actual -and $null -eq $Expected) {
                $equal = $true
            }
            elseif ($null -ne $Actual -and $null -ne $Expected) {
                if ($Actual -is [string] -or $Expected -is [string]) {
                    $equal = ([string]$Actual -ceq [string]$Expected)
                }
                else {
                    $equal = ($Actual -eq $Expected)
                }
            }

            if (-not $equal) {
                throw ("{0}: expected [{1}], found [{2}]." -f $Label, $Expected, $Actual)
            }
        }

        $script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
        $script:CatalogPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'catalog\apps.psd1'
        $script:SchemaPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'schemas\config.schema.json'
        $script:Catalog = Import-PowerShellDataFile -LiteralPath $script:CatalogPath
        $script:Applications = @($script:Catalog.Applications)
        $script:ExpectedActiveKeys = @(
            'chrome',
            'clash-verge-rev',
            'xftp',
            'xshell',
            'git',
            'codex-desktop',
            'vscode',
            'intellij-idea',
            'realvnc-server',
            'realvnc-viewer',
            'netease-cloudmusic',
            'nomachine-client',
            'bandizip',
            'bing-wallpaper',
            'wsl2-ubuntu',
            'obsidian',
            'cc-switch'
        )
        $script:ExpectedKeys = @($script:ExpectedActiveKeys + 'nomachine')
    }

    It 'imports as pure PowerShell data with schema 1.1.0' {
        Assert-TestEqual -Actual $script:Catalog.SchemaVersion -Expected '1.1.0' -Label 'SchemaVersion'
        Assert-TestEqual -Actual $script:Applications.Count -Expected 18 -Label 'Application count'
    }

    It 'contains 17 active keys plus the deprecated compatibility key' {
        $ordered = @($script:Applications | Sort-Object { [int]$_.Order })
        Assert-TestEqual -Actual (@($ordered.Key) -join '|') -Expected ($script:ExpectedKeys -join '|') -Label 'Ordered keys'
        Assert-TestEqual -Actual (@($ordered.Order) -join '|') -Expected ((1..18) -join '|') -Label 'Order values'
        Assert-TestEqual -Actual @($script:Applications.Key | Sort-Object -Unique).Count -Expected 18 -Label 'Unique key count'
        Assert-TestEqual -Actual @($script:Applications.InstallOrder | Sort-Object -Unique).Count -Expected 18 -Label 'Unique install-order count'

        $active = @($ordered | Where-Object {
            -not $_.ContainsKey('Lifecycle') -or [string]$_.Lifecycle.State -eq 'Active'
        })
        Assert-TestEqual -Actual (@($active.Key) -join '|') -Expected ($script:ExpectedActiveKeys -join '|') -Label 'Active menu keys'

        $deprecated = @($ordered | Where-Object {
            $_.ContainsKey('Lifecycle') -and [string]$_.Lifecycle.State -eq 'Deprecated'
        })
        Assert-TestEqual -Actual $deprecated.Count -Expected 1 -Label 'Deprecated key count'
        Assert-TestEqual -Actual $deprecated[0].Key -Expected 'nomachine' -Label 'Deprecated key'
        Assert-TestEqual -Actual $deprecated[0].Lifecycle.ReplacementKey -Expected 'nomachine-client' -Label 'Replacement key'
        Assert-TestEqual -Actual $deprecated[0].Safety.Ready -Expected $false -Label 'Deprecated readiness'
    }

    It 'provides every provider-required field and fails closed when unavailable' {
        $problems = New-Object 'System.Collections.Generic.List[string]'
        foreach ($app in $script:Applications) {
            foreach ($field in @(
                'Key', 'Name', 'Order', 'InstallOrder', 'InstallPhase',
                'InstallerType', 'RequiresNetwork', 'ProxyPolicy', 'WingetId',
                'WingetSource', 'WingetVersion', 'StoreProductId', 'Detection',
                'WindowsFeatures', 'VersionPolicy', 'ManualActions', 'Safety'
            )) {
                if (-not $app.ContainsKey($field)) {
                    [void]$problems.Add("$($app.Key) missing $field")
                }
            }

            switch ([string]$app.InstallerType) {
                'Winget' {
                    if ([string]::IsNullOrWhiteSpace([string]$app.WingetId) -or
                        [string]$app.WingetSource -ne 'winget' -or
                        -not [bool]$app.Safety.Ready) {
                        [void]$problems.Add("$($app.Key) has invalid WinGet fields")
                    }
                }
                'Store' {
                    if ([string]$app.WingetSource -ne 'msstore' -or
                        [string]$app.StoreProductId -cne [string]$app.WingetId -or
                        @($app.Detection.AppxNames).Count -eq 0 -or
                        -not [bool]$app.Safety.Ready) {
                        [void]$problems.Add("$($app.Key) has invalid Store fields")
                    }
                }
                'ManualOrSeed' {
                    if (-not $app.ContainsKey('Seed')) {
                        [void]$problems.Add("$($app.Key) has no seed contract")
                    }
                    else {
                        foreach ($field in @('FileName', 'Sha256', 'SignerSubject', 'SilentArgs')) {
                            if (-not $app.Seed.ContainsKey($field)) {
                                [void]$problems.Add("$($app.Key) seed contract is missing $field")
                            }
                        }
                        if ($app.Seed.ContainsKey('SilentArgs') -and -not ($app.Seed.SilentArgs -is [System.Array])) {
                            [void]$problems.Add("$($app.Key) seed silent arguments are not an array")
                        }
                        $seedValues = @([string]$app.Seed.FileName, [string]$app.Seed.Sha256, [string]$app.Seed.SignerSubject)
                        $metadataCount = @($seedValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
                        if ([bool]$app.Safety.Ready -and $metadataCount -ne 3) {
                            [void]$problems.Add("$($app.Key) is ready without complete seed trust metadata")
                        }
                        if ([bool]$app.Safety.Ready -and
                            [IO.Path]::GetExtension([string]$app.Seed.FileName).ToLowerInvariant() -eq '.exe' -and
                            @($app.Seed.SilentArgs).Count -eq 0) {
                            [void]$problems.Add("$($app.Key) is ready without reviewed EXE silent arguments")
                        }
                        if (-not [bool]$app.Safety.Ready -and [string]$app.Safety.FailureStatus -ne 'ManualActionRequired') {
                            [void]$problems.Add("$($app.Key) is not fail-closed")
                        }
                    }
                }
                'Wsl' {
                    if ([string]::IsNullOrWhiteSpace([string]$app.Detection.WslDistribution) -or
                        @($app.Detection.Commands).Count -ne 0 -or
                        @($app.WindowsFeatures).Count -ne 2 -or
                        -not [bool]$app.Safety.Ready) {
                        [void]$problems.Add("$($app.Key) has invalid WSL fields")
                    }
                }
                default {
                    [void]$problems.Add("$($app.Key) has unsupported InstallerType")
                }
            }
        }

        if ($problems.Count -gt 0) {
            throw ($problems -join '; ')
        }
    }

    It 'keeps the deliberate fail-closed entries explicit' {
        $actual = @(
            $script:Applications |
                Where-Object { -not [bool]$_.Safety.Ready } |
                ForEach-Object { [string]$_.Key } |
                Sort-Object
        )
        Assert-TestEqual -Actual ($actual -join '|') -Expected ((@('nomachine', 'realvnc-viewer', 'xftp', 'xshell') | Sort-Object) -join '|') -Label 'Fail-closed keys'
        foreach ($app in @($script:Applications | Where-Object { -not [bool]$_.Safety.Ready })) {
            Assert-TestEqual -Actual ([string]::IsNullOrWhiteSpace([string]$app.Safety.FailureReason)) -Expected $false -Label "$($app.Key) failure reason"
            $seedValues = @([string]$app.Seed.FileName, [string]$app.Seed.Sha256, [string]$app.Seed.SignerSubject)
            Assert-TestEqual -Actual @($seedValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -Expected 0 -Label "$($app.Key) seed metadata count"
        }
    }

    It 'pins the reviewed RealVNC and NoMachine client versions and keeps the legacy server gate' {
        $server = @($script:Applications | Where-Object Key -eq 'realvnc-server')[0]
        Assert-TestEqual -Actual $server.WingetId -Expected 'RealVNC.VNCServer' -Label 'RealVNC Server ID'
        Assert-TestEqual -Actual $server.WingetVersion -Expected '7.18.0.14' -Label 'RealVNC Server version'
        Assert-TestEqual -Actual $server.VersionPolicy.AllowedMajor -Expected '7' -Label 'RealVNC Server allowed major'
        Assert-TestEqual -Actual $server.VersionPolicy.RejectMajorAtOrAbove -Expected '8' -Label 'RealVNC Server rejected major'

        $viewer = @($script:Applications | Where-Object Key -eq 'realvnc-viewer')[0]
        Assert-TestEqual -Actual $viewer.VersionPolicy.TargetVersion -Expected '7.18.1' -Label 'RealVNC Viewer target version'
        Assert-TestEqual -Actual $viewer.WingetVersion -Expected '' -Label 'RealVNC Viewer WinGet version'
        Assert-TestEqual -Actual $viewer.VersionPolicy.AllowedMajor -Expected '7' -Label 'RealVNC Viewer allowed major'
        Assert-TestEqual -Actual $viewer.VersionPolicy.RejectMajorAtOrAbove -Expected '8' -Label 'RealVNC Viewer rejected major'
        Assert-TestEqual -Actual $viewer.Safety.Ready -Expected $false -Label 'RealVNC Viewer readiness'

        $client = @($script:Applications | Where-Object Key -eq 'nomachine-client')[0]
        Assert-TestEqual -Actual $client.WingetId -Expected 'NoMachine.NoMachine.EnterpriseClient' -Label 'NoMachine client ID'
        Assert-TestEqual -Actual $client.WingetVersion -Expected '10.0.59' -Label 'NoMachine client version'
        Assert-TestEqual -Actual $client.VersionPolicy.Mode -Expected 'AnyInstalled' -Label 'NoMachine client version policy'
        Assert-TestEqual -Actual $client.VersionPolicy.TargetVersion -Expected '10.0.59' -Label 'NoMachine client target'
        Assert-TestEqual -Actual (@($client.PolicyGuardKeys) -join '|') -Expected 'nomachine' -Label 'NoMachine client policy guard'
        Assert-TestEqual -Actual (@($client.Detection.DisplayNamePatterns) -join '|') -Expected 'NoMachine Enterprise Client*' -Label 'NoMachine client product-specific detector'
        Assert-TestEqual -Actual @($client.Detection.Commands).Count -Expected 0 -Label 'NoMachine client shared-command detector count'

        $legacy = @($script:Applications | Where-Object Key -eq 'nomachine')[0]
        Assert-TestEqual -Actual $legacy.InstallerType -Expected 'ManualOrSeed' -Label 'Legacy NoMachine provider'
        Assert-TestEqual -Actual $legacy.WingetId -Expected 'NoMachine.NoMachine' -Label 'Legacy NoMachine detection ID'
        Assert-TestEqual -Actual $legacy.WingetVersion -Expected '' -Label 'Legacy NoMachine install pin'
        Assert-TestEqual -Actual $legacy.VersionPolicy.TargetVersion -Expected '9.8.2' -Label 'Legacy NoMachine target'
        Assert-TestEqual -Actual $legacy.VersionPolicy.AllowedMajor -Expected '9' -Label 'Legacy NoMachine allowed major'
        Assert-TestEqual -Actual $legacy.VersionPolicy.RejectMajorAtOrAbove -Expected '10' -Label 'Legacy NoMachine rejected major'
        Assert-TestEqual -Actual $legacy.Lifecycle.State -Expected 'Deprecated' -Label 'Legacy NoMachine lifecycle'
        Assert-TestEqual -Actual (@($legacy.Detection.ExcludedDisplayNamePatterns) -join '|') -Expected 'NoMachine Enterprise Client*' -Label 'Legacy NoMachine exclusion'
        Assert-TestEqual -Actual @($legacy.Detection.Services).Count -Expected 0 -Label 'Legacy NoMachine shared-service detector count'
    }

    It 'keeps the config schema enum synchronized with the catalog' {
        $schema = Get-Content -LiteralPath $script:SchemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $defs = $schema.PSObject.Properties['$defs'].Value
        $schemaKeys = @($defs.applicationKeys.items.enum | Sort-Object)
        $catalogKeys = @($script:Applications.Key | Sort-Object)
        Assert-TestEqual -Actual ($schemaKeys -join '|') -Expected ($catalogKeys -join '|') -Label 'Schema/catalog keys'
        Assert-TestEqual -Actual $schema.additionalProperties -Expected $false -Label 'Schema additionalProperties'
        Assert-TestEqual -Actual @($schema.properties.PSObject.Properties.Name | Where-Object { $_ -ceq 'yes' }).Count -Expected 0 -Label 'Schema yes property count'
        Assert-TestEqual -Actual $schema.properties.only.minItems -Expected 1 -Label 'Schema only minItems'
        Assert-TestEqual -Actual @($schema.properties.skip.PSObject.Properties.Name | Where-Object { $_ -ceq 'minItems' }).Count -Expected 0 -Label 'Schema skip minItems property count'
    }

    It 'keeps Chinese and English documentation filenames paired' {
        $zh = @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'docs\zh-CN') -File -Filter '*.md' | ForEach-Object Name | Sort-Object)
        $en = @(Get-ChildItem -LiteralPath (Join-Path $script:RepositoryRoot 'docs\en') -File -Filter '*.md' | ForEach-Object Name | Sort-Object)
        Assert-TestEqual -Actual ($zh -join '|') -Expected ($en -join '|') -Label 'Bilingual documentation filenames'
        Assert-TestEqual -Actual $zh.Count -Expected 8 -Label 'Bilingual documentation file count'
    }

    It 'keeps executable files and JSON resources ASCII-only for Windows PowerShell 5.1' {
        $files = @(
            Get-ChildItem -LiteralPath $script:RepositoryRoot -Recurse -File |
                Where-Object {
                    $_.Extension -in @('.ps1', '.psm1', '.psd1') -or
                    ($_.Extension -eq '.json' -and $_.Directory.Name -in @('resources', 'schemas'))
                }
        )
        $bad = New-Object 'System.Collections.Generic.List[string]'
        foreach ($file in $files) {
            if (@([System.IO.File]::ReadAllBytes($file.FullName) | Where-Object { $_ -gt 127 }).Count -gt 0) {
                [void]$bad.Add($file.FullName)
            }
        }
        if ($bad.Count -gt 0) {
            throw ("Non-ASCII executable/resource files: {0}" -f ($bad -join ', '))
        }
    }

    It 'contains no installer, archive, binary, or private-key artifacts' {
        $forbidden = @(
            '.exe', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle',
            '.zip', '.7z', '.rar', '.cab', '.nupkg', '.dll', '.sys', '.pfx',
            '.p12', '.pem', '.key'
        )
        $found = @(
            Get-ChildItem -LiteralPath $script:RepositoryRoot -Recurse -File -Force |
                Where-Object { $_.Extension.ToLowerInvariant() -in $forbidden }
        )
        Assert-TestEqual -Actual $found.Count -Expected 0 -Label 'Forbidden artifact count'
    }
}
