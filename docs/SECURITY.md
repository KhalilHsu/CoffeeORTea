# Security policy / 安全政策

## Reporting a vulnerability

Please do not open a public issue for a vulnerability, credential, private display data, or an exploit that could affect users. Prefer a [GitHub Security Advisory](https://github.com/KhalilHsu/CoffeeORTea/security/advisories/new). If that channel is unavailable, open an issue with only enough detail to request a private contact path and do not include sensitive material.

请不要在公开 Issue 中发布漏洞利用细节、凭据、私人显示器数据或可能影响用户的攻击代码。优先使用 [GitHub Security Advisory](https://github.com/KhalilHsu/CoffeeORTea/security/advisories/new)；如果该入口不可用，只提交请求私下沟通的最少信息，不要附带敏感内容。

Include the affected commit or version, macOS version, hardware/connection details when relevant, reproduction steps, and a safe mitigation if known. Please allow reasonable time for validation and a fix before public disclosure.

报告时请尽量提供受影响的 commit 或版本、macOS 版本、相关硬件/连接方式、复现步骤，以及已知的安全缓解方式。请在公开披露前留出合理的验证和修复时间。

## Scope and privacy

KeepAwake is a local-only menu bar application. It does not provide a server, network API, analytics pipeline, or remote-control service. Its temporary Blackout recovery file contains display restoration state and should be treated as local user data. Do not attach that file, logs containing display paths, or private system information to a public report unless redacted.

KeepAwake 是本地菜单栏应用，不提供服务器、网络 API、分析管线或远程控制服务。Blackout 临时恢复文件包含显示器恢复状态，应当视为本机用户数据。除非已脱敏，不要把该文件、包含显示器路径的日志或私有系统信息附在公开报告中。
