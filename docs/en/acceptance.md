# Acceptance manual

## Scope and authority

This manual governs v0.1.0 Windows 11 VM acceptance. The maintainer controls Hyper-V, UAC prompts, reboots, private activation, and the one-time Clash subscription entry. The acceptance scripts collect and compare evidence but never manage Hyper-V, activate Windows, enter credentials, reboot, or publish a release. A merged acceptance PR is only a release gate; creating `v0.1.0` still requires a separate explicit instruction.

Keep raw evidence on a repository-external, dynamically expanding NTFS VHDX such as `D:\VM\win11-bootstrap-private\evidence.vhdx`. Do not attach that VHDX to GitHub. Never record accounts, license keys, tokens, passwords, subscription URLs, authorization headers, or private VM screenshots. Destroy and rerun any evidence set in which a secret is found.

## Candidate freeze

1. Merge the acceptance-tooling PR after `validate` and `acceptance-tools` pass.
2. On `main`, manually run the Candidate workflow. Download its ZIP and `.sha256` into a new evidence directory.
3. Verify both controls:

   ```powershell
   (Get-FileHash .\win11-bootstrap-v0.1.0.zip -Algorithm SHA256).Hash
   gh attestation verify .\win11-bootstrap-v0.1.0.zip --repo UnbalancedCat/win11-bootstrap
   ```

4. Expand the ZIP, run `tests/Get-RuntimeFingerprint.ps1` from the matching toolkit checkout with `-RepositoryRoot` set to the expanded directory, and record the candidate commit, workflow URL, archive SHA-256, runtime fingerprint, toolkit commit, and successful attestation result.
5. Preflight `clash-verge-rev`, `chrome`, `git`, `codex-desktop`, `realvnc-server`, and `nomachine`, then repeat the same command once. A runtime defect requires a separate PR and a new candidate. Freeze only after package IDs, Store identity, pinned versions, and manual-only sources are rechecked.

Any functional change to a runtime-whitelisted file or the acceptance toolkit invalidates every formal result. Restore the final golden checkpoint and rerun beginning with VM-011. Complete all formal scenarios within seven natural days and record the OS build for every run.

## Baselines

The Windows SUT is a Generation 2 Windows 11 Pro x64 VM with Secure Boot, vTPM, 4 vCPU, 4/8/12 GB dynamic memory, a 128 GB dynamic VHDX, Hong Kong locale/UTC+8, a local administrator, current Windows Updates, and nested virtualization. The golden checkpoint contains no candidate, toolkit, personal account, or Clash subscription.

VM-004 and VM-006 additionally use the two-NIC Ubuntu Gateway documented under `tests/acceptance/gateway/`: WAN on Default Switch, LAN on private switch `W11B-Lab`, Gateway `192.168.77.1/24`, and SUT `192.168.77.10/24`. The fixture performs no TLS interception and changes no host or SUT proxy, certificate, firewall, or WinHTTP setting.

## Evidence commands

Mount a fresh evidence VHDX directory for the scenario. Before and after each run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\Capture-SystemState.ps1 -OutputPath E:\VM-006\before.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\Invoke-ReleaseCandidate.ps1 -CandidateRoot C:\Candidate -ScenarioId VM-006 -OutputDirectory E:\VM-006\run -BootstrapArguments '-Only','chrome','-Yes'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\Capture-SystemState.ps1 -OutputPath E:\VM-006\after.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\Compare-SystemState.ps1 -BeforePath E:\VM-006\before.json -AfterPath E:\VM-006\after.json -OutputPath E:\VM-006\comparison.json
```

The runner writes redacted stdout/stderr, their hashes, the command-summary hash, timestamps, and exit code. It rejects secret-bearing arguments. `Write-EvidenceManifest.ps1` canonicalizes a completed manifest conforming to `evidence.schema.json` and refuses suspected secrets. Human review remains mandatory before a summary or screenshot is posted to Issue #1.

## Formal order and verdicts

Run in this order: VM-011, VM-001 with VM-010, VM-009, VM-002, VM-003, VM-004, VM-005, VM-006, VM-007, VM-008.

- **VM-011:** golden checkpoint, default selection with `-WhatIf -Yes`. Exit 10 is allowed only for planned manual catalog items. There must be no elevation, download, log, registry/feature/proxy change, or other state change.
- **VM-001/010:** default interactive run. Automated items install; Xftp, Xshell, and RealVNC Viewer are manual; WSL needs restart; Store may be manual only with a precise instruction. Exit 10, with no ordinary `Failed`, is expected. Verify every account/portal/license/first-run instruction.
- **VM-009:** after each manual reboot, run `-Only wsl2-ubuntu -Yes` until Ubuntu 24.04 is detected as WSL version 2. The script must not reboot, launch Ubuntu, or create a Linux user.
- **VM-002/003:** preinstall Chrome and Git with WinGet. Run `-Only chrome,git,vscode -Yes`, then repeat it. First verdict: two `AlreadyInstalled`, VS Code `Installed`, exit 0. Second: all `AlreadyInstalled`, exit 0, no installer execution.
- **VM-004:** the Gateway initially permits Clash resources and blocks the two frozen Ready targets. The first run installs Clash and returns `NeedsProxy/10` for targets. Enter the subscription only in the Clash UI with system proxy/TUN off. Verify auto-discovery on port 7897 for the first target, then explicit `-ProxyUri http://127.0.0.1:7897` for the second; each exits 0. Targets are frozen before formal runs.
- **VM-005:** from separate clean restores, establish and record one fully absent App Installer state and one supported package-present/current-user-registration-or-command failure. Repair must restore trusted WinGet and install the test package. If the current build cannot safely create the second state using supported AppX operations, release remains blocked; do not replace it with a shim or edited system file.
- **VM-006:** A listens on 7897 but rejects CONNECT/HTTPS and must yield `NeedsProxy/10`. B permits the real HTTPS probe and drops the later installer transfer, also yielding `NeedsProxy/10`. The target stays absent, and WinGet feature, WinINET, WinHTTP, environment, and firewall observations match before/after.
- **VM-007:** run `Invoke-InstallerTrustProbe.ps1` in the real VM. Its two runtime-created cases call production `Test-InstallerTrust`, return `NonCompliant/30`, and record `Executed=false`. This tests the production trust boundary, not a live-mirror end-to-end path.
- **VM-008:** in an isolated snapshot, create synthetic uninstall entries for RealVNC v8 and NoMachine v10, then invoke the real `bootstrap.ps1`. Both must be `NonCompliant/30`, with no WinGet, uninstall, overwrite, or downgrade invocation. Remove the snapshot after evidence review.

## Public record and retention

Record the candidate and toolkit commits, runtime fingerprint, archive SHA-256, VM UUID/checkpoint, OS/WinGet builds, command hash, exit/statuses, before/after hashes, file hashes, and fixture events. Post only redacted verdicts and necessary redacted screenshots to Issue #1. Keep valid raw evidence and a secret-free golden checkpoint until 30 days after v0.1.0 is published. Destroy any Clash-bearing branch immediately after evidence extraction.
