# Security model

## Goals and non-goals

The project protects against wrong sources, transport tampering, accidental upgrade/downgrade, command injection, secret disclosure, and persistent proxy pollution. It does not guarantee that third-party software is vulnerability-free or bypass license, account, regional, or organizational policy.

## Trust hierarchy

1. Reviewed repository catalog and release tags.
2. Official GitHub API, vendor HTTPS, and official Microsoft Store/WinGet sources.
3. Catalog-pinned SHA-256 and expected Authenticode publisher.
4. GitHub transport mirrors or user seed files, usable only when level 3 already constrains identity.

`ghfast.top` and `gh-proxy.com` are allow-listed transport candidates, not trust roots. They cannot supply versions, API metadata, or digests. The release bootstrap stops when trusted metadata cannot be obtained directly from the official GitHub API.

## Acquisition and execution

- Direct networking is always first; only network-class failures can trigger proxy retry.
- URLs must use HTTPS and redirects remain subject to provider host policy.
- Files enter a protected `%ProgramData%\Win11Bootstrap\Staging\<random GUID>` directory before validation and cannot execute until validation succeeds. The directory is removed after the attempt and is not a reusable cache.
- Required SHA-256 comparisons are exact and have no ignore switch.
- Required signatures need a `Valid` Authenticode status and an allowed publisher.
- Failed files never execute; logs contain only digests, public hosts, and redacted errors.

## Proxy

Explicit `-ProxyUri` wins. Automatic candidates are limited to the system proxy and local Clash ports 7897/7890, and each must complete an HTTPS probe. Proxy state is applied to the process or current WinGet call and restored in `finally`. Persistent `netsh winhttp set proxy` and automatic Clash subscription access are prohibited.

## Elevation and command execution

The tool triggers UAC exactly once immediately before a real installation. It first resolves configuration into canonical options, so the administrator process never reopens the original JSON, and fixes the lengths and SHA-256 values of `bootstrap.ps1`, the module, catalog, and localization resource. Canonical options and the loader never enter the command line or disk and do not rely on temporary environment variables crossing UAC. They travel over a random one-use request pipe; a separate one-use result pipe carries only a fixed 41-byte result frame. Both pipes disable ACL inheritance, explicitly deny the Network SID, allow only the current user SID and SYSTEM, and are one-way. Both ends use operating-system APIs to bind each connection to the exact child PID returned by `Start-Process -Verb RunAs` and the requesting parent PID. Envelope length, SHA-256, invocation ID, version, and exact property set must all match. The result must repeat the invocation ID and contain only `0`, `10`, `20`, `30`, or `64`; it is authoritative because ShellExecute may not preserve observation of a nonzero child exit code. Timeout, early exit, trailing data, or any mismatch fails closed with no alternate transport.

The authenticated loader creates an Administrators/SYSTEM-only non-reparse snapshot under `%ProgramData%\Win11Bootstrap\Runtime\<random GUID>`, verifies each manifest item before and after copying, then starts the real script from that snapshot. Canonical options exist briefly only in the elevated client's process environment so its direct child can inherit and consume them once. A source mutation while UAC is pending, an unknown manifest entry, a path escape, or unsafe cleanup fails closed.

Existing directories under `%ProgramData%\Win11Bootstrap` are never repaired into trusted state. Their owner, protected inheritance, and exact Administrators/SYSTEM access must already match policy or execution stops, preventing inheritance of a directory handle retained by an attacker before elevation. External commands use fixed executables, argument arrays, and validated enums. Every mutation path stops before elevation when `WhatIf` is active, and `WhatIf` creates no log.

## Version gates and seed directory

RealVNC v8+ and NoMachine v10+ are policy conflicts. Automatic uninstall or downgrade is forbidden. `SeedDirectory` does not imply trust: filename, exact hash, and full Authenticode publisher must all match one catalog tuple manually reviewed for the pinned target version; runtime never guesses that target from an untrusted installer version field. Proprietary packages without that reviewed verification tuple return `ManualActionRequired`.

## Secrets and logs

The repository, schema, and logs do not accept subscription, token, or license fields. URI user info is removed before logging. Real-run logs live in restricted `%ProgramData%\Win11Bootstrap\Logs`, use unpredictable GUID-bearing names, and are atomically created with `CreateNew` so an existing file is never overwritten or followed; reading them requires administrator rights. Release artifacts exclude local config, cache, logs, and installers.

## Candidate provenance and private evidence

Candidate and Release ZIPs are built deterministically from a strict text-file allowlist. The builder rejects dangerous extensions, executable/archive/disk-image magic, NUL-containing or non-UTF-8 input, alternate streams, path escapes, and reparse points; accepted text is canonicalized to BOM-free UTF-8 with LF endings. The archive permits only deterministic ZIP32 method 0 (Store) entries and fails closed on entry-count, size, or offset limits. It extracts its own output, compares the exact entry set, and recomputes the runtime fingerprint with the same text canonicalization. GitHub build provenance is attached to the ZIP with a full-SHA-pinned attestation action in a job whose write permissions are limited to OIDC and attestations. Consumers verify both SHA-256 and `gh attestation verify`; neither replaces the other.

Acceptance outputs are repository-external and create-new. The harness hashes command summaries instead of storing raw commands, redacts URI user info and common credential forms before writing stdout/stderr, and rejects secret-bearing evidence manifests. Gateway logs contain only time, lab client, target host/port, event, and byte count; it performs no TLS interception. Automated redaction is a guard, not authorization to publish: a human must review every Issue #1 excerpt, and any secret exposure invalidates and destroys that evidence set.
