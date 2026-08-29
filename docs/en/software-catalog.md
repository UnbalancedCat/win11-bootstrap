# Software catalog

The machine source of truth is `catalog/apps.psd1`; this page explains user-visible policy. Vendor licenses still apply.

| Key | Target | Policy |
|---|---|---|
| `chrome` | Google Chrome | WinGet `Google.Chrome` |
| `clash-verge-rev` | Clash Verge Rev | WinGet `ClashVergeRev.ClashVergeRev` is active; direct bootstrap stays disabled until fixed URL, hash, and signer metadata are reviewed |
| `xftp` | Xftp 8 Home/School | Currently `ManualActionRequired`; personal/education eligibility and complete reviewed seed metadata are required before `SeedDirectory` can be enabled |
| `xshell` | Xshell 8 Home/School | Currently `ManualActionRequired`; the Xftp licensing and safety policy applies |
| `git` | Git for Windows | WinGet `Git.Git` |
| `codex-desktop` | ChatGPT/Codex Windows desktop | Microsoft Store `9PLM9XGG6VKS`, not the `OpenAI.Codex` CLI |
| `vscode` | Visual Studio Code | WinGet `Microsoft.VisualStudioCode` |
| `intellij-idea` | Unified IntelliJ IDEA | WinGet `JetBrains.IntelliJIDEA`; student Ultimate is account-entitled |
| `realvnc-server` | RealVNC Server v7 | reviewed 7.18.0 (package 7.18.0.14); never substitute v8 |
| `realvnc-viewer` | RealVNC Classic Viewer v7 | target 7.18.1; currently `ManualActionRequired` until complete Portal seed metadata is reviewed for `SeedDirectory` |
| `netease-cloudmusic` | NetEase Cloud Music | WinGet `NetEase.CloudMusic` |
| `nomachine-client` | NoMachine Enterprise Client | WinGet `NoMachine.NoMachine.EnterpriseClient`, pinned to reviewed version 10.0.59; free and non-expiring, but outbound-only and unable to receive connections |
| `bandizip` | Bandizip Standard | WinGet `Bandisoft.Bandizip`; the free edition may contain advertising |
| `bing-wallpaper` | Bing Wallpaper | WinGet `Microsoft.BingWallpaper` |
| `wsl2-ubuntu` | WSL2 + Ubuntu 24.04 LTS | enable/install last; never reboot or first-launch automatically |
| `obsidian` | Obsidian | WinGet `Obsidian.Obsidian` |
| `cc-switch` | CC Switch | WinGet `farion1231.CC-Switch`; no third-party API/key configuration |

Ordinary applications are presence-only and are never upgraded by this tool. RealVNC v8+ and legacy NoMachine server/Personal Edition v10+ produce `NonCompliant`; the separate client-only NoMachine Enterprise Client is not subject to the legacy server major-version gate. Fixed versions, package IDs, URLs, hashes, and signer policy require a reviewed catalog change; runtime never follows a dynamic `latest`. Clash subscription, account sign-in, RealVNC authorization, NetSarang license confirmation, and Ubuntu user creation remain manual. Proprietary installers are never committed or attached to a Release.

The v0.1 default menu still contains 17 visible applications, with automated providers for 14. Xftp, Xshell, and RealVNC Viewer deliberately keep execution disabled because complete seed trust metadata cannot be guessed. The machine catalog also retains one hidden deprecated compatibility key, so its raw record count is greater than the default menu count.

## Deprecated compatibility key

When `nomachine-client` is selected by default, runtime still uses `PolicyGuardKeys` to evaluate the legacy server gate during planning and again before provider invocation. Enterprise Client v10 itself is explicitly excluded and does not trigger that gate.

`nomachine` remains a hidden `Deprecated` key so existing configuration does not suddenly become invalid, but it no longer installs NoMachine Free Server and is never silently repurposed as the semantically different client:

- A detected legacy NoMachine v9 installation returns `AlreadyInstalled` and is not upgraded.
- When the legacy product is absent, the result is `ManualActionRequired` with exit code `10` and guidance to use `nomachine-client`.
- A detected NoMachine v10 server or Personal Edition returns `NonCompliant` with exit code `30`; it is not uninstalled, overwritten, or downgraded.

NoMachine documents that version 10 discontinued the free server while Enterprise Client remains free, non-expiring, and connection-initiating only; see the [NoMachine FAQ](https://www.nomachine.com/support/faq) and [vendor knowledge-base article](https://kb.nomachine.com/AR03P00972). The vendor also states that [every product contains Player](https://kb.nomachine.com/AR09F00515) and that [Enterprise Client installs `nxservice`](https://kb.nomachine.com/AR08M00856), so those shared components are not treated as product identity. The pinned package identity is recorded by the [Microsoft winget-pkgs 10.0.59 manifest](https://github.com/microsoft/winget-pkgs/tree/master/manifests/n/NoMachine/NoMachine/EnterpriseClient/10.0.59).
