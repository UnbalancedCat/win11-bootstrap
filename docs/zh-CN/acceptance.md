# 验收手册

## 范围与权限

本手册规定 v0.1.0 的 Windows 11 VM 验收。维护者负责 Hyper-V、UAC、人工重启、私下合法激活以及只在 Clash 界面中输入一次订阅；验收脚本只采集、比较证据，不管理 Hyper-V、不激活 Windows、不输入凭据、不重启，也不发布 Release。验收 PR 合并只表示发布门禁通过；创建 `v0.1.0` 仍须用户另行明确授权。

原始证据应保存到仓库外的动态扩展 NTFS VHDX，例如 `D:\VM\win11-bootstrap-private\evidence.vhdx`，不得上传该 VHDX。账号、许可证密钥、令牌、密码、订阅 URL、Authorization Header 和未脱敏的私人截图都不得进入证据或 GitHub。若发现秘密，该组证据立即销毁并从干净检查点重跑。

## 候选冻结

1. `validate` 与 `acceptance-tools` 全绿后合并验收工具 PR。
2. 在 `main` 手动触发 Candidate workflow，把 ZIP 与 `.sha256` 下载到新的证据目录。
3. 同时验证两个信任条件：

   ```powershell
   (Get-FileHash .\win11-bootstrap-v0.1.0.zip -Algorithm SHA256).Hash
   gh attestation verify .\win11-bootstrap-v0.1.0.zip --repo UnbalancedCat/win11-bootstrap
   ```

4. 解压 ZIP，用同一工具提交中的 `tests/Get-RuntimeFingerprint.ps1 -RepositoryRoot <解压目录>` 计算指纹，记录候选 commit、workflow URL、ZIP SHA-256、运行时指纹、工具 commit 和 attestation 验证结果。
5. 在普通（非管理员）Windows PowerShell 中运行匹配工具提交的 `tests\acceptance\Invoke-SelfElevationProbe.ps1 -CandidateRoot <解压候选目录>`，确认只出现一次 UAC、没有 Provider 安装且退出 0。不得用管理员直启候选来绕过失败。
6. 再预演 `clash-verge-rev`、`chrome`、`git`、`codex-desktop`、`realvnc-server`、`nomachine`，然后原命令重复一次。若发现运行时缺陷，必须另开 PR 并生成新候选。冻结前重新核查包 ID、Store 身份、固定版本和只能人工取得的来源。

运行 ZIP 白名单内文件或验收工具发生功能性变化时，全部正式证据作废，须恢复最终金检查点并从 VM-011 重跑。所有正式场景必须在七个自然日内完成，每次都记录 OS build。

## 基线

Windows SUT 是第 2 代 Windows 11 专业版 x64 VM：Secure Boot、vTPM、4 vCPU、4/8/12 GB 动态内存、128 GB 动态 VHDX、香港地区/UTC+8、本地管理员、Windows Update 已完成并重启、开启 nested virtualization。金检查点中不得有候选包、验收工具、个人账号或 Clash 订阅。

VM-004 与 VM-006 另用 `tests/acceptance/gateway/` 记录的双网卡 Ubuntu Gateway：WAN 接 Default Switch，LAN 接私有交换机 `W11B-Lab`，Gateway 为 `192.168.77.1/24`，SUT 为 `192.168.77.10/24`。夹具不做 TLS MITM，也不修改宿主机或 SUT 的代理、证书、防火墙或 WinHTTP。

## 证据命令

