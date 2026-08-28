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
        $before = [pscustomobject]@{ schemaVersion = 1; os = @{ build = '1' }; proxy = @{ value = $null }; winget = @{ available = $true }; firewallProfiles = @() }
        $same = $before | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $equal = Compare-AcceptanceSystemState -Before $before -After $same
        $equal.equal | Should -BeTrue
        $equal.beforeSha256 | Should -BeExactly $equal.afterSha256

        $after = $before | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $after.proxy.value = 'http://127.0.0.1:7897'
        $changed = Compare-AcceptanceSystemState -Before $before -After $after
        $changed.equal | Should -BeFalse
        $changed.differences | Should -Contain 'proxy'
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
