# KeepAwake（咖啡或茶 CoffeeORTea）☕️

KeepAwake 是一个原生 macOS 菜单栏工具，用系统 `caffeinate` 断言阻止 Mac 空闲休眠和显示器空闲关闭，并提供定时保持唤醒与 Blackout Mode。它不会绕过手动锁屏或身份验证。

Blackout Mode 的默认策略是把内置屏幕、外接屏亮度降到 0，而不是发送显示器断电命令。这样可以尽量保持显示器仍在系统图形拓扑中，适合需要后台截图或使用 Computer Use 的场景。不同显示器的 DDC/Gamma 行为仍需在真实硬件上验证，项目不保证所有显示器都能保持截图可用。

## 功能

- 菜单栏显示睡眠/咖啡状态。
- 启动和打开菜单时读取当前电源策略；如果系统已经设置为永不休眠，会明确提示当前状态；其他程序的 `caffeinate` 不会被当作 KeepAwake 已开启。
- 永久或 15 分钟、1 小时、3 小时、直到早上 8:00 的保持唤醒时长。
- Blackout Mode：内置屏使用 DisplayServices，外接屏优先使用 DDC/CI 亮度控制，不支持时使用 Gamma 降级方案。
- Blackout 状态写入临时恢复文件，并启动独立 watchdog；主进程异常退出后，watchdog 会尝试恢复显示器状态。
- 鼠标快速移动或 2 秒内连续按 3 次键，可触发显示恢复。
- 中英文菜单和通知，语言跟随 macOS 首选语言。

## 要求

- macOS 13 或更高版本。
- Swift command-line tools；本项目不依赖第三方包或 Xcode 工程。
- 外接屏 DDC/CI 支持取决于显示器、连接方式和 macOS/Apple Silicon 环境。

## 构建和运行

```bash
git clone https://github.com/KhalilHsu/CoffeeORTea.git
cd CoffeeORTea
./build.sh
open KeepAwake.app
```

`build.sh` 默认生成 arm64 + x86_64 universal binary，并使用 ad-hoc 签名，适合本机运行。也可以指定本机证书：

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name" ./build.sh
```

构建产物 `KeepAwake.app` 和编译缓存不会提交到 Git；源码、构建脚本、许可证和图标资源会保留在仓库中。

## 安全边界和已知限制

- `caffeinate -w <PID>` 会把断言绑定到 KeepAwake 进程；KeepAwake 退出后，`caffeinate` 会结束并释放对应的防休眠断言。
- KeepAwake 只管理自己启动的 `caffeinate`；关闭开关时不会终止其他程序的保持唤醒断言。
- KeepAwake 不修改屏幕保护程序或锁屏设置。开启期间的空闲显示器断言在当前 macOS 环境下也会阻止屏保按空闲计时启动，但手动锁屏、合盖和认证策略不作保证。
- 显示器亮度恢复由 KeepAwake 的 watchdog 做 best-effort 保护。系统断电、watchdog 自身被杀、极端系统崩溃或显示器拒绝恢复命令时，不能保证 100% 恢复。
- 项目使用 macOS 私有的 DisplayServices 和 Apple Silicon 上的 IOAVService/`@_silgen_name` DDC 接口，不适合提交 Mac App Store。公开发布时应使用自己的 Developer ID 签名并完成 notarization。
- Blackout Mode 不会模拟键鼠，也不会绕过 macOS 的隐私权限。全局键盘自动恢复可能需要用户授予 Input Monitoring/辅助功能权限；鼠标恢复仍可独立工作。

## 项目结构

- `main.swift`：AppKit 菜单栏 UI、`caffeinate` 生命周期、显示器控制和恢复 watchdog。
- `Info.plist`：菜单栏 Agent 配置、版本号和图标声明。
- `build.sh`：universal binary、App bundle、图标复制和签名构建脚本。
- `AppIcon.png` / `AppIcon.icns`：KeepAwake 应用图标。
- `LICENSE`：MIT License。

## 版本

当前版本：`1.2.0`。

## 许可证

本项目使用 [MIT License](LICENSE)。
