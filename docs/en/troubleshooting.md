# Troubleshooting

## Exit code 64

Verify that JSON contains only allowed properties, application keys exist in the catalog, `proxyUri` is an absolute HTTP/HTTPS URI without user info, query, or fragment components, and `seedDirectory` exists. Use `-WhatIf` to inspect the resolved plan without elevation.

## WinGet is unavailable

The tool checks WinGet, re-registers/resets App Installer, and can install `Microsoft.WinGet.Client` to run `Repair-WinGetPackageManager -AllUsers`. The Clash direct-download fallback remains fail-closed in v0.1 because complete pinned-hash and signer metadata is not yet available. If Store, PSGallery, and WinGet are all unreachable, repair networking or manually install and configure Clash from an official trusted channel, then rerun. Do not download a purported WinGet installer from an unknown site.

## `NeedsProxy`

Open Clash Verge Rev, add your subscription, and confirm that it can reach the public host shown in the failure. Rerun the same selection. A listening port alone is insufficient; the tool validates actual HTTPS connectivity.

## `ManualActionRequired`

Typical causes are RealVNC Classic Viewer Portal access, NetSarang license download, Store organizational policy, or required sign-in. Follow the result guidance. A local package in `SeedDirectory` executes only when exact reviewed verification metadata already exists.

## `NonCompliant`

RealVNC v8+, NoMachine v10+, a hash/signature mismatch, or a source-policy violation was detected. There is no automatic ignore, uninstall, or downgrade. Decide manually after backup and license/security review, then rerun if appropriate.

## WSL needs a restart

`NeedsRestart` never reboots the machine. Save work, restart manually, and run the same command. Creating the Linux user on the first Ubuntu launch is an expected manual step.

## Logs

Inspect the newest file under `%ProgramData%\Win11Bootstrap\Logs` from an administrator PowerShell; `WhatIf` does not create a log. Redact personal paths and network-environment detail before sharing. Never attach subscriptions, tokens, licenses, or installers. `%ProgramData%\Win11Bootstrap\Staging` and `Runtime` are restricted temporary areas, not caches to collect or reuse.
