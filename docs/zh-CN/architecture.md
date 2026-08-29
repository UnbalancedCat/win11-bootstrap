# 架构

## 组件

- `bootstrap.ps1`：稳定 CLI、参数绑定、模块加载、一次性自提权和进程退出码。
- `src/Win11Bootstrap.psm1`：配置解析、选择、检测、网络、WinGet、自定义安装、WSL、日志和结果汇总。
- `catalog/apps.psd1`：仅数据的应用目录，使用 `Import-PowerShellDataFile` 加载。
- `schemas/config.schema.json`：对外 JSON 配置契约。
- `tests/`：Pester 行为测试及不依赖第三方模块的仓库验证器。

## 数据流

1. 解析 CLI 和 JSON，拒绝未知字段/key。
2. 计算选择集合：默认选择全部可见的 Active 条目，配置 `only`，CLI `Only` 覆盖，所有 `skip` 最后移除。隐藏的 Deprecated key 只有被显式指定时才参与计划。
3. `WhatIf` 保持普通权限；真实执行先把配置解析为规范选项、对运行文件生成 SHA-256 清单并建立一对一次性单向本机命名管道，然后只触发一次 UAC。命令行只携带随机管道名、进程绑定信息、信封长度和摘要，不携带选项或 loader。
4. 最小化的提权客户端与普通权限父进程把两个通道分别绑定到精确进程 ID。子进程验证请求信封的精确长度、SHA-256、版本和字段集合；父进程另行验证包含同一调用 ID 和一个已记录稳定退出码的固定长度结果帧。经验证的 loader 随后把清单文件复制到受限的随机 ProgramData 快照，复验每个副本并从快照启动真实入口，绝不跨权限边界重新打开原始配置。
5. 加载目录并运行独立检测器；受保护的更高主版本先产生 `NonCompliant`。
6. 输出计划并确认。
7. 确保 WinGet 可用，随后按 Clash、普通软件、WSL 的顺序执行。
8. 每个安装先直连，只有网络类失败才尝试已验证的进程级代理。
9. 汇总稳定状态、写入脱敏日志并返回最高严重度退出码。

## 幂等性

完成状态来自系统事实而非历史状态文件。检测综合 WinGet 精确 ID、卸载注册表、AppX、命令、Windows 功能和 WSL 发行版。检测到任何既有版本时不会调用升级；RealVNC v8+ 与旧 NoMachine 服务端/Personal Edition v10+ 是策略冲突而不是升级目标。NoMachine Enterprise Client v10 是独立的纯客户端产品，使用独立 key 和精确 WinGet ID，不与旧服务端门禁混为一谈。Active 条目可以声明 `PolicyGuardKeys`；运行时在普通安装检测前和真正调用 Provider 前分别复查这些受保护条目，只传播 `NonCompliant`，不自动安装或重定向守卫条目。

目录条目缺少 `Lifecycle` 时视为 Active。`Lifecycle.State = 'Deprecated'` 的条目从交互菜单和默认选择中隐藏，并通过 `Lifecycle.ReplacementKey` 给出迁移目标；其旧 key 仍可被 `-Only`、`-Skip` 和配置文件识别。弃用不会把旧 key 静默重定向到功能不同的新产品。

## Provider 边界

- `Winget`：精确 ID，可选固定版本，自动接受源/包协议，不使用 `upgrade`。
- `Store`：通过精确 Store ID 和 `msstore` 源安装。
- `ManualOrSeed`：只有目录提供完整固定文件名、SHA-256、签名发布者以及所需静默参数时才执行种子包；否则返回人工步骤。
- `Wsl`：仅处理 WSL2 所需功能和 Ubuntu 24.04 LTS，绝不自动重启或启动发行版交互。
- 任何 `Safety.Ready = false` 的条目：在 Provider 分派前失败关闭并返回目录指定的人工或安全状态。

Provider 返回结构化结果而不是直接退出；入口统一计算退出码。这使 Pester 可以模拟命令、网络和注册表，无需在 CI 真正安装软件。

## 提权和设置恢复

入口不会把用户路径拼成 PowerShell 命令，也不依赖临时进程环境变量跨越 UAC。它在 UAC 前解析配置、限制参数大小，把运行所需文件名、长度和 SHA-256 固定到 loader 清单，并建立随机的一次性请求管道与结果管道。两个管道的 ACL 都关闭继承、显式拒绝 Network SID 且只允许当前用户 SID 和 SYSTEM。父进程只向 `Start-Process -Verb RunAs` 返回的精确子 PID 发送信封，子进程也通过系统 API 验证精确父 PID。信封必须满足命令行中固定的长度、SHA-256、调用 ID 和字段集合。完成清理后，同一子进程返回固定 41 字节结果帧，其中包含调用 ID，并且状态只能是 `0`、`10`、`20`、`30` 或 `64`；父进程把结果绑定到精确子 PID，并以该认证结果为准，不依赖 ShellExecute 对非零进程退出码的观测。超时、子进程提前退出、尾随数据，或 PID、摘要、结构、调用 ID、状态任一不匹配均失败关闭，不回退到命令行、磁盘或跨 UAC 环境传参。

提权客户端只在自身进程内临时设置规范选项，供它启动的受限快照子进程继承并一次性消费。经验证的 loader 在 `%ProgramData%\Win11Bootstrap\Runtime\<随机 GUID>` 中创建仅 Administrators 和 SYSTEM 可访问的非重解析点快照，复制前后都复验摘要，再由同一个已提升令牌启动快照中的入口。源文件在 UAC 等待期间被修改、既有 ProgramData 目录的 owner/DACL 不符合精确策略或安全清理失败时都会失败关闭；快照不会作为断点或缓存复用。

真实运行日志使用受相同 owner/DACL 约束的 `%ProgramData%\Win11Bootstrap\Logs`，以随机 GUID 名称和原子 `CreateNew` 创建；`WhatIf` 不创建日志。所有临时环境变量与 WinGet 代理能力在 `finally` 中恢复。脚本不修改持久 WinHTTP 代理、不存储代理凭据、不自动重启。

## 发布与验收边界

`tests/New-ReleaseBundle.ps1` 是候选 workflow 与标签 Release workflow 共用的唯一打包器。稳定、无压缩的 ZIP 只包含公开入口、示例配置、运行时模块/目录/schema/resources、选定用户文档以及仓库政策与许可证文件。它把所有文本严格解码为 UTF-8，再统一写成无 BOM、LF 换行的字节；内置的确定性 ZIP32 写入器按序数顺序生成 method 0（Store）条目，并固定头字段、DOS epoch、属性和 CRC32。随后工具复核解压白名单与规范化运行时指纹，因此 Git 设置或压缩库版本不能改变产物。测试、workflow、agent 指引、验收记录、发布说明、缓存、日志、二进制和嵌套归档都不进入运行 ZIP。

`tests/acceptance/` 是只存在于仓库中的黑盒夹具：调用解压候选、采集脱敏证据、比较系统观测值、验证生产安装器信任边界，并提供隔离 Gateway 故障代理。`bootstrap.ps1` 不导入它，发布包也不包含它。候选与 Release 调用同一构建器；provenance 绑定精确 ZIP，验收记录再把该 ZIP 摘要绑定到已测试的运行时指纹。
