# Changelog / 变更记录

## [1.3.0] - 2026-08-24

### Menu experience and reliability

- Refined the native menu controls, language switcher, duration-slider interaction, and hover tooltip behavior.
- Improved notification reliability and the notification application-icon resources.
- Fixed Blackout keyboard recovery and menu-state handling; refreshed the Blackout title and made its tooltip size adapt to its content.

### 菜单体验与可靠性

- 优化原生菜单控件、语言切换、时长滑杆交互和悬停提示的表现。
- 提升通知的可靠性，并修正通知应用图标资源。
- 修复 Blackout 的键盘恢复与菜单状态处理；更新 Blackout 标题，并让提示框尺寸随内容自动适配。

## [1.2.0] - 2026-08-07

### Public source release preparation

- Added system wake-state detection and clearer separation between KeepAwake's own assertion and other `caffeinate` processes.
- Added Blackout recovery state, independent watchdog recovery, input-triggered auto-restore, and safer display fallback behavior.
- External-display recovery now matches stable IORegistry paths instead of positional DDC service indexes.
- Failed display reads/writes no longer silently report success; partial Blackout changes are rolled back.
- Added single-instance protection and macOS 13 minimum-system metadata.
- Added universal arm64/x86_64 build validation, hardened-runtime options for certificate-signed builds, CI, security guidance, contribution guidance, and asset provenance.
- Rewrote the README in Chinese and English.

### 公开源码发布准备

- 增加系统唤醒状态读取，并区分 KeepAwake 自己的断言与其他 `caffeinate` 进程。
- 增加 Blackout 恢复状态、独立 watchdog、输入触发自动恢复和更安全的显示器降级策略。
- 外接屏恢复从不稳定的 DDC 服务数组下标改为稳定的 IORegistry 路径匹配。
- 显示器读取/写入失败不再静默报告成功；Blackout 部分失败时会回滚。
- 增加单实例保护和 macOS 13 最低系统版本声明。
- 增加 universal arm64/x86_64 构建验证、证书签名构建的 hardened runtime、CI、安全说明、贡献说明和素材来源记录。
- README 改为中英双语。
