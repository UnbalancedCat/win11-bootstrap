# Contributing / 贡献指南

## 中文

感谢帮助改进 `win11-bootstrap`。提交修改前请先阅读根目录 `AGENTS.md`，并根据改动类型阅读 `docs/zh-CN/` 中对应的架构、安全或扩展文档。

基本要求：

1. 从可信的一手来源核实包 ID、固定版本、下载 URL、SHA-256、签名发布者和静默参数；不要根据记忆或第三方博客填写。
2. 新软件必须具有稳定 key、独立检测策略、默认安装位置、明确的失败方式和至少一个 Pester 测试。
3. 任何镜像回退都必须绑定由官方渠道独立取得的固定摘要；禁止加入“忽略哈希”选项。
4. 修改中文文档时同步英文对应页，反之亦然。中文版本在冲突时为规范版本。
5. 不得提交安装器、账号、令牌、代理订阅、许可证、真实本机路径或包含这些内容的日志。

提交前运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-StaticAnalysis.ps1
Invoke-Pester -Path tests -Output Detailed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Validate-Repository.ps1
```

PR 应说明修改原因、可信来源、失败/回滚行为、测试结果以及是否影响公开参数或文档。

## English

Thank you for improving `win11-bootstrap`. Read the root `AGENTS.md` first, then the relevant architecture, security, or extension guide under `docs/en/`.

Requirements:

1. Verify package IDs, pinned versions, URLs, SHA-256 values, publishers, and silent arguments from primary sources. Never fill them from memory or a third-party blog.
2. A new application needs a stable key, independent detection, vendor-default location, explicit failure behavior, and at least one Pester test.
3. Mirror fallback must remain bound to a digest independently obtained from an official channel. Never add an ignore-hash option.
4. Update matching Chinese and English documentation in the same change. Chinese is normative if the two disagree.
5. Do not commit installers, accounts, tokens, proxy subscriptions, licenses, real machine paths, or logs containing them.

Run the three validation commands shown above before opening a pull request. Describe the rationale, primary sources, failure/rollback behavior, test evidence, and public interface impact in the PR.
