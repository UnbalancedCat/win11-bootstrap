# Architecture

## Components

- `bootstrap.ps1`: stable CLI, parameter binding, module loading, single self-elevation, and process exit code.
- `src/Win11Bootstrap.psm1`: configuration, selection, detection, networking, WinGet, custom installation, WSL, logging, and result aggregation.
- `catalog/apps.psd1`: data-only application catalog loaded with `Import-PowerShellDataFile`.
- `schemas/config.schema.json`: public JSON configuration contract.
- `tests/`: Pester behavior tests plus a repository validator without third-party dependencies.

## Flow

1. Parse CLI/JSON and reject unknown properties or application keys.
2. Resolve selection: all by default, config `only`, CLI `Only` replacement, then all skip values.
3. Keep `WhatIf` unelevated; a real mutation first resolves configuration into canonical options and hashes the runtime files, then triggers UAC exactly once.
4. The fixed elevated loader copies the manifest files into a restricted randomized ProgramData snapshot, verifies every copy, and starts the real entry point there. It never reopens the original config across the privilege boundary.
5. Run independent detectors and surface protected-major conflicts first.
6. Show and confirm the plan.
7. Ensure WinGet, then run Clash, ordinary applications, and WSL in that order.
8. Try direct networking first; only network failures may use a verified process-scoped proxy.
9. Aggregate stable statuses, write a redacted log, and return the highest-severity exit code.

## Idempotency

Completion comes from current system facts, not a history file. Detection combines exact WinGet IDs, uninstall registry entries, AppX packages, commands, Windows features, and WSL distro state. Any installed version prevents an upgrade. RealVNC v8+ and NoMachine v10+ are policy conflicts, not upgrade targets.

## Provider boundaries

- `Winget`: exact ID, optional pinned version, agreement flags, and never `upgrade`.
- `Store`: installs through an exact Store ID and the `msstore` source.
- `ManualOrSeed`: executes a seed only when the catalog contains the complete pinned filename, SHA-256, signer, and required silent arguments; otherwise it returns an actionable manual step.
- `Wsl`: handles only the WSL2 prerequisites and Ubuntu 24.04 LTS; it never reboots or launches interactive first setup.
- Any entry with `Safety.Ready = false`: fails closed before provider dispatch and returns the catalog-defined manual or security status.

Providers return structured results rather than exiting. This lets Pester mock commands, network, and registry state without installing software in CI.

## Elevation and restoration

The entry point never interpolates user paths into PowerShell source. Before UAC it resolves configuration, bounds option sizes, and fixes runtime filenames, lengths, and SHA-256 values in the loader manifest. The elevated loader accepts only that manifest, creates a non-reparse snapshot under `%ProgramData%\Win11Bootstrap\Runtime\<random GUID>` that only Administrators and SYSTEM can access, verifies hashes before and after copying, and starts the snapshotted entry point with the same elevated token. A source change while UAC is pending, a pre-existing ProgramData directory whose owner/DACL does not exactly match policy, or unsafe cleanup fails closed. Snapshots are never reused as checkpoints or cache.

Real-run logs use `%ProgramData%\Win11Bootstrap\Logs` with the same owner/DACL policy and are created atomically under GUID-bearing names with `CreateNew`; `WhatIf` creates no log. Temporary environment and WinGet proxy state is restored in `finally`. Persistent WinHTTP proxy, credentials, and automatic reboot are out of scope.

## Release and acceptance boundary

`tests/New-ReleaseBundle.ps1` is the single package builder for candidate and tagged Release workflows. Its stable, uncompressed ZIP contains only the public entry point, example config, runtime module/catalog/schema/resources, selected user documentation, and repository policy/license files. It strictly decodes every text input as UTF-8 and writes canonical BOM-free LF bytes. Its built-in deterministic ZIP32 writer emits ordinal method 0 (Store) entries with fixed headers, DOS epoch, attributes, and CRC32 values. It then verifies the extracted allowlist and canonical runtime fingerprint, so neither Git settings nor compression-library versions can change the artifact. Tests, workflows, agent guidance, acceptance records, release notes, caches, logs, and every binary or nested archive are outside the runtime ZIP.

`tests/acceptance/` is a repository-only black-box harness. It invokes the extracted candidate, captures redacted evidence, compares system observations, tests the production installer trust boundary, and supplies the isolated Gateway fault proxy. It is never imported by `bootstrap.ps1` and is never packaged. Candidate and Release jobs call the same builder; provenance describes the exact ZIP, while the acceptance record binds that ZIP hash to the tested runtime fingerprint.
