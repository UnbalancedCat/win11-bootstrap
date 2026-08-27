# 软件目录

机器事实源是 `catalog/apps.psd1`；本页解释用户可见策略。安装前仍需接受各厂商许可证。

| Key | 目标 | 策略 |
|---|---|---|
| `chrome` | Google Chrome | WinGet `Google.Chrome` |
| `clash-verge-rev` | Clash Verge Rev | 当前使用 WinGet `ClashVergeRev.ClashVergeRev`；直装自举在固定 URL、哈希和签名元数据审查前保持关闭 |
| `xftp` | Xftp 8 Home/School | 当前返回 `ManualActionRequired`；仅符合个人/教育许可者，完整种子元数据审查后才能启用 `SeedDirectory` |
| `xshell` | Xshell 8 Home/School | 当前返回 `ManualActionRequired`；许可和安全策略同 Xftp |
| `git` | Git for Windows | WinGet `Git.Git` |
| `codex-desktop` | ChatGPT/Codex Windows 桌面应用 | Microsoft Store `9PLM9XGG6VKS`，不是 `OpenAI.Codex` CLI |
| `vscode` | Visual Studio Code | WinGet `Microsoft.VisualStudioCode` |
| `intellij-idea` | IntelliJ IDEA 统一发行版 | WinGet `JetBrains.IntelliJIDEA`；学生 Ultimate 由账号授权 |
| `realvnc-server` | RealVNC Server v7 | 固定审核版本 7.18.0（包版本 7.18.0.14）；不允许 v8 回退/替代 |
| `realvnc-viewer` | RealVNC Classic Viewer v7 | 目标 7.18.1；当前返回 `ManualActionRequired`，完整 Portal 种子元数据审查后才能启用 `SeedDirectory` |
| `netease-cloudmusic` | 网易云音乐 | WinGet `NetEase.CloudMusic` |
| `nomachine` | NoMachine Free Server | 固定 9.8.2；不安装会转为付费试用语义的 v10 |
| `bandizip` | Bandizip Standard | WinGet `Bandisoft.Bandizip`，免费版可能含广告 |
| `bing-wallpaper` | Bing Wallpaper | WinGet `Microsoft.BingWallpaper` |
| `wsl2-ubuntu` | WSL2 + Ubuntu 24.04 LTS | 功能启用与发行版安装；最后执行，不自动重启/首启 |
| `obsidian` | Obsidian | WinGet `Obsidian.Obsidian` |
| `cc-switch` | CC Switch | WinGet `farion1231.CC-Switch`；不自动配置第三方 API 或密钥 |

## 版本规则

普通软件只判断“是否已安装”，不由脚本升级。RealVNC 与 NoMachine 具有额外主版本门禁：发现 RealVNC v8+ 或 NoMachine v10+ 时返回 `NonCompliant`，不卸载、不覆盖、不降级。固定包的版本、URL、SHA-256 或签名策略只能通过经过测试和审查的目录变更更新。

当前 v0.1 目录中 14 项具有自动 Provider，Xftp、Xshell 和 RealVNC Viewer 3 项因缺少不可臆造的完整种子信任元数据而明确关闭自动执行。

## 人工步骤

Clash 订阅、ChatGPT/JetBrains/RealVNC 登录、RealVNC 授权、Xftp/Xshell 许可确认和 Ubuntu 用户创建不属于自动化范围。需要门户权限的专有安装器不会提交到仓库或 Release。
