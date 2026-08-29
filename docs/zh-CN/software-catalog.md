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
| `nomachine-client` | NoMachine Enterprise Client | WinGet `NoMachine.NoMachine.EnterpriseClient`，固定审核版 10.0.59；免费且不过期，但只能发起连接，不能让本机接受连接 |
| `bandizip` | Bandizip Standard | WinGet `Bandisoft.Bandizip`，免费版可能含广告 |
| `bing-wallpaper` | Bing Wallpaper | WinGet `Microsoft.BingWallpaper` |
| `wsl2-ubuntu` | WSL2 + Ubuntu 24.04 LTS | 功能启用与发行版安装；最后执行，不自动重启/首启 |
| `obsidian` | Obsidian | WinGet `Obsidian.Obsidian` |
| `cc-switch` | CC Switch | WinGet `farion1231.CC-Switch`；不自动配置第三方 API 或密钥 |

## 版本规则

普通软件只判断“是否已安装”，不由脚本升级。RealVNC v8+ 与旧 NoMachine 服务端/Personal Edition v10+ 具有额外门禁：发现后返回 `NonCompliant`，不卸载、不覆盖、不降级。NoMachine Enterprise Client 是独立的纯客户端产品，不受旧服务端主版本门禁影响。固定包的版本、包 ID、URL、SHA-256 或签名策略只能通过经过测试和审查的目录变更更新；运行时不会动态跟随 `latest`。

当前 v0.1 默认菜单仍有 17 个可见软件，其中 14 项具有自动 Provider；Xftp、Xshell 和 RealVNC Viewer 3 项因缺少不可臆造的完整种子信任元数据而明确关闭自动执行。目录还保留一个不显示也不默认选择的弃用兼容 key，因此机器目录记录数大于默认菜单项数。

## 弃用兼容 key

默认选择 `nomachine-client` 时，运行时仍通过 `PolicyGuardKeys` 在计划阶段和 Provider 调用前复查旧服务端门禁；Enterprise Client 自身的 v10 被明确排除，不会触发该门禁。

`nomachine` 保留为隐藏的 `Deprecated` key，避免旧配置突然变成未知 key，但它不再安装 NoMachine Free Server，也不会静默改成语义不同的客户端：

- 已检测到旧 NoMachine v9 时返回 `AlreadyInstalled`，不升级。
- 未检测到旧版时返回 `ManualActionRequired` 和退出码 `10`，提示改用 `nomachine-client`。
- 检测到 NoMachine v10 服务端或 Personal Edition 时返回 `NonCompliant` 和退出码 `30`，不卸载、不覆盖、不降级。

NoMachine 官方说明 v10 起不再提供免费服务端，而 Enterprise Client 继续免费、不过期且仅用于发起连接，参见 [NoMachine FAQ](https://www.nomachine.com/support/faq) 与[官方知识库](https://kb.nomachine.com/AR03P00972)。官方还说明[所有产品都包含 Player](https://kb.nomachine.com/AR09F00515)，且 [Enterprise Client 也会安装 `nxservice`](https://kb.nomachine.com/AR08M00856)，所以目录不把这些共享组件当作产品身份。固定版包身份来自 [Microsoft winget-pkgs 的 10.0.59 manifest](https://github.com/microsoft/winget-pkgs/tree/master/manifests/n/NoMachine/NoMachine/EnterpriseClient/10.0.59)。

## 人工步骤

Clash 订阅、ChatGPT/JetBrains/RealVNC 登录、RealVNC 授权、Xftp/Xshell 许可确认和 Ubuntu 用户创建不属于自动化范围。需要门户权限的专有安装器不会提交到仓库或 Release。