为每个场景挂载新的证据目录，并在执行前后采集状态：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\Capture-SystemState.ps1 -OutputPath E:\VM-006\before.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\Invoke-ReleaseCandidate.ps1 -CandidateRoot C:\Candidate -ScenarioId VM-006 -OutputDirectory E:\VM-006\run -BootstrapArguments '-Only','chrome','-Yes'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\Capture-SystemState.ps1 -OutputPath E:\VM-006\after.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\Compare-SystemState.ps1 -BeforePath E:\VM-006\before.json -AfterPath E:\VM-006\after.json -OutputPath E:\VM-006\comparison.json
```

执行器只保存脱敏后的 stdout/stderr、文件哈希、命令摘要哈希、时间与退出码，并拒绝含秘密的参数。`Write-EvidenceManifest.ps1` 会按 `evidence.schema.json` 规范化清单并拒绝疑似秘密。任何摘要或截图发布到 Issue #1 前仍须人工复核。

## 正式顺序与判定

顺序固定为：VM-011、VM-001（同时覆盖 VM-010）、VM-009、VM-002、VM-003、VM-004、VM-005、VM-006、VM-007、VM-008。

- **VM-011：**金检查点执行默认全选 `-WhatIf -Yes`。仅三个人工目录项可导致退出 10；不得提权、下载、创建日志或改变注册表、功能、代理及其他系统状态。
- **VM-001/010：**默认交互运行。自动项安装；Xftp、Xshell、RealVNC Viewer 为人工项；WSL 为待重启；Store 只有在给出准确人工说明时可接受。预期退出 10，不得有普通 `Failed`，并核对所有账号、Portal、许可和首次启动说明。
- **VM-009：**每次人工重启后执行 `-Only wsl2-ubuntu -Yes`，直至 Ubuntu 24.04 被识别为 WSL 2。脚本不得重启、启动 Ubuntu 或创建 Linux 用户。
- **VM-002/003：**先用 WinGet 人工安装 Chrome、Git，再执行 `-Only chrome,git,vscode -Yes` 并立即重复。第一次两项 `AlreadyInstalled`、VS Code `Installed`、退出 0；第二次全部 `AlreadyInstalled`、退出 0 且没有再次执行安装器。
- **VM-004：**Gateway 最初允许 Clash 资源并阻断冻结的两个 Ready 目标。首跑安装 Clash，目标为 `NeedsProxy/10`。只在 Clash UI 输入订阅，保持系统代理/TUN 关闭；首个目标通过 7897 自动发现，第二个显式传 `-ProxyUri http://127.0.0.1:7897`，两次都退出 0。正式开始前冻结目标。
- **VM-005：**从两个干净恢复点分别建立并记录 App Installer 完全缺失，以及包存在但当前用户注册/命令损坏的前置条件。两者均须恢复可信 WinGet 并安装测试包。若当前 build 无法通过受支持 AppX 操作安全制造第二种状态，发布继续阻断；不得用 shim 或修改系统文件代替。
- **VM-006：**A 仅监听 7897 但拒绝 CONNECT/HTTPS，必须得到 `NeedsProxy/10`；B 允许真实 HTTPS 探测后在安装传输中断流，也必须得到 `NeedsProxy/10`。目标未安装，且 WinGet 功能、WinINET、WinHTTP、环境变量和防火墙观测值前后相等。
- **VM-007：**在真实 VM 中运行 `Invoke-InstallerTrustProbe.ps1`。两个运行时生成的案例直接调用生产 `Test-InstallerTrust`，均为 `NonCompliant/30` 且 `Executed=false`。它验证生产信任边界，不宣称 live mirror E2E。
- **VM-008：**在隔离快照建立 RealVNC v8 与 NoMachine v10 的合成卸载项，再调用真实 `bootstrap.ps1`。两项都必须为 `NonCompliant/30`，且不调用 WinGet、不卸载、不覆盖、不降级；证据复核后销毁快照。

## 公开记录与保留

原始证据记录候选及工具 commit、运行时指纹、ZIP SHA-256、VM UUID/检查点、OS/WinGet build、命令哈希、退出码/逐项状态、前后状态哈希、文件哈希和夹具事件。Issue #1 只发布脱敏判定和必要脱敏截图。有效原始证据与不含秘密的金检查点保留到 v0.1.0 发布后 30 天；含 Clash 订阅的分支完成取证后立即销毁。
