# Adding or updating software

## Research order

1. Confirm product identity through vendor documentation, Microsoft Store, or official WinGet manifests.
2. Record a stable key, bilingual name, provider, exact package ID, detection signals, network policy, and manual follow-up.
3. For a fixed direct download, record an immutable HTTPS URL, SHA-256, filename, allowed Authenticode publisher, and primary-source evidence.
4. Verify silent and no-restart arguments. Use `Manual` instead of guessing.
5. Document license/region limits and never redistribute proprietary installers.

## Catalog constraints

`apps.psd1` must remain ASCII-only pure data loadable by `Import-PowerShellDataFile`. Keys are lower kebab-case. Every item declares its key, English name, order, provider, detection, network policy, and manual guidance; Chinese UI names live in localization JSON encoded with `\\u` escapes. Provider-specific fields are enforced by repository validation.

Protected software declares an allowed major and exact target version. Never add placeholder hashes or publishers. If trusted metadata is unavailable, encode a manual/seed flow that the runtime cannot execute until real verification data is reviewed.

Do not delete or reuse an established stable key for a functionally different product. Deprecate it with `Lifecycle = @{ State = 'Deprecated'; ReplacementKey = '<active-key>' }`: the replacement must exist and be Active; the old entry is hidden from menus and default selection but remains valid when explicitly referenced by CLI/configuration and returns actionable migration guidance. An entry without `Lifecycle` is Active.

## Detection priority

Prefer stable, non-launching signals: exact WinGet ID, AppX/Store identity, Publisher plus DisplayName in uninstall registry, executable product version, Windows feature state, and WSL distro list. Do not depend solely on a changing path or fuzzy display name. A command or service shared by different products cannot establish product identity by itself. Use `ExcludedDisplayNamePatterns` for a reviewed sibling-product exclusion when needed, and let an Active replacement use `PolicyGuardKeys` to recheck the deprecated record's protected major both during planning and at the provider boundary.

## Change checklist

- Update `catalog/apps.psd1`, validation, and both catalog pages.
- Update architecture when adding a provider.
- Test installed, missing, retry, security failure, and protected-major paths.
- Run PSScriptAnalyzer, Pester, and `tests/Validate-Repository.ps1`.
- Link primary sources in the PR and explain legacy behavior, failure paths, and manual steps.
