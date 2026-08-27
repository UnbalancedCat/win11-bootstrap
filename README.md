# win11-bootstrap

[中文](#中文) | [English](#english)

## 中文

一个面向 Windows 11 x64 的可重复运行新机初始化工具。它会先检测现状，只安装缺失的软件，并保留各软件的默认安装位置。项目不会自动升级、卸载、降级或重启电脑。

> 当前状态：`v0.1.0` 实现候选，尚未发布。Xftp、Xshell、RealVNC Viewer 7.18.1 的自动种子安装以及 Clash 的直装回退，会在可信文件名、完整签名主题和精确 SHA-256 未经审查前保持关闭。

### 快速开始

要求：Windows 11 x64、Windows PowerShell 5.1、联网环境，以及可批准一次 UAC 的管理员账户。

```powershell
git clone https://github.com/UnbalancedCat/win11-bootstrap.git
Set-Location win11-bootstrap
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

无参数运行会显示 17 项软件的编号菜单，默认全选，并在执行前展示计划。常用自动化示例：

```powershell
# 只安装 Git、VS Code 和 Obsidian，显式跳过确认
.\bootstrap.ps1 -Only git,vscode,obsidian -Yes

# 使用 JSON 配置，但仍保留最终确认
.\bootstrap.ps1 -Config .\bootstrap.example.json

# 仅检测、探测网络并显示计划
.\bootstrap.ps1 -WhatIf

# 使用已经运行且经过连通性验证的本地 Clash 代理
.\bootstrap.ps1 -ProxyUri http://127.0.0.1:7897 -Yes
```

完整参数、配置格式、状态和退出码见[中文用户手册](docs/zh-CN/user-guide.md)。

也可以从[配置样例](bootstrap.example.json)开始编辑。配置文件不能包含 `-Yes`，因此不会在不知情时静默批准安装。

### 从正式 Release 安全下载

发布 `v0.1.0` 后，可使用下面的片段从官方 GitHub API 取得最新 ZIP 及其官方摘要。它要求规范的语义化版本标签，并且 Release 中恰好存在一个与该标签精确对应的 ZIP；摘要缺失或不匹配时会停止。请勿改成 `irm | iex`：

```powershell
$repository = 'UnbalancedCat/win11-bootstrap'
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/latest"
if (-not [bool]$release.immutable) {
    throw 'The latest GitHub Release is not immutable.'
}
$tag = [string]$release.tag_name
$canonicalTagPattern = '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
if ($tag -cnotmatch $canonicalTagPattern) {
    throw "GitHub returned a non-canonical release tag: $tag"
}
$expectedAssetName = "win11-bootstrap-$tag.zip"
$assetMatches = @($release.assets | Where-Object { [string]$_.name -ceq $expectedAssetName })
if ($assetMatches.Count -ne 1) {
    throw "Expected exactly one Release asset named $expectedAssetName."
}
$asset = $assetMatches[0]
if ([string]$asset.digest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
    throw 'GitHub did not provide a trusted SHA-256 digest for the release ZIP.'
}
$downloadRoot = Join-Path $env:TEMP ('win11-bootstrap-download-' + [Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $downloadRoot) {
    throw 'The random download directory unexpectedly already exists.'
}
$downloadRootItem = New-Item -ItemType Directory -Path $downloadRoot -ErrorAction Stop
if (-not $downloadRootItem.PSIsContainer -or (($downloadRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw 'The download directory is not a regular directory.'
}
$zip = Join-Path $downloadRoot $asset.name
if (Test-Path -LiteralPath $zip) {
    throw 'The release ZIP path unexpectedly already exists.'
}
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
$zipItem = Get-Item -LiteralPath $zip -Force -ErrorAction Stop
if ($zipItem.PSIsContainer -or (($zipItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
    throw 'The downloaded release ZIP is not a regular file.'
}
$expected = $asset.digest.Substring(7)
$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
if ($actual -ine $expected) { throw 'Release ZIP SHA-256 mismatch.' }
$destination = Join-Path $downloadRoot 'expanded'
if (Test-Path -LiteralPath $destination) {
    throw 'The extraction directory unexpectedly already exists.'
}
Expand-Archive -LiteralPath $zip -DestinationPath $destination
& (Join-Path $destination 'bootstrap.ps1')
```

### 代理分阶段运行

脚本始终先尝试直连。WinGet 可正常工作时会优先安装 Clash Verge Rev；若后续资源仍受限，则返回 `NeedsProxy`。请手动添加自己的订阅并确认代理可用，再次运行相同命令。当前目录没有为 Clash 启用未经签名的直装回退；WinGet 与 PSGallery 同时不可达时应先恢复系统网络或 App Installer。仓库不会保存或要求提交订阅地址。

### 安全说明

- GitHub 代理镜像仅可传输已经固定 SHA-256 的不可变 Release 资产，且不会成为版本或摘要来源。
- 直接下载或本地种子安装器必须通过目录规定的哈希和签名检查；缺少可信元数据时安全停止。
- 检测到 RealVNC v8+ 或 NoMachine v10+ 时只报告冲突，不自动降级。
- Xftp/Xshell Home/School 仅适用于满足厂商个人或教育许可条件的用户。
- OpenAI、JetBrains、RealVNC、Clash、Ubuntu 等登录、授权或首次配置仍由用户完成。

更多内容：

- [文档索引](docs/index.md)
- [软件目录](docs/zh-CN/software-catalog.md)
- [安全模型](docs/zh-CN/security-model.md)
- [故障排除](docs/zh-CN/troubleshooting.md)
- [贡献指南](CONTRIBUTING.md)

## English

`win11-bootstrap` is an idempotent Windows 11 x64 setup tool. It detects installed software first, installs only missing items into vendor-default locations, and never upgrades, uninstalls, downgrades, or automatically reboots the machine.

> Status: `v0.1.0` implementation candidate, not yet published. Seed automation for Xftp, Xshell, and RealVNC Viewer 7.18.1, plus the direct Clash fallback, remains disabled until an exact filename, full signer subject, and SHA-256 have been reviewed.

### Quick start

Requirements: Windows 11 x64, Windows PowerShell 5.1, an internet connection, and an administrator account that can approve one UAC prompt.

```powershell
git clone https://github.com/UnbalancedCat/win11-bootstrap.git
Set-Location win11-bootstrap
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

Running without arguments opens a numbered 17-item menu with every item selected by default. The final plan is shown before any mutation.

```powershell
.\bootstrap.ps1 -Only git,vscode,obsidian -Yes
.\bootstrap.ps1 -Config .\bootstrap.example.json
.\bootstrap.ps1 -WhatIf
.\bootstrap.ps1 -ProxyUri http://127.0.0.1:7897 -Yes
```

See the [English user guide](docs/en/user-guide.md) for the complete CLI, configuration schema, statuses, and exit codes.

Start with [the example configuration](bootstrap.example.json) when automating selection. Config files intentionally cannot contain `-Yes`.

### Secure download from a tagged Release

After `v0.1.0` is published, use the PowerShell snippet in the Chinese section above. It obtains metadata directly from the official GitHub API, requires a canonical SemVer tag and exactly one precisely named `win11-bootstrap-$tag.zip` asset, requires the asset's official `sha256:` digest, verifies the ZIP locally, and only then starts `bootstrap.ps1`. Do not replace this with an `irm | iex` pipeline.

### Staged proxy workflow

Direct connectivity is always attempted first. When WinGet is functional, the tool installs Clash Verge Rev first and can return `NeedsProxy` for later restricted items. Configure your subscription, verify connectivity, and rerun. The current catalog does not enable an unsigned direct Clash fallback; restore networking or App Installer first when both WinGet and PSGallery are unreachable. Subscriptions are never stored in this repository.

### Security notes

- GitHub proxy mirrors can transport only immutable Release assets with a pinned SHA-256; mirrors never provide trusted version metadata or digests.
- Direct or seeded installers must satisfy catalog hash/signature policy. Missing trusted metadata causes a closed failure.
- RealVNC v8+ and NoMachine v10+ are reported as conflicts and are never downgraded.
- Xftp/Xshell Home/School installers require the user to qualify under the vendor license.
- Account sign-in, licensing, Clash subscriptions, and Ubuntu first-user setup remain manual.

More information:

- [Documentation index](docs/index.md)
- [Software catalog](docs/en/software-catalog.md)
- [Security model](docs/en/security-model.md)
- [Troubleshooting](docs/en/troubleshooting.md)
- [Contributing](CONTRIBUTING.md)

## License

Repository code and documentation are released under the [MIT License](LICENSE). Third-party applications remain subject to their own licenses and terms.
