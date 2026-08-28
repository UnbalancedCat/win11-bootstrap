# 架构

## 组件

- `bootstrap.ps1`：稳定 CLI、参数绑定、模块加载、一次性自提权和进程退出码。
- `src/Win11Bootstrap.psm1`：配置解析、选择、检测、网络、WinGet、自定义安装、WSL、日志和结果汇总。
- `catalog/apps.psd1`：仅数据的应用目录，使用 `Import-PowerShellDataFile` 加载。
- `schemas/config.schema.json`：对外 JSON 配置契约。
- `tests/`：Pester 行为测试及不依赖第三方模块的仓库验证器。

## 数据流

1. 解析 CLI 和 JSON，拒绝未知字段/key。
2. 计算选择集合：默认全部，配置 `only`，CLI `Only` 覆盖，所有 `skip` 最后移除。
3. `WhatIf` 保持普通权限；真实执行先把配置解析为规范选项并对运行文件生成 SHA-256 清单，然后只触发一次 UAC。
4. 提权后的固定 loader 把清单文件复制到受限的 ProgramData 随机快照，逐项复验后从快照启动实际入口；原始配置文件不会在权限边界另一侧重新读取。
5. 加载目录并运行独立检测器；受保护的更高主版本先产生 `NonCompliant`。
6. 输出计划并确认。
7. 确保 WinGet 可用，随后按 Clash、普通软件、WSL 的顺序执行。
8. 每个安装先直连，只有网络类失败才尝试已验证的进程级代理。
9. 汇总稳定状态、写入脱敏日志并返回最高严重度退出码。

## 幂等性

完成状态来自系统事实而非历史状态文件。检测综合 WinGet 精确 ID、卸载注册表、AppX、命令、Windows 功能和 WSL 发行版。检测到任何既有版本时不会调用升级；RealVNC v8+ 和 NoMachine v10+ 是策略冲突而不是升级目标。

## Provider 边界

- `Winget`：精确 ID，可选固定版本，自动接受源/包协议，不使用 `upgrade`。
- `Store`：通过精确 Store ID 和 `msstore` 源安装。
- `ManualOrSeed`：只有目录提供完整固定文件名、SHA-256、签名发布者以及所需静默参数时才执行种子包；否则返回人工步骤。
- `Wsl`：仅处理 WSL2 所需功能和 Ubuntu 24.04 LTS，绝不自动重启或启动发行版交互。
- 任何 `Safety.Ready = false` 的条目：在 Provider 分派前失败关闭并返回目录指定的人工或安全状态。

Provider 返回结构化结果而不是直接退出；入口统一计算退出码。这使 Pester 可以模拟命令、网络和注册表，无需在 CI 真正安装软件。

## 提权和设置恢复

入口不会把用户路径拼成 PowerShell 命令。它在 UAC 前解析配置、限制参数大小，并把运行所需文件名、长度和 SHA-256 固定到 loader 清单。提权后的 loader 只接受该固定清单，在 `%ProgramData%\Win11Bootstrap\Runtime\<随机 GUID>` 中创建仅 Administrators 和 SYSTEM 可访问的非重解析点快照，复制前后都复验摘要，再由同一个已提升令牌启动快照中的入口。源文件在 UAC 等待期间被修改、既有 ProgramData 目录的 owner/DACL 不符合精确策略或安全清理失败时都会失败关闭；快照不会作为断点或缓存复用。

真实运行日志使用受相同 owner/DACL 约束的 `%ProgramData%\Win11Bootstrap\Logs`，以随机 GUID 名称和原子 `CreateNew` 创建；`WhatIf` 不创建日志。所有临时环境变量与 WinGet 代理能力在 `finally` 中恢复。脚本不修改持久 WinHTTP 代理、不存储代理凭据、不自动重启。

## 发布与验收边界

`tests/New-ReleaseBundle.ps1` 是候选 workflow 与标签 Release workflow 共用的唯一打包器。稳定、无压缩的 ZIP 只包含公开入口、示例配置、运行时模块/目录/schema/resources、选定用户文档以及仓库政策与许可证文件。它把所有文本严格解码为 UTF-8，再统一写成无 BOM、LF 换行的字节，按序数排序条目，固定时间戳和属性，随后复核解压白名单与规范化运行时指纹；因此 Git 的换行设置不能改变产物。测试、workflow、agent 指引、验收记录、发布说明、缓存、日志、二进制和嵌套归档都不进入运行 ZIP。

`tests/acceptance/` 是只存在于仓库中的黑盒夹具：调用解压候选、采集脱敏证据、比较系统观测值、验证生产安装器信任边界，并提供隔离 Gateway 故障代理。`bootstrap.ps1` 不导入它，发布包也不包含它。候选与 Release 调用同一构建器；provenance 绑定精确 ZIP，验收记录再把该 ZIP 摘要绑定到已测试的运行时指纹。
