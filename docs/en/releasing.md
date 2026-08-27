# Release guide

## Before release

1. Revalidate every pinned package from primary sources, especially RealVNC v7 and NoMachine v9.
2. Reject dynamic `latest` assets paired with fixed hashes, placeholder digests, unknown publishers, or cross-major fallback.
3. Run PSScriptAnalyzer, the complete Pester suite, and repository validation.
4. Exercise direct, staged proxy, idempotent rerun, WinGet repair, security failure, and WSL restart scenarios in a clean Windows 11 VM. Record the runtime fingerprint, VM build/image, date, tester, and HTTPS evidence URL in the matching `docs/acceptance/vX.Y.Z.md`. Evidence must cite the checklist's stable scenario IDs; only after every scenario is complete may its status become `release-approved`.
5. Confirm bilingual file pairing and catalog/documentation consistency.

## Runtime fingerprint

After freezing the candidate to be tested, run this command from the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Get-RuntimeFingerprint.ps1
```

Copy the complete `sha256:<64 lowercase hexadecimal characters>` output into the acceptance file's `Runtime fingerprint` field. The fingerprint canonically covers `bootstrap.ps1`, `bootstrap.example.json`, and every file under `src/`, `catalog/`, `schemas/`, and `resources/`. A change to any covered file invalidates existing VM evidence; generate a new fingerprint and rerun all 11 stable scenario IDs. The fingerprint computed from the extracted Release ZIP must exactly match the acceptance record.

## CI and tags

Pull requests validate only and never publish. Merging the default branch also does not create a Release. A maintainer may create a semantic version tag, beginning with `v0.1.0`, only on a reviewed commit contained in `main`; the release workflow verifies that ancestry before packaging required source files. It excludes `.git`, local configuration, logs, cache, and installers, and produces a SHA-256 file.

Use immutable names such as `win11-bootstrap-v0.1.0.zip` and the matching `.sha256`. Release notes list catalog/pin changes, manual actions, and known limitations.

The publish job creates a draft, attaches every asset, and then publishes the draft. The standard `GITHUB_TOKEN` does not expose repository `Administration (read)`, so the workflow does not depend on the repository-settings endpoint. It polls the concrete Release object's `immutable` field instead. If that field does not become `true`, the workflow removes the still-mutable Release and fails; a cleanup failure requires maintainer action.

## Secure bootstrap

The README release method must query the official GitHub Release API, require the asset's official `sha256:` digest, download, and verify locally. Stop when the API or digest is unavailable. Bootstrap code itself cannot come through a third-party mirror; only the Release ZIP may use an allowed transport mirror after the digest is known.

## Publishing permission

Run `gh auth status` and verify the intended account/repository permission before publishing. Never write a token into the repository, examples, Actions logs, or artifacts. When local authentication is invalid, restrict work to local tags/artifact validation rather than bypassing authentication.
