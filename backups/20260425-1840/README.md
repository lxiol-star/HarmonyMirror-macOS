# DevEcoCastMac

本地自用的 HarmonyOS/鸿蒙手机投屏 macOS App。

## 当前状态

- 已实现 macOS SwiftUI 外壳。
- 已实现 DevEco Testing gRPC 投屏 bridge。
- 已接入 VideoToolbox H.264 解码显示链路。
- 已添加 Wi-Fi 调试入口：
  - USB 下开启 `hdc tmode port 10178`
  - 输入手机 IP 后执行 `hdc tconn <ip>:10178`

## 运行方式

构建：

```shell
xcodebuild -project /Users/wyj/project/code/local/harmony/DevEcoCastMac_codex2kimi2codex/HarmonyMirror.xcodeproj -scheme HarmonyMirror -destination platform=macOS -derivedDataPath /Users/wyj/project/code/local/harmony/DevEcoCastMac_codex2kimi2codex/.build/DerivedData build
```

打开：

```shell
open /Users/wyj/project/code/local/harmony/DevEcoCastMac_codex2kimi2codex/.build/DerivedData/Build/Products/Debug/HarmonyMirror.app
```

## 使用前提

第一版依赖本机已有 DevEco Testing 和 Python 虚拟环境：

- `/Applications/DevEco_Testing_for_App.app`
- `/Users/wyj/project/code/local/harmony/.venv-deveco-mirror`

如果设备上没有 `/data/local/tmp/libscreen_casting.z.so`，先用 DevEco Testing 打开一次“设备投屏”，再回到本 App 使用。
