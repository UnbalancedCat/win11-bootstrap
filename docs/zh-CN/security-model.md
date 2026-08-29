# 安全模型

## 目标与非目标

本项目要防止错误来源、传输篡改、意外升级/降级、命令注入、秘密泄露和持久代理污染。项目不保证第三方软件没有漏洞，也不绕过许可证、账号、地区或组织策略。

## 信任层级

1. 仓库内经过审查的目录和发行标签。
2. 官方 GitHub API、厂商 HTTPS、Microsoft Store/WinGet 官方源。
3. 目录中的固定 SHA-256 与预期 Authenticode 发布者。
4. GitHub 传输镜像或用户种子文件——只能在第 3 层已经提供身份约束时使用。

`ghfast.top` 与 `gh-proxy.com` 不是信任根，只是允许列表中的传输候选。它们不得提供版本号、API 元数据或摘要。无法直接从官方 GitHub API 取得可信摘要时，引导脚本停止。

## 下载与执行

- 默认直连，只有网络类失败才允许代理重试。
- URL 必须是 HTTPS；重定向后的主机仍需符合 Provider 策略。
- 临时文件先写入受保护的 `%ProgramData%\Win11Bootstrap\Staging\<随机 GUID>`，验证完成后才能执行；目录在本次尝试结束时删除，不作为可复用缓存。
- 要求哈希的包必须进行常量时间无关的精确 SHA-256 比较；不提供忽略开关。
- 要求签名的包必须具有 `Valid` Authenticode 状态并匹配允许的发布者。
- 失败文件不执行；日志只记录摘要、公开主机和脱敏错误。

## 代理

显式 `-ProxyUri` 优先。自动候选仅包括系统代理和本机 Clash 常见端口 7897/7890；每个候选都必须实际完成 HTTPS 探测。代理通过进程环境或本次 WinGet 参数使用，并在 `finally` 中恢复。项目不会执行持久化 `netsh winhttp set proxy`，也不会自动读取或写入 Clash 订阅。

## 提权与命令执行

脚本只在真实安装前触发一次 UAC。提权前先解析并规范化配置，原始 JSON 不会由管理员进程重新打开；同时固定 `bootstrap.ps1`、模块、目录和本地化资源的文件长度与 SHA-256。规范选项和 loader 不进入命令行或磁盘，也不依赖临时环境变量跨越 UAC；它们通过随机的一次性请求管道传递，另一个一次性结果管道只传递固定 41 字节结果帧。两个管道均为单向，ACL 均关闭继承、显式拒绝 Network SID 且只允许当前用户 SID 和 SYSTEM。双方通过系统 API 把每个连接绑定到 `Start-Process -Verb RunAs` 返回的精确子 PID 和请求父 PID。信封的长度、SHA-256、调用 ID、版本和字段集合必须全部匹配；结果必须重复调用 ID，且状态只能是 `0`、`10`、`20`、`30` 或 `64`。由于 ShellExecute 可能无法保留对非零子进程退出码的观测，父进程以该认证结果为准。超时、子进程提前退出、尾随数据或任一校验失败均安全停止且不使用备用传输路径。

通过认证的 loader 在 `%ProgramData%\Win11Bootstrap\Runtime\<随机 GUID>` 创建仅 Administrators/SYSTEM 可访问的非重解析点快照，复制前后逐文件复验清单，再从快照启动实际脚本。规范选项只在已提升客户端的进程环境中短暂存在，供其直接子进程继承并一次性消费。UAC 等待期间的源修改、未知清单项、越界路径或清理异常都停止执行并返回失败。

`%ProgramData%\Win11Bootstrap` 的既有目录不会被“修复”为可信目录：owner、继承保护和 Administrators/SYSTEM 精确权限必须已经符合策略，否则失败关闭，以免继承攻击者在提权前保留的目录句柄。外部进程使用固定可执行文件、参数数组和已验证枚举。`WhatIf` 必须在所有写入路径之前短路，且不创建日志。

## 版本门禁和种子目录

RealVNC v8+ 与旧 NoMachine 服务端/Personal Edition v10+ 是策略冲突，任何自动卸载或降级都会扩大风险，因而禁止。NoMachine Enterprise Client v10 是另一产品，只能通过独立的 `nomachine-client` key、精确 WinGet ID 和固定审核版本安装；弃用的 `nomachine` key 不会被重定向到客户端，从而避免许可和功能语义被静默改变。NoMachine 的 Player 命令和 `nxservice` 会被多个产品共享，因此两者都不作为独立产品身份；目录依靠卸载项排除规则、精确 WinGet ID 和 `PolicyGuardKeys`，在计划及 Provider 前把服务端 v10 冲突传播为 `NonCompliant/30`。`SeedDirectory` 不表示信任：文件名、精确哈希和完整 Authenticode 发布者必须与目录中针对固定目标版本人工审查的同一组元数据全部匹配；运行时不从未受信的安装器版本字段猜测目标版本。缺少这组可信元数据的专有包返回 `ManualActionRequired`。

## 秘密和日志

仓库、配置 schema 与日志不接受订阅、令牌或许可证字段。URI 在写日志前移除用户信息。真实运行日志位于受限的 `%ProgramData%\Win11Bootstrap\Logs`，使用含 GUID 的不可预测文件名并以原子 `CreateNew` 创建，避免覆盖或跟随预置文件；查看日志需要管理员权限。发布产物不包含本地配置、缓存、日志或安装器。

## 候选 provenance 与私有证据

候选 ZIP 和 Release ZIP 都由严格文本白名单确定性构建。构建器拒绝危险扩展名、可执行文件/归档/磁盘镜像魔数、含 NUL 或非 UTF-8 的输入、备用数据流、路径逃逸和重解析点；通过验证的文本统一为无 BOM UTF-8 与 LF 换行。归档只允许确定性 ZIP32 method 0（Store）条目，并对条目数量、大小和偏移上限失败关闭。工具会自行解压产物，比较精确条目集合并按相同文本规范重新计算运行时指纹。GitHub build provenance 由固定完整 commit SHA 的 attestation Action 生成，其 job 写权限仅限 OIDC 与 attestation。下载者必须同时验证 SHA-256 与 `gh attestation verify`，两者不能互相替代。

验收输出保存在仓库外并采用 create-new。夹具只保存命令摘要的哈希，stdout/stderr 落盘前会脱敏 URI user info 和常见凭据形式，并拒绝含疑似秘密的证据清单。Gateway 日志只含时间、实验客户端、目标主机/端口、事件和字节数，不做 TLS MITM。自动脱敏只是防线，不代表可以公开；Issue #1 的每段内容都须人工复核，任何秘密暴露都会使该证据组作废并被销毁。
