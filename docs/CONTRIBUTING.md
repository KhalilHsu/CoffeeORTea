# Contributing / 贡献指南

## Before opening a change

- Read the [README](README.md), [security policy](SECURITY.md), and [license](LICENSE).
- Keep the project local-only: do not add telemetry, network calls, credential collection, or unrelated dependencies without a separate design discussion.
- Preserve the macOS 13 deployment target unless the compatibility contract is intentionally changed and documented.
- For display behavior, state the tested Mac, macOS version, monitor, cable/dock, and whether the path used DDC, DisplayServices, or Gamma.

## Local verification

Install Xcode Command Line Tools, then run:

```bash
bash -n build.sh
plutil -lint Info.plist
./build.sh
lipo -info KeepAwake.app/Contents/MacOS/KeepAwake
codesign --verify --deep --strict KeepAwake.app
git diff --check
```

安装 Xcode Command Line Tools 后，至少运行上面的脚本语法、Plist、构建、架构、签名和空白检查。不要把 `KeepAwake.app/` 或 `build_cache/` 提交到仓库。

## Pull requests

Describe what changed, why it is safe, how it was tested, and any hardware or permission limitations. Do not claim that every external display works unless it was tested on that display path. Changes involving private APIs should explain the expected macOS-version risk.

请在 Pull Request 中说明改了什么、为什么安全、如何验证，以及硬件或权限限制。除非已经在相应显示器和连接方式上验证，不要声称所有外接屏都支持。涉及私有 API 时，请说明预期的 macOS 版本风险。
