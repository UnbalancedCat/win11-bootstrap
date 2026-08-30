#requires -Version 5.1

Describe 'Acceptance evidence tooling' {
    BeforeAll {
        $script:RepositoryRoot = Split-Path $PSScriptRoot -Parent
        Import-Module (Join-Path $PSScriptRoot 'acceptance\AcceptanceTools.psm1') -Force
    }

    It 'redacts credentials, sensitive query values, and local user names' {
        $sampleText = 'Authorization: Bearer abcdefghijk https://name:password@example.test/a?token=secret-value C:\Users\Alice\file'
        $output = Protect-AcceptanceText -Text $sampleText
        $output | Should -Not -Match 'abcdefghijk|name:password|secret-value|\\Alice\\'
        $output | Should -Match '\[REDACTED\]'
        Test-AcceptanceSecretText -Text $output | Should -BeTrue
    }

    It 'rejects unredacted evidence secrets' {
        Test-AcceptanceSecretText -Text 'https://user:pass@example.test' | Should -BeFalse
        Test-AcceptanceSecretText -Text 'token=super-secret-value' | Should -BeFalse
    }

    It 'compares stable system-state structures and identifies top-level changes' {
        $network = ConvertTo-AcceptanceNetworkState -NetworkState @{
            adapters = @([pscustomobject]@{ InterfaceIndex = 7; Name = 'Lab'; InterfaceDescription = 'Lab adapter'; Status = 'Up'; MacAddress = '00-11-22-33-44-55' })
            ipv4Addresses = @([pscustomobject]@{ InterfaceIndex = 7; IPAddress = '192.168.77.10'; PrefixLength = 24 })
            ipv4Routes = @([pscustomobject]@{ InterfaceIndex = 7; DestinationPrefix = '0.0.0.0/0'; NextHop = '192.168.77.1'; RouteMetric = 5 })
            ipv4Dns = @([pscustomobject]@{ InterfaceIndex = 7; ServerAddresses = @('1.1.1.1') })
            ipv6Addresses = @([pscustomobject]@{ InterfaceIndex = 7; IPAddress = 'fe80::10'; PrefixLength = 64 })
            ipv6Routes = @([pscustomobject]@{ InterfaceIndex = 7; DestinationPrefix = 'fe80::/64'; NextHop = '::'; RouteMetric = 5 })
            ipv6Dns = @([pscustomobject]@{ InterfaceIndex = 7; ServerAddresses = @('2606:4700:4700::1111') })
        }
        $before = [pscustomobject]@{ schemaVersion = 2; os = @{ build = '1' }; proxy = @{ value = $null }; winget = @{ available = $true }; firewallProfiles = @(); network = $network }
        $same = $before | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $equal = Compare-AcceptanceSystemState -Before $before -After $same
        $equal.equal | Should -BeTrue
        $equal.beforeSha256 | Should -BeExactly $equal.afterSha256

        $after = $before | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $after.proxy.value = 'http://127.0.0.1:7897'
        $changed = Compare-AcceptanceSystemState -Before $before -After $after
        $changed.equal | Should -BeFalse
        $changed.differences | Should -Contain 'proxy'

        $networkChanged = $before | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $networkChanged.network.ipv4Routes[0].NextHop = '192.168.77.254'
        $networkDifference = Compare-AcceptanceSystemState -Before $before -After $networkChanged
        $networkDifference.equal | Should -BeFalse
        $networkDifference.differences | Should -Contain 'network'

        $ipv6Changed = $before | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $ipv6Changed.network.ipv6Routes[0].DestinationPrefix = '::/0'
        $ipv6Difference = Compare-AcceptanceSystemState -Before $before -After $ipv6Changed
        $ipv6Difference.equal | Should -BeFalse
        $ipv6Difference.differences | Should -Contain 'network'
    }

    It 'normalizes network state independently of discovery order' {
        $first = @{
            adapters = @(
                [pscustomobject]@{ InterfaceIndex = 9; Name = 'Second'; InterfaceDescription = 'Adapter B'; Status = 'Disconnected'; MacAddress = '00-11-22-33-44-66' },
                [pscustomobject]@{ InterfaceIndex = 7; Name = 'First'; InterfaceDescription = 'Adapter A'; Status = 'Up'; MacAddress = '00-11-22-33-44-55' }
            )
            ipv4Addresses = @(
                [pscustomobject]@{ InterfaceIndex = 9; IPAddress = '192.0.2.9'; PrefixLength = 24 },
                [pscustomobject]@{ InterfaceIndex = 7; IPAddress = '192.168.77.10'; PrefixLength = 24 }
            )
            ipv4Routes = @(
                [pscustomobject]@{ InterfaceIndex = 9; DestinationPrefix = '192.0.2.0/24'; NextHop = '0.0.0.0'; RouteMetric = 10 },
                [pscustomobject]@{ InterfaceIndex = 7; DestinationPrefix = '0.0.0.0/0'; NextHop = '192.168.77.1'; RouteMetric = 5 }
            )
            ipv4Dns = @(
                [pscustomobject]@{ InterfaceIndex = 9; ServerAddresses = @('9.9.9.9') },
                [pscustomobject]@{ InterfaceIndex = 7; ServerAddresses = @('8.8.8.8', '1.1.1.1') }
            )
            ipv6Addresses = @(
                [pscustomobject]@{ InterfaceIndex = 9; IPAddress = 'fe80::9'; PrefixLength = 64 },
                [pscustomobject]@{ InterfaceIndex = 7; IPAddress = 'fe80::7'; PrefixLength = 64 }
            )
            ipv6Routes = @(
                [pscustomobject]@{ InterfaceIndex = 9; DestinationPrefix = 'fe80::/64'; NextHop = '::'; RouteMetric = 10 },
                [pscustomobject]@{ InterfaceIndex = 7; DestinationPrefix = '::/0'; NextHop = 'fe80::1'; RouteMetric = 5 }
            )
            ipv6Dns = @(
                [pscustomobject]@{ InterfaceIndex = 9; ServerAddresses = @('2620:fe::fe') },
                [pscustomobject]@{ InterfaceIndex = 7; ServerAddresses = @('2606:4700:4700::1111', '2001:4860:4860::8888') }
            )
        }
        $second = @{
            adapters = @($first.adapters[1], $first.adapters[0])
            ipv4Addresses = @($first.ipv4Addresses[1], $first.ipv4Addresses[0])
            ipv4Routes = @($first.ipv4Routes[1], $first.ipv4Routes[0])
            ipv4Dns = @(
                [pscustomobject]@{ InterfaceIndex = 7; ServerAddresses = @('1.1.1.1', '8.8.8.8') },
                $first.ipv4Dns[0]
            )
            ipv6Addresses = @($first.ipv6Addresses[1], $first.ipv6Addresses[0])
            ipv6Routes = @($first.ipv6Routes[1], $first.ipv6Routes[0])
            ipv6Dns = @(
                [pscustomobject]@{ InterfaceIndex = 7; ServerAddresses = @('2001:4860:4860::8888', '2606:4700:4700::1111') },
                $first.ipv6Dns[0]
            )
        }

        $firstJson = ConvertTo-AcceptanceJson -InputObject (ConvertTo-AcceptanceNetworkState -NetworkState $first)
        $secondJson = ConvertTo-AcceptanceJson -InputObject (ConvertTo-AcceptanceNetworkState -NetworkState $second)
        $firstJson | Should -BeExactly $secondJson
        ((ConvertTo-AcceptanceNetworkState -NetworkState $first).ipv4Dns[0].ServerAddresses -join ',') | Should -BeExactly '1.1.1.1,8.8.8.8'
        ((ConvertTo-AcceptanceNetworkState -NetworkState $first).ipv6Dns[0].ServerAddresses -join ',') | Should -BeExactly '2001:4860:4860::8888,2606:4700:4700::1111'
    }

    It 'fails closed on incompatible or incomplete system-state schemas' {
        $network = [pscustomobject]@{
            adapters = @(); ipv4Addresses = @(); ipv4Routes = @(); ipv4Dns = @()
            ipv6Addresses = @(); ipv6Routes = @(); ipv6Dns = @()
        }
        $version2 = [pscustomobject]@{
            schemaVersion = 2; os = @{}; proxy = @{}; winget = @{}
            firewallProfiles = @(); network = $network
        }
        $version1 = $version2 | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $version1.schemaVersion = 1
        { Compare-AcceptanceSystemState -Before $version1 -After $version2 } | Should -Throw '*schemaVersion mismatch*'

        $unknown = $version2 | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $unknown.schemaVersion = 3
        { Compare-AcceptanceSystemState -Before $unknown -After $unknown } | Should -Throw '*Unsupported system-state schemaVersion*'

        $missingNetwork = [pscustomobject]@{
            schemaVersion = 2; os = @{}; proxy = @{}; winget = @{}; firewallProfiles = @()
        }
        { Compare-AcceptanceSystemState -Before $missingNetwork -After $version2 } | Should -Throw "*missing required field 'network'*"

        $missingIpv6 = $version2 | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $missingIpv6.network.PSObject.Properties.Remove('ipv6Routes')
        { Compare-AcceptanceSystemState -Before $missingIpv6 -After $version2 } | Should -Throw "*missing required field 'ipv6Routes'*"
    }

    It 'compares exact stable application statuses' {
        $equal = Compare-AcceptanceStatuses -Expected @{ chrome = 'Installed' } -Actual @{ chrome = 'Installed' }
        $equal.equal | Should -BeTrue
        $changed = Compare-AcceptanceStatuses -Expected @{ chrome = 'Installed'; git = 'AlreadyInstalled' } -Actual @{ chrome = 'Failed' }
        $changed.equal | Should -BeFalse
        @($changed.differences).Count | Should -Be 2
        { Compare-AcceptanceStatuses -Expected @{ chrome = 'Unknown' } -Actual @{} } | Should -Throw '*Unknown stable status*'
    }

    It 'creates a complete secret-free evidence manifest' {
        $hash = 'a' * 64
        $manifest = New-AcceptanceEvidenceManifest -ScenarioId VM-007 -CandidateCommit ('b' * 40) `
            -RuntimeFingerprint ('sha256:' + $hash) -ArchiveSha256 $hash -ToolkitCommit ('c' * 40) `
            -VmId 'vm-redacted-id' -Checkpoint 'clean' -OsBuild '26100.1' -WinGetVersion 'v1.12.0' `
            -StartedAtUtc ([datetime]'2026-08-28T00:00:00Z') -EndedAtUtc ([datetime]'2026-08-28T00:01:00Z') `
            -CommandSha256 $hash -ExitCode 30 -Statuses @{ 'trust-hash' = 'NonCompliant' } `
            -BeforeStateSha256 $hash -AfterStateSha256 $hash
        $validation = Test-AcceptanceEvidence -Manifest $manifest
        $validation.valid | Should -BeTrue
        $manifest.scenarioId | Should -BeExactly 'VM-007'
        $manifest['unexpected'] = 'value'
        (Test-AcceptanceEvidence -Manifest $manifest).valid | Should -BeFalse
    }

    It 'rejects hash and publisher mismatches at the exported production trust boundary' {
        Import-Module (Join-Path $script:RepositoryRoot 'src\Win11Bootstrap.psm1') -Force
        $fixture = Join-Path $env:SystemRoot 'System32\notepad.exe'
        $signature = Get-AuthenticodeSignature -LiteralPath $fixture
        if ($signature.Status -ne 'Valid') { Set-ItResult -Skipped -Because 'Runner has no valid signed Notepad fixture.'; return }
        $actualHash = (Get-FileHash -LiteralPath $fixture -Algorithm SHA256).Hash
        (Test-InstallerTrust -Path $fixture -ExpectedSha256 ('0' * 64) -ExpectedSignerSubject $signature.SignerCertificate.Subject).Trusted | Should -BeFalse
        (Test-InstallerTrust -Path $fixture -ExpectedSha256 $actualHash -ExpectedSignerSubject 'CN=Wrong Publisher').Trusted | Should -BeFalse
        Get-ExitCodeForResults -Results @([pscustomobject]@{ Status = 'NonCompliant' }) | Should -Be 30
    }

    It 'keeps the evidence JSON schema strict' {
        $schema = Get-Content (Join-Path $PSScriptRoot 'acceptance\evidence.schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $schema.additionalProperties | Should -BeFalse
        @($schema.required).Count | Should -Be 19
    }
}
