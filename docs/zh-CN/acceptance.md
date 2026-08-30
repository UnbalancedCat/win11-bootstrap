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
5. 在普通（非管理员）Windows PowerShell 中使用匹配工具提交，先运行 `tests\acceptance\Invoke-SelfElevationProbe.ps1 -CandidateRoot <解压候选目录>`，再加 `-Scenario Exit10` 运行一次。每次调用都必须只出现一次 UAC 且不调用安装 Provider：第一次要求候选的跳过选择返回 0；第二次要求安全停止的 RealVNC Viewer 选择把 `ManualActionRequired` 保留为 10。探针仅在候选结果符合预期时自身返回 0。不得用管理员直启候选来绕过失败。
6. 再预演 `clash-verge-rev`、`chrome`、`git`、`codex-desktop`、`realvnc-server`、`nomachine-client`，然后原命令重复一次。任何运行时或目录变更都必须另开 PR、生成新候选、恢复干净检查点并完整重跑预演。冻结前重新核查包 ID、Store 身份、固定版本和只能人工取得的来源。

运行 ZIP 白名单内文件或验收工具发生功能性变化时，全部正式证据作废，须恢复最终金检查点并从 VM-011 重跑。所有正式场景必须在七个自然日内完成，每次都记录 OS build。

## 基线

Windows SUT 是第 2 代 Windows 11 专业版 x64 VM：Secure Boot、vTPM、4 vCPU、4/8/12 GB 动态内存、128 GB 动态 VHDX、香港地区/UTC+8、本地管理员、Windows Update 已完成并重启、开启 nested virtualization。金检查点中不得有候选包、验收工具、个人账号或 Clash 订阅。

VM-004 与 VM-006 另用 `tests/acceptance/gateway/` 记录的双网卡 Ubuntu Gateway：WAN 接 Default Switch，LAN 接私有交换机 `W11B-Lab`，Gateway 为 `192.168.77.1/24`，SUT 为 `192.168.77.10/24`。场景运行期间 SUT 只能连接 `W11B-Lab`，不得同时保留 Default Switch、`W11B-Direct` 或其他网卡；SUT 在 `W11B-Lab` 上不得有可用的全局 IPv6 地址，也不得有全局或默认 IPv6 路由，Gateway 还必须丢弃来自 LAN 的 IPv6，不能留下 IPv6 旁路。每次应用 `vm004-bootstrap`、`vm004-subscription`、`vm004-runtime` 或 `vm006` profile 前，都要从关机状态恢复同一个干净 Gateway 基线检查点；取证后也恢复该检查点，不得把手工删除 nftables 表当作清理。夹具不做 TLS MITM，也不修改宿主机或 SUT 的持久代理、证书、防火墙或 WinHTTP。

## 证据命令

