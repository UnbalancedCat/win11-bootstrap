# Acceptance toolkit

This directory is the repository-only toolkit for the 11 stable VM scenarios. Read the bilingual [acceptance manual](../../docs/en/acceptance.md) before using it. Never copy this directory into a candidate ZIP, and never write raw evidence into the repository.

## Tools

- `Capture-SystemState.ps1` records the OS build and the process/user/machine proxy, WinINET, WinHTTP, WinGet feature, and firewall-profile observations to a new JSON file.
- `Compare-SystemState.ps1` reports top-level state drift and before/after SHA-256 values.
- `Compare-StableStatuses.ps1` exactly compares expected and observed per-application stable statuses.
- `Invoke-ReleaseCandidate.ps1` runs the extracted candidate under Windows PowerShell 5.1 and writes only redacted stdout/stderr plus a hashed command summary.
- `Invoke-SelfElevationProbe.ps1` must start from an ordinary Windows PowerShell. Its default `Exit0` scenario selects and skips Chrome; `-Scenario Exit10` selects the fail-closed RealVNC Viewer entry and requires the candidate to preserve `ManualActionRequired` as exit 10. Each invocation exercises exactly one real UAC handoff without calling an installation provider, and the probe itself exits 0 only when the candidate result matches.
- `Test-ExplicitProxyHttps.ps1` proves an explicit process proxy can complete a real HTTPS request; a listening port alone is not success.
- `Invoke-InstallerTrustProbe.ps1` creates its signed fixture only in `%TEMP%`, invokes the exported production trust boundary for VM-007, records `Executed=false`, and exits 30.
- `Write-EvidenceManifest.ps1` checks a draft against the strict, secret-free contract in `evidence.schema.json` and refuses to overwrite output.
- `gateway/` contains the restricted, no-MITM VM-004/006 CONNECT fault proxy and its tests.

Every output path must be new and located on the private evidence VHDX. Run the candidate from an expanded, SHA-256-verified, attestation-verified ZIP. Keep the candidate and toolkit commits, workflow URL, archive digest, runtime fingerprint, VM/checkpoint/build identities, command hash, stable statuses, before/after hashes, and relevant file hashes in each manifest.

Automated redaction does not make evidence public. Inspect every file manually before posting a minimal summary to Issue #1. If a credential, subscription, token, password, license, or private identity is found, destroy the evidence and restore the clean checkpoint.
