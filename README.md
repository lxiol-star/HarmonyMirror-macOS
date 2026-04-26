# HarmonyMirror

macOS 上的鸿蒙设备投屏工具 — 在 Mac 上实时查看和控制 HarmonyOS 手机/平板。

## 功能

- USB / Wi-Fi 自动发现和连接鸿蒙设备
- 实时屏幕镜像（60fps H.264 硬件解码）
- 触摸/滑动/长按输入控制
- 横竖屏自动切换
- 手机 / 平板自动识别和适配
- 局域网设备自动扫描
- 设备友好名称显示（如 "HUAWEI Mate 70 Pro+"）
- 连接等待动画和状态提示
- 远程唤醒屏幕
- Wi-Fi 连接可靠性优化（自动检测端口变化）
- macOS 触控板双指滚动和捏合缩放
- Wi-Fi 网络诊断（Mac IP、网关、目标端口探测）
- HarmonyAgent 低延迟输入优先路径（不可用时自动回退 hdc 输入）

## 快速开始

### 前置条件

1. macOS 13.0+，Xcode 15.0+
2. 安装 [DevEco Studio](https://developer.huawei.com)（提供 hdc 工具）
3. HarmonyOS 设备已开启开发者模式和 USB 调试
4. 设备首次使用需先通过 DevEco Testing 打开一次投屏（安装 `libscreen_casting.z.so`）

### 构建

```shell
xcodebuild -project HarmonyMirror.xcodeproj -scheme HarmonyMirror -configuration Debug build
```

### 运行

```shell
open ~/Library/Developer/Xcode/DerivedData/HarmonyMirror-*/Build/Products/Debug/HarmonyMirror.app
```

> 注意：Debug 构建必须通过 `open` 启动 `.app`，不能直接执行二进制文件。

## 使用方法

### USB 连接

1. USB 线连接设备和 Mac
2. App 自动发现设备，点击"连接手机/平板"

### Wi-Fi 连接

1. 确保 USB 已连接且设备开启无线调试
2. 点击"开启无线调试"按钮
3. 拔掉 USB，在输入框填入设备 IP（如 `10.1.2.224:10178`）
4. 点击"连接 Wi-Fi"

App 也会自动扫描局域网并连接发现的设备。

### 投屏操作

| 操作 | 方式 |
|------|------|
| 点击 | 在画面上点击 |
| 拖拽 | 按住并移动 |
| 长按 | 按住不放 (>150ms) |
| Back | 工具栏 Back 按钮，或右键点击画面 |
| Home | 工具栏 Home 按钮 |
| 唤醒屏幕 | 工具栏太阳图标 |
| 通知中心 | 工具栏铃铛图标 |
| 控制中心 | 工具栏滑块图标 |
| 双指滑动 | 触控板双指滑动，映射为设备内滚动 |
| 捏合缩放 | 触控板两指张开/捏合，缩放投屏窗口 |
| 断开 | 工具栏"断开"按钮 |

### 注意事项

- 锁屏和密码输入界面因系统安全限制无法远程操作，需在设备上手动解锁
- 通知中心/控制中心按钮已改用 `uitest uiInput swipe`，桌面状态可打开；锁屏状态仍受系统安全限制
- Wi-Fi 连接需要设备和 Mac 在同一局域网，部分路由器可能隔离客户端

## 项目文档

- [DESIGN.md](DESIGN.md) — 完整的架构设计和技术方案文档

## 技术栈

- Swift / SwiftUI (macOS 原生界面)
- AVFoundation / VideoToolbox (硬件视频解码)
- hdc (HarmonyOS 设备通信)
- Python gRPC bridge (视频流转发)
