# 发布指南

## 发布前

1. 从一手来源重新核实所有固定包，尤其是 RealVNC v7 与 NoMachine v9。
2. 确认目录没有动态 `latest` 资产配合固定哈希、占位摘要、未知发布者或越过主版本的回退。
3. 运行 PSScriptAnalyzer、完整 Pester 和仓库验证器。
4. 在干净 Windows 11 VM 完成直连、代理二阶段、重复运行、WinGet 修复、安全失败和 WSL 重启场景；在对应 `docs/acceptance/vX.Y.Z.md` 中记录运行时指纹、VM build、ISO/镜像、日期、测试者和 HTTPS 证据链接。证据必须引用清单中的稳定场景 ID；勾选全部场景后才能将状态改为 `release-approved`。
5. 确保中英文件配对且软件表与目录一致。

## 运行时指纹

冻结待测候选后，从仓库根目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Get-RuntimeFingerprint.ps1
```

把输出的完整 `sha256:<64 个小写十六进制字符>` 写入验收文件的 `Runtime fingerprint` 字段。该指纹按序覆盖 `bootstrap.ps1`、`bootstrap.example.json` 以及 `src/`、`catalog/`、`schemas/`、`resources/` 下的全部文件；计算前严格按 UTF-8 解码，并规范为无 BOM、LF 换行，避免 Git 的本地换行设置改变身份。除 BOM/换行表示外，上述任一文件发生变化都会使既有 VM 证据失效；必须生成新指纹并重新执行 11 个稳定场景 ID。发布 ZIP 解压后的指纹必须与验收记录完全相同，ZIP SHA-256 继续约束精确归档字节。

## CI 与标签

PR 只运行验证，不发布。合并到默认分支后仍不自动创建 Release。维护者只能在已属于 `main` 历史的审查提交上创建语义化标签（从 `v0.1.0` 开始）；Release workflow 会验证这一祖先关系，然后打包源码所需文件，排除 `.git`、本地配置、日志、缓存和安装器，并生成 SHA-256 文件。

工作流产物应为不可变版本名，例如 `win11-bootstrap-v0.1.0.zip` 与相应 `.sha256`。发布说明列出目录变化、固定版本变化、人工步骤和已知限制。

发布作业先创建草稿并附加全部资产，再将草稿发布。标准 `GITHUB_TOKEN` 不具备仓库 `Administration (read)` 权限，因此工作流不依赖仓库设置查询接口；它会轮询具体 Release 对象的 `immutable` 字段。若该字段未变为 `true`，工作流会删除仍可变的 Release 并失败；自动清理失败时必须由维护者处理。

## 安全引导

README 的发布安装方法必须先调用官方 GitHub Release API，要求资产存在官方 `sha256:` digest，再下载并本地验证。API 或摘要不可用时停止。引导代码本身不得通过第三方镜像取得；Release ZIP 才能在摘要已知后使用允许的传输镜像。

## 发布权限

发布前使用 `gh auth status` 验证正确的 GitHub 账号与仓库权限。不得把令牌写入仓库、配置样例、Actions 日志或发布产物。当前环境认证无效时，只保留本地标签/产物验证，不尝试绕过认证。

## 确定性候选门禁

验收工具合并后，只能在 `main` 手动触发 Candidate。它用共享构建器连续打包两次，要求字节完全相同，上传 ZIP/摘要并生成 build provenance。下载后必须同时通过 SHA-256 与 `gh attestation verify`，再把 ZIP 摘要、运行时指纹、候选/工具 commit、workflow URL、attestation 结果、两份 ISO/build、七天内日期范围、测试者和证据 URL 写入 `docs/acceptance/vX.Y.Z.md`。

最小 ZIP 只含 `bootstrap.ps1`、`bootstrap.example.json`、`src/`、`catalog/`、`schemas/`、`resources/`、`docs/index.md`、两种语言手册、`README.md`、`CONTRIBUTING.md`、`SECURITY.md` 和 `LICENSE`；每个中央目录条目必须是 method 0（Store），压缩长度必须等于原长度。标签 workflow 使用同一脚本重建，SHA-256 不等于已验收候选就停止。因此验收 PR 只能修改白名单外文件。只有验收 PR 合并且维护者再次明确授权发布后，才能创建标签。
