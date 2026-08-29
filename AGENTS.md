# Repository guide for coding agents

This repository builds an idempotent Windows 11 bootstrapper. Keep this file short; detailed project knowledge lives under `docs/`.

## Read first

- Read `docs/en/architecture.md` before changing orchestration or providers.
- Read `docs/en/security-model.md` before changing downloads, proxy handling, mirrors, hashes, signatures, elevation, or logging.
- Read `docs/en/adding-software.md` before editing `catalog/apps.psd1`.
- Read `docs/en/releasing.md` before changing pinned versions or release workflows.
- Chinese documents under `docs/zh-CN/` are normative. Update the matching English document in the same change.

## Non-negotiable invariants

- Support Windows PowerShell 5.1 on Windows 11 x64.
- Preserve idempotency: detect first and never upgrade an installed application.
- Never uninstall, downgrade, auto-reboot, or choose a non-default install directory.
- Treat RealVNC major 8+ and legacy NoMachine server/Personal Edition major 10+ as `NonCompliant`; the separate Enterprise Client key is not that server product.
- Direct connections are tried first. Proxy settings must be process-scoped and restored.
- GitHub mirrors are transport only, never a trust root. Only immutable, hash-pinned assets may use an allow-listed mirror.
- Never execute a direct-download or seeded installer until required SHA-256 and Authenticode checks pass.
- Never invent a URL, checksum, publisher, silent argument, or product identifier. Fail closed when verified metadata is unavailable.
- Never commit installers, credentials, Clash subscriptions, license material, access tokens, or machine-specific configuration.
- `-WhatIf` must not elevate, download, install, enable Windows features, or persist settings.
- Logs must redact URI user info and must not contain secrets.

## Sources of truth

- `catalog/apps.psd1`: stable application keys and machine-readable install/detection policy.
- `schemas/config.schema.json`: public JSON configuration contract.
- `src/Win11Bootstrap.psm1`: orchestration and provider implementation.
- `bootstrap.ps1`: public command-line entry point only.
- `docs/zh-CN/`: normative human-facing behavior and policy.

Do not duplicate the application catalog in agent instructions. Generated or validated documentation tables must remain consistent with the catalog.

## Validation

Run from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-StaticAnalysis.ps1
Invoke-Pester -Path tests -Output Detailed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Validate-Repository.ps1
```

When PowerShell modules are unavailable, at minimum run the repository validator and parse every `.ps1`, `.psm1`, and `.psd1` file with the Windows PowerShell parser.

## Change routing

- Catalog change: update both catalog documentation pages and catalog tests.
- New provider/detector: add focused Pester tests and architecture documentation.
- Network/security change: add a failure-path test, not only a success test.
- CLI/config/status/exit-code change: update schema, both user guides, and tests.
- Release change: preserve immutable ZIP plus SHA-256 output and do not publish from pull-request jobs.

## Definition of done

- Behavior is implemented, not represented by a placeholder or unsafe fallback.
- Failure is explicit and uses the documented stable status/exit code.
- Tests cover success, already-installed, retry, and fail-closed paths as applicable.
- Chinese and English docs are synchronized.
- No unrelated files, generated caches, secrets, or downloaded binaries are committed.
