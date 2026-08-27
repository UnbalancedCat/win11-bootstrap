# 用户手册

## 使用前提

- Windows 11 x64；Windows PowerShell 5.1。
- 当前账户可以批准一次 UAC。
- 至少存在一种联网路径；部分 GitHub 或境外厂商资源可能需要已经配置好的 Clash。
- 脚本只负责安装，不负责账号登录、许可证激活、代理订阅或 Ubuntu 首次用户创建。

建议从普通 PowerShell 窗口启动。真正执行修改时脚本会自行提权一次；`-WhatIf` 不提权。

## 交互运行

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

菜单默认选择全部 17 项。输入为空表示接受默认；可以输入 `1,3,5-8`，也可以使用 `all` 或 `none`。脚本先检测安装状态，再显示最终计划并要求确认。

## 自动化参数

```powershell
.\bootstrap.ps1 -Only git,vscode -Skip vscode -Yes
.\bootstrap.ps1 -Config C:\Setup\bootstrap.json -Yes
.\bootstrap.ps1 -ProxyUri http://127.0.0.1:7897 -Yes
.\bootstrap.ps1 -SeedDirectory C:\Setup\verified-installers -Yes
.\bootstrap.ps1 -NoGitHubMirrors -Yes
.\bootstrap.ps1 -WhatIf
```

- `-Only` 替换配置文件中的 `only`；未指定时基线为全部软件。
- 命令行与配置文件的 `skip` 合并，且跳过总是优先。
- `-ProxyUri` 和 `-SeedDirectory` 覆盖配置文件对应值。
- `proxyUri`/`-ProxyUri` 只接受不含用户信息、查询参数或 fragment 的绝对 HTTP/HTTPS URI，避免凭据进入原生命令行或日志。
- `-NoGitHubMirrors` 禁止内置 GitHub Release 传输镜像。
- `-Yes` 只能从命令行给出。配置文件不能静默批准安装。
- `-WhatIf` 只校验、检测、探测并显示计划；不会提权、下载、安装或启用功能。

配置文件只能包含以下字段：

```json
{
  "only": ["git", "vscode", "obsidian"],
  "skip": ["obsidian"],
  "proxyUri": "http://127.0.0.1:7897",
  "seedDirectory": "C:\\Setup\\verified-installers",
  "noGitHubMirrors": true
}
```

字段或软件 key 未知、代理 URI 不是 HTTP/HTTPS、种子目录不存在时返回退出码 `64`。

## 多次运行与代理

每次运行都从实际系统重新检测，不维护安装断点文件。直连失败后，脚本只会使用显式代理或经过 HTTPS 验证的系统/本地候选代理。如果 Clash 尚未配置：

1. 允许脚本先安装 Clash Verge Rev。
2. 收到 `NeedsProxy` 后退出。
3. 手动添加订阅并确认代理能访问目标 HTTPS 站点。
4. 使用相同选择再次运行；已完成的软件会变为 `AlreadyInstalled`。

代理只影响当前进程及本次 WinGet 调用，不永久修改系统或 WinHTTP 配置。

## 状态与退出码

| 状态 | 含义 |
|---|---|
| `Planned` | 已选择且准备执行 |
| `AlreadyInstalled` | 检测到任意已安装版本，未升级 |
| `Installed` | 本次成功安装 |
| `Skipped` | 用户或配置明确跳过 |
| `NeedsProxy` | 网络受限，配置代理后重跑 |
| `NeedsRestart` | Windows/WSL 要求用户自行重启后重跑 |
| `ManualActionRequired` | 需要登录、许可、Portal 下载或可信本地安装器 |
| `NonCompliant` | 发现禁止自动处理的主版本或安全策略冲突 |
| `Failed` | 普通下载或安装失败 |

退出码：`0` 完成；`10` 可恢复的人工步骤；`20` 普通失败；`30` 安全/策略阻止；`64` 用法或配置错误。多种结果并存时返回严重程度最高者。

## 默认位置与重启

脚本不向 WinGet 或厂商安装器传入自定义位置。WSL2 与 Ubuntu 始终最后处理；脚本从不自动重启。Ubuntu 首次启动时创建 Linux 用户属于人工步骤。

## 日志和缓存

真实运行日志位于仅 Administrators 和 SYSTEM 可访问的 `%ProgramData%\Win11Bootstrap\Logs\`；需要管理员权限才能查看。`WhatIf` 不创建日志。直接下载或种子安装器只会进入同样受限的 `%ProgramData%\Win11Bootstrap\Staging\<随机 GUID>` 临时目录，并在本次处理结束后删除，不作为可复用缓存。日志记录时间、软件 key、状态和脱敏错误，不记录 URI 用户信息、订阅、令牌或许可证。
