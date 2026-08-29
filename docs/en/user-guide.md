# User guide

## Requirements

- Windows 11 x64 and Windows PowerShell 5.1.
- The current account can approve one UAC prompt.
- At least one network path is available. GitHub-hosted or overseas vendor resources may require a configured Clash instance.
- The tool installs applications; account sign-in, license activation, proxy subscriptions, and Ubuntu first-user setup remain manual.

Start from a normal PowerShell window. A real installation self-elevates once; `-WhatIf` never elevates.

## Interactive mode

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

All 17 items are selected by default. Empty input accepts the default; `1,3,5-8`, `all`, and `none` are supported. Installed state is detected before the final plan and confirmation are shown.

The NoMachine entry among the 17 defaults is the outbound-only `nomachine-client`. The old `nomachine` key is deprecated and hidden from menus/default selection, but existing configuration still parses: an installed v9 is skipped; absence returns `ManualActionRequired/10` with migration guidance; a detected v10 server or Personal Edition returns `NonCompliant/30`. The tool never silently repurposes the old key as the client.

The server gate also runs when the client is part of the default selection. Enterprise Client v10 is identified separately through the product exclusion and exact WinGet ID, so it is not mistaken for the legacy server.

## Automation

```powershell
.\bootstrap.ps1 -Only git,vscode -Skip vscode -Yes
.\bootstrap.ps1 -Config C:\Setup\bootstrap.json -Yes
.\bootstrap.ps1 -ProxyUri http://127.0.0.1:7897 -Yes
.\bootstrap.ps1 -SeedDirectory C:\Setup\verified-installers -Yes
.\bootstrap.ps1 -NoGitHubMirrors -Yes
.\bootstrap.ps1 -WhatIf
```

- CLI `-Only` replaces config `only`; the baseline is all applications when neither is set.
- CLI and config `skip` values are combined, and skip always wins.
- CLI `-ProxyUri` and `-SeedDirectory` override config values.
- `proxyUri`/`-ProxyUri` accepts only an absolute HTTP/HTTPS URI without user info, query, or fragment components, keeping credentials out of native command lines and logs.
- `-NoGitHubMirrors` disables built-in GitHub Release transport mirrors.
- `-Yes` is command-line only. A config file cannot silently approve installation.
- `-WhatIf` validates, detects, probes, and plans without elevation, downloads, installation, or feature changes.

Only these JSON properties are accepted:

```json
{
  "only": ["git", "vscode", "obsidian"],
  "skip": ["obsidian"],
  "proxyUri": "http://127.0.0.1:7897",
  "seedDirectory": "C:\\Setup\\verified-installers",
  "noGitHubMirrors": true
}
```

Unknown properties/keys, a non-HTTP(S) proxy URI, or a missing seed directory produce exit code `64`.

## Reruns and proxy staging

Every run detects real system state; there is no resume-state file. Direct access is tried first. Only a declared proxy or a system/local candidate that passes an HTTPS probe is used. If Clash is not configured:

1. Let the tool install Clash Verge Rev.
2. Exit when remaining items report `NeedsProxy`.
3. Add your subscription manually and verify connectivity.
4. Run the same selection again; completed items become `AlreadyInstalled`.

Proxy state is process-scoped and restored. Persistent system and WinHTTP proxy settings are not changed.

## Status and exit codes

| Status | Meaning |
|---|---|
| `Planned` | Selected and ready |
| `AlreadyInstalled` | An installed version was detected; no upgrade |
| `Installed` | Installed during this run |
| `Skipped` | Explicitly skipped |
| `NeedsProxy` | Configure networking and rerun |
| `NeedsRestart` | Restart manually and rerun |
| `ManualActionRequired` | Sign-in, licensing, Portal download, or trusted local package is required |
| `NonCompliant` | Protected major version or security policy conflict |
| `Failed` | Ordinary download or install failure |

Exit codes are `0` complete, `10` recoverable manual step, `20` ordinary failure, `30` security/policy block, and `64` invalid usage/config. The highest-severity result wins.

## Locations, restart, and logs

No custom install location is passed. WSL2 and Ubuntu run last and never trigger an automatic restart or distro first launch. Real-run logs live under the Administrators-and-SYSTEM-only `%ProgramData%\Win11Bootstrap\Logs\`; administrator rights are required to read them. `WhatIf` creates no log. Direct downloads and seed installers use a restricted `%ProgramData%\Win11Bootstrap\Staging\<random GUID>` directory and are removed after processing; it is not a reusable cache. URI user info, subscriptions, tokens, and license material are not logged.
