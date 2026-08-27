# Security Policy / 安全策略

## Supported versions / 支持版本

Security fixes are applied to the latest tagged release and the default branch. Older tags may be used for reproducibility but are not guaranteed to receive fixes.

安全修复面向最新标签版本和默认分支；历史标签用于复现，但不保证继续维护。

## Reporting a vulnerability / 报告漏洞

Please use GitHub private vulnerability reporting for the repository. Do not open a public issue for an unpatched vulnerability involving arbitrary command execution, signature or hash bypass, unsafe elevation, proxy credential disclosure, or secret leakage.

请使用 GitHub 仓库的私有漏洞报告功能。涉及任意命令执行、签名/哈希绕过、不安全提权、代理凭据泄露或秘密泄露的未修复问题，请勿直接创建公开 Issue。

Include the affected revision, Windows/PowerShell version, minimal reproduction, expected versus actual behavior, and whether an installer was executed. Redact credentials, subscriptions, license material, and personal paths.

报告中应包含受影响提交、Windows/PowerShell 版本、最小复现、预期与实际行为，以及是否执行过安装器。请移除凭据、订阅、许可证和个人路径。

## Trust boundary / 信任边界

This repository does not audit or warrant third-party applications. It verifies transport and package identity where metadata is available, but vendor software remains governed by its own security practices and license. A matching checksum proves byte identity, not that the software is harmless.

本仓库不对第三方软件本身进行安全背书。项目会在存在可信元数据时验证传输和包身份，但厂商软件仍受其自身安全实践和许可证约束；哈希一致只证明字节一致，不代表软件绝对安全。

Never attach proprietary installers, Clash subscriptions, API keys, RealVNC license data, or diagnostic logs containing secrets to an issue or pull request.
