# 增加或更新软件

## 调研顺序

1. 从厂商文档、Microsoft Store 或 WinGet 官方 manifests 核实产品身份。
2. 记录稳定 key、显示名、Provider、精确包 ID、检测信号、代理策略和人工后续操作。
3. 若使用固定直接下载，记录不可变 HTTPS URL、SHA-256、文件名、允许的 Authenticode 发布者和官方依据。
4. 验证静默安装与“不重启”参数；不能验证时使用 `Manual`，不要猜测。
5. 明确许可和地域限制，不重新分发专有安装器。

## 目录约束

`apps.psd1` 必须是可由 `Import-PowerShellDataFile` 安全读取的纯 ASCII 数据。稳定 key 使用小写 kebab-case。每项至少声明 key、英文名称、顺序、Provider、检测策略、网络策略和人工说明；中文界面名称放在使用 `\\u` 转义的本地化 JSON 中。Provider 所需字段由仓库验证器强制检查。

固定版本软件必须声明允许的主版本与精确目标版本。未提供真实的 SHA-256 或发布者时，不得填占位字符串，也不得让运行时执行该包；应显式标记为人工/种子流程。

## 检测优先级

优先使用不会启动应用的稳定信号：精确 WinGet ID、AppX/Store 包、卸载注册表 Publisher + DisplayName、可执行文件版本、Windows 功能与 WSL 列表。不要仅依赖易变化的安装路径，也不要仅用模糊名称匹配。

## 变更清单

- 更新 `catalog/apps.psd1` 和目录校验测试。
- 更新中英软件目录，新增 Provider 时还要更新架构页。
- 为已安装、缺失、网络重试、安全失败和受保护版本添加测试。
- 运行 PSScriptAnalyzer、Pester 和 `tests/Validate-Repository.ps1`。
- 在 PR 中链接一手来源，并说明旧版本、失败路径和人工步骤。
