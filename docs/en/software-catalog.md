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
| `nomachine` | NoMachine Free Server | pinned 9.8.2; do not install v10 with changed trial semantics |
| `bandizip` | Bandizip Standard | WinGet `Bandisoft.Bandizip`; the free edition may contain advertising |
| `bing-wallpaper` | Bing Wallpaper | WinGet `Microsoft.BingWallpaper` |
| `wsl2-ubuntu` | WSL2 + Ubuntu 24.04 LTS | enable/install last; never reboot or first-launch automatically |
| `obsidian` | Obsidian | WinGet `Obsidian.Obsidian` |
| `cc-switch` | CC Switch | WinGet `farion1231.CC-Switch`; no third-party API/key configuration |

Ordinary applications are presence-only and are never upgraded by this tool. RealVNC v8+ and NoMachine v10+ produce `NonCompliant`. Fixed versions, URLs, hashes, and signer policy require a reviewed catalog change. Clash subscription, account sign-in, RealVNC authorization, NetSarang license confirmation, and Ubuntu user creation remain manual. Proprietary installers are never committed or attached to a Release.

The current v0.1 catalog has automated providers for 14 entries. Xftp, Xshell, and RealVNC Viewer deliberately keep execution disabled because complete seed trust metadata cannot be guessed.