为每个场景挂载新的证据目录，并在执行前后采集状态：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\Capture-SystemState.ps1 -OutputPath E:\VM-006\before.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\Invoke-ReleaseCandidate.ps1 -CandidateRoot C:\Candidate -ScenarioId VM-006 -OutputDirectory E:\VM-006\run -BootstrapArguments '-Only','chrome','-Yes','-ProxyUri','http://192.168.77.1:7897'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\Capture-SystemState.ps1 -OutputPath E:\VM-006\after.json
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\acceptance\Compare-SystemState.ps1 -BeforePath E:\VM-006\before.json -AfterPath E:\VM-006\after.json -OutputPath E:\VM-006\comparison.json
```

执行器只保存脱敏后的 stdout/stderr、文件哈希、命令摘要哈希、时间与退出码，并拒绝含秘密的参数。`Write-EvidenceManifest.ps1` 会按 `evidence.schema.json` 规范化清单并拒绝疑似秘密。任何摘要或截图发布到 Issue #1 前仍须人工复核。

Gateway 网络 policy 必须是 create-new、调用者所有、非符号链接且权限为 `0600` 的私有 JSON，例如 `/var/lib/w11b-private/v0.1.0/VM-004/chrome-vm004-runtime.json` 或 `/var/lib/w11b-private/v0.1.0/VM-006/a-network.json`。网络 policy 只列出规范化的单个公网 IPv4、准确协议和准确端口，不接受 CIDR、地址范围或隐式目标；VM-006 fault-proxy policy 还必须把每个主机固定到已复核的公网 IP。policy 不属于证据，不得复制到证据盘、仓库或 GitHub；证据只记录 policy/rules SHA-256、blocked/allowed 或 rule 数量、脱敏计数器以及夹具事件类型和字节数，不披露 Clash 订阅、节点或它们与 IP 的对应关系。

SUT 操作前后必须立即以 root 从冻结的、root 所有且非符号链接的夹具运行 `capture_gateway_state.py`。每次调用都传必需的 `--profile`：VM-004 使用匹配的 `vm004-bootstrap`、`vm004-subscription` 或 `vm004-runtime`，不得传 `--ready-file`，且 Gateway 的 7897 端口不得存在任何 TCP/UDP 绑定；VM-006 使用 `--profile vm006`，还必须传 `--ready-file`，唯一的 `192.168.77.1:7897` TCP 监听必须对应真实运行中的 root `/usr/bin/python3` 冻结夹具进程，并与 root 所有、`0600` 的 policy、日志、ready 文件及 ready profile/hash 绑定。采集器只接受唯一的 lo/WAN/LAN 清单，采集全部地址、所有表的 IPv4/IPv6 路由和准确的标准 IPv4/IPv6 policy rule，要求 IPv4 forwarding 为 1、两个 IPv6 forwarding 控制均为 0，并把完整 nftables 表、链、有序 match、counter、verdict 和 NAT 语义与所选 policy 精确比较。每个输出都是受信 evidence parent 的直接子项，以 root 所有、`0600`、create-new 方式创建；该 parent 必须 root 所有、非符号链接且不可被组/其他用户写入。此 guest 门禁不能替代宿主对该目录确实位于已批准私有 NTFS evidence VHDX 的挂载核验。输出只记录哈希、数量、脱敏网络身份、计数器和已验证进程身份，不记录原始 policy、原始 WAN 地址/路由、原始 MAC、接口名或私有路径。必须比较前后两份结果并阻断无法解释的身份漂移；VM-004 与 VM-006 各自的 before/after 准确命令见 `tests/acceptance/gateway/README.md`。

## 正式顺序与判定

顺序固定为：VM-011、VM-001（同时覆盖 VM-010）、VM-009、VM-002、VM-003、VM-004、VM-005、VM-006、VM-007、VM-008。

- **VM-011：**金检查点执行默认全选 `-WhatIf -Yes`。仅三个人工目录项可导致退出 10；不得提权、下载、创建日志或改变注册表、功能、代理及其他系统状态。
- **VM-001/010：**默认交互运行。自动项安装；Xftp、Xshell、RealVNC Viewer 为人工项；WSL 为待重启；Store 只有在给出准确人工说明时可接受。预期退出 10，不得有普通 `Failed`，并核对所有账号、Portal、许可和首次启动说明。
- **VM-009：**每次人工重启后执行 `-Only wsl2-ubuntu -Yes`，直至 Ubuntu 24.04 被识别为 WSL 2。脚本不得重启、启动 Ubuntu 或创建 Linux 用户。
- **VM-002/003：**先用 WinGet 人工安装 Chrome、Git，再执行 `-Only chrome,git,vscode -Yes` 并立即重复。第一次两项 `AlreadyInstalled`、VS Code `Installed`、退出 0；第二次全部 `AlreadyInstalled`、退出 0 且没有再次执行安装器。
- **VM-004：**固定两个相互隔离的 Ready 目标分支：`chrome` 验证本机 Clash `127.0.0.1:7897` 自动发现，`bandizip` 验证显式传入同一个 `-ProxyUri`。每个目标分支都从相同的干净 Windows gold 和干净 Gateway 检查点开始，不得把一个目标的状态作为另一个目标的基线。先用 create-new 私有 policy 配置 `vm004-bootstrap`，仅放行安装 Clash 所需的准确端点并阻断该目标，首跑应安装 Clash 且目标为 `NeedsProxy/10`；恢复干净 Gateway 后配置 `vm004-subscription`，只在 Clash UI 输入订阅并保持系统代理/TUN 关闭；再次恢复干净 Gateway 后配置 `vm004-runtime`，只放行冻结节点的准确端点并继续阻断目标直连。`chrome` 运行不得传 `-ProxyUri`，须由运行时自动发现 `127.0.0.1:7897`；`bandizip` 运行必须显式传 `-ProxyUri http://127.0.0.1:7897`；两项分别退出 0。每个 profile 前后记录 Gateway policy/rules 哈希、数量和 nftables 计数器，并证明 SUT 的网卡、IPv4/IPv6 地址与路由、DNS 以及持久代理状态前后精确相等。取证完成后销毁含订阅的 SUT 分支，并恢复干净 Gateway 检查点。
- **VM-005：**从两个干净恢复点分别建立并记录 App Installer 完全缺失，以及包存在但当前用户注册/命令损坏的前置条件。两者均须恢复可信 WinGet 并安装测试包。若当前 build 无法通过受支持 AppX 操作安全制造第二种状态，发布继续阻断；不得用 shim 或修改系统文件代替。
- **VM-006：**A/B 是两个独立分支，每个都从干净 Windows gold 和干净 Gateway 检查点开始，使用 create-new `vm006` 网络 policy，并让 `chrome` 显式使用远端 `-ProxyUri http://192.168.77.1:7897`。固定探针为 `https://www.microsoft.com/favicon.ico`（主机 `www.microsoft.com`）。A 的 create-new `vm006a` fault-proxy policy 只能包含该 probe 的 `reject` 规则且没有 upstream 地址：显式代理探针必须失败，候选必须得到 `NeedsProxy/10`。B 的 create-new `vm006b` policy 必须把 probe 固定到已复核的公网 IP 并 relay，至少一个冻结 metadata 主机也使用固定公网 IP relay，至少一个冻结 payload 主机使用固定公网 IP，在 65536 字节后 drop；显式代理探针先成功，随后候选在安装 payload 传输中断流并得到 `NeedsProxy/10`。两支中 `chrome` 都保持未安装；WinGet 功能、WinINET、WinHTTP、环境变量、防火墙以及 SUT 网卡、IPv4/IPv6 地址与路由、DNS 观测值前后精确相等。证据必须包含 create-new ready 元数据、Gateway policy/rules 哈希与数量、nftables 计数器，以及 A 的拒绝事件或 B 的 probe/metadata relay 与 payload drop 事件；不得包含私有 policy 本文。取证完成后恢复干净 Gateway 检查点，不手动删表。
- **VM-007：**在真实 VM 中运行 `Invoke-InstallerTrustProbe.ps1`。两个运行时生成的案例直接调用生产 `Test-InstallerTrust`，均为 `NonCompliant/30` 且 `Executed=false`。它验证生产信任边界，不宣称 live mirror E2E。
- **VM-008：**在隔离快照建立 RealVNC v8 与旧 NoMachine 服务端/Personal Edition v10 的合成卸载项，再使用对应受保护 key 调用真实 `bootstrap.ps1`。两项都必须为 `NonCompliant/30`，且不调用 WinGet、不卸载、不覆盖、不降级；另外的 Enterprise Client v10 记录不得触发旧服务端门禁。证据复核后销毁快照。

## 公开记录与保留

原始证据记录候选及工具 commit、运行时指纹、ZIP SHA-256、VM UUID/检查点、OS/WinGet build、命令哈希、退出码/逐项状态、前后状态哈希、文件哈希、Gateway policy/rules 哈希与数量、脱敏计数器和夹具事件。Issue #1 只发布脱敏判定和必要脱敏截图。有效原始证据与不含秘密的金检查点保留到 v0.1.0 发布后 30 天；含 Clash 订阅的分支完成取证后立即销毁。
