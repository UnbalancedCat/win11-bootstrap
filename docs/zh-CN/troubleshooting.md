# 故障排除

## 退出码 64

检查 JSON 是否只有允许字段、软件 key 是否来自软件目录、`proxyUri` 是否为不含用户信息/查询/fragment 的绝对 HTTP/HTTPS URI，以及 `seedDirectory` 是否存在。使用 `-WhatIf` 可以在不提权的情况下复查计划。

## WinGet 不可用

脚本依次尝试检测、重新注册/重置 App Installer，以及通过 `Microsoft.WinGet.Client` 执行 `Repair-WinGetPackageManager -AllUsers`。v0.1 的 Clash 直接下载回退尚未具备完整的固定哈希与签名元数据，因此保持安全关闭。如果 Microsoft Store、PSGallery 和 WinGet 同时不可达，请先修复系统网络或仅从官方可信渠道手动安装并配置 Clash，再次运行。不要从未知站点下载所谓 WinGet 安装包。

## 自提权失败

请从普通（非管理员）Windows PowerShell 启动脚本并正常确认唯一一次 UAC；不要通过预先以管理员身份启动 `bootstrap.ps1` 绕过自提权测试。取消 UAC 或普通传输故障返回 20，PID、摘要或信封结构不匹配等安全拒绝返回 30。`WhatIf` 不创建日志；真实运行只有在安全快照入口开始后才创建 `%ProgramData%\Win11Bootstrap\Logs`。在非正式 VM 中，可从匹配的工具提交运行 `tests\acceptance\Invoke-SelfElevationProbe.ps1 -CandidateRoot <解压候选目录>`：它选择并跳过同一个软件，不调用安装 Provider，但会真实触发一次 UAC 并要求退出 0。若失败，只用管理员 PowerShell 检查 `%ProgramData%\Win11Bootstrap` 下是否存在 `Runtime`/`Logs` 以及受限目录的时间信息，不要公开目录内容或通过管理员直启继续真实安装。

## `NeedsProxy`

打开 Clash Verge Rev，添加自己的订阅并确认代理能够访问失败日志中的公开主机。随后使用相同选择重跑。仅看到 7897/7890 端口监听并不代表代理可用；脚本会验证 HTTPS。

## `ManualActionRequired`

常见原因包括 RealVNC Classic Viewer 需要 Portal 权限、Xftp/Xshell 许可下载、Microsoft Store 被组织策略禁用，或应用需要登录。按照结果中的提示完成操作；若提供本地安装器，放入 `SeedDirectory`，但只有目录已有精确验证元数据时脚本才会执行。

## `NonCompliant`

发现 RealVNC v8+、NoMachine v10+、摘要/签名不匹配或来源违反策略。脚本不会提供自动忽略、卸载或降级。请人工决定保留现状，或在备份并理解许可/安全影响后自行处理，再重跑。

## WSL 需要重启

脚本返回 `NeedsRestart` 但不会重启。保存工作后自行重启，再运行相同命令。Ubuntu 安装完成后的首次启动会要求创建 Linux 用户，这是正常人工步骤。

## 查看日志

在管理员 PowerShell 中查看 `%ProgramData%\Win11Bootstrap\Logs` 中最新日志；`WhatIf` 不会生成日志。公开报告前移除个人路径和可能包含网络环境的内容；不要附加订阅、令牌、许可证或安装器。`%ProgramData%\Win11Bootstrap\Staging` 和 `Runtime` 是受限临时区，不是需要手工收集或复用的缓存。
