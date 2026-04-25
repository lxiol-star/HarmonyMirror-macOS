# HarmonyMirror — 鸿蒙设备 macOS 投屏工具

## 一句话介绍

HarmonyMirror 是一个 macOS 原生应用，让你在 Mac 上实时查看和控制鸿蒙手机/平板的屏幕。类似于 Android 的 scrcpy，但针对 HarmonyOS 设备。

---

## 整体架构

整个系统由三部分协作完成投屏：

```
┌──────────────────────────────────────────────────────────────────┐
│                        你的 Mac                                   │
│                                                                    │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │              HarmonyMirror App (Swift/SwiftUI)              │  │
│  │                                                             │  │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │  │
│  │  │ 设备发现      │  │ 投屏服务      │  │ 用户界面         │  │  │
│  │  │ DeviceDiscovery│ │ MirrorService│  │ MirrorWindow    │  │  │
│  │  └──────────────┘  └──────────────┘  └──────────────────┘  │  │
│  │         │                  │                    │            │  │
│  │         ▼                  ▼                    ▼            │  │
│  │  ┌──────────────────────────────────────────────────────┐   │  │
│  │  │              HDCCommand (hdc 命令封装)                │   │  │
│  │  │   设备连接 │ shell 命令 │ 端口转发 │ 输入注入         │   │  │
│  │  └──────────────────────────────────────────────────────┘   │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                              │                                     │
│                    hdc 命令行工具                                   │
│                              │                                     │
│  ┌───────────────────┐      │      ┌─────────────────────────┐   │
│  │ Python Bridge      │◄─────┘      │ TCPStreamReceiver      │   │
│  │ deveco_cast_bridge │──────────►  │ 接收 H.264 视频帧      │   │
│  │ gRPC → TCP 转发    │   本地TCP   │                         │   │
│  └───────────────────┘              └──────────┬──────────────┘   │
│                                                 │                  │
│                                    ┌────────────▼──────────────┐   │
│                                    │ H264VideoLayer            │   │
│                                    │ 解析 H.264 → 硬件解码显示  │   │
│                                    └───────────────────────────┘   │
│                                                                    │
└──────────────────────────────────────────────────────────────────┘
                               │
                    USB 数据线 或 Wi-Fi 网络
                               │
┌──────────────────────────────────────────────────────────────────┐
│                     鸿蒙手机 / 平板                                │
│                                                                    │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │  libscreen_casting.z.so (华为投屏扩展)                      │  │
│  │  录屏 → H.264 编码 → gRPC 服务 → scrcpy_grpc_socket        │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │  hdc daemon (设备端守护进程)                                 │  │
│  │  接收 Mac 发来的 shell 命令、触摸注入、端口转发请求          │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                    │
└──────────────────────────────────────────────────────────────────┘
```

## 数据流：画面是怎么到 Mac 屏幕上的？

```
手机屏幕
   │
   ▼ (录屏 + H.264 编码)
libscreen_casting.z.so
   │
   ▼ (gRPC 协议，通过 Unix socket)
scrcpy_grpc_socket (手机内部)
   │
   ▼ (hdc 端口转发，把手机端口映射到 Mac 本地端口)
Mac 本地端口 (如 tcp:9500)
   │
   ▼ (Python bridge 读取 gRPC 数据，转成简单的 TCP 帧)
Mac 本地 TCP (如 tcp:18000)
   │
   ▼ (TCPStreamReceiver 接收)
H264VideoLayer
   │
   ▼ (解析 NAL 单元、提取 SPS/PPS、构建 CMSampleBuffer)
AVSampleBufferDisplayLayer (macOS 硬件解码渲染)
   │
   ▼
你在 Mac 上看到的手机画面
```

## 数据流：触摸操作是怎么传到手机的？

```
你在 Mac 上点击/滑动投屏窗口
   │
   ▼ (MirrorWindow 捕获鼠标事件)
InputInjector
   │
   ▼ (窗口坐标 → 手机屏幕坐标 换算)
HDCCommand.uinputClick / uinputSwipe / uinputTouchDown...
   │
   ▼ (执行 hdc shell uinput -T -c x y 等命令)
hdc 命令行
   │
   ▼ (通过 USB/Wi-Fi 发送到手机)
手机 hdc daemon
   │
   ▼ (uinput 写入 Linux 内核输入子系统)
手机屏幕响应你的操作
```

> **当前局限**：每次触摸都要启动一个 `hdc shell` 进程，单次往返约 100ms。
> 拖拽时以 10Hz 节流，仍然能感知到轻微跳跃。未来 HarmonyAgent 方案可解决。

---

## 当前实现更新（2026-04-26）

- 工具栏改为紧凑按钮布局，窗口尺寸按当前屏幕可见区域和 macOS 标题栏动态计算；竖屏手机/平板下顶部按钮和底部 fps/分辨率不会再被窗口边缘裁切。
- 投屏窗口支持等比拖拽缩放，并在底部状态栏提供缩小、放大、适配窗口、占满屏幕四个控制按钮；底部缩放按钮触发的窗口变化固定底边，便于连续点击，设备横竖屏变化时会回到新方向的自动适配尺寸。
- 左上角 macOS 原生全屏按钮已接入全屏状态监听，进入全屏后会按全屏屏幕重新计算窗口限制，退出后恢复普通可视区域适配。
- macOS 端交互继续补齐触控板手势适配：双指滑动映射为投屏内滚动，两指张开/捏合映射为窗口或画面缩放，和底部缩放按钮共享同一套缩放状态。
- 连接开始时先读取 `Display ID: 0` 宽高，立即初始化窗口尺寸和输入坐标；设备列表刷新时也读取当前显示尺寸，用于提前显示横竖屏和分辨率。
- 通知栏/控制中心按钮改为 `uitest uiInput swipe`。实测 `uinput -T` 从 `y=0` 下拉无法打开系统面板；`uitest uiInput swipe x 5 x 1189 600` 可稳定打开通知栏和控制中心。
- 投屏画面顶部状态栏区域向下拖动超过阈值后，会触发同一条 `uitest` 系统下拉路径。
- 新增 HarmonyAgent Phase 1 原型：`agent/harmony_agent.c` 和 `HarmonyMirror/Agent/AgentSocketClient.swift`。当前作为低延迟输入通道基础，不替换现有可用输入链路。

## 实测结果（2026-04-26）

- 手机 `10.1.2.224:10178`：`Display ID: 0` 为 `1316×2832`，桌面状态下左上区域下拉打开通知栏，右上区域下拉打开控制中心。
- 平板 `192.168.18.188:10178`：`Display ID: 0` 为 `1600×2560`，可用于初始化竖屏窗口尺寸。
- 锁屏状态下系统面板下拉仍受系统限制；需进入桌面后才能打开通知栏/控制中心。
- `xcodebuild -project HarmonyMirror.xcodeproj -scheme HarmonyMirror -destination platform=macOS -derivedDataPath .build/DerivedData build` 通过。

---

## 核心模块说明

### 1. HDCCommand — 与鸿蒙设备通信的桥梁

**文件**：`HarmonyMirror/HDC/HDCCommand.swift`

`hdc`（HarmonyOS Device Connector）是华为提供的命令行工具，类似于 Android 的 `adb`。这个模块把所有 hdc 命令封装成 Swift 方法。

关键功能：

| 方法 | 作用 | 底层 hdc 命令 |
|------|------|---------------|
| `listTargets()` | 查看已连接设备 | `hdc list targets` |
| `connectWiFi(host:)` | Wi-Fi 连接设备 | `hdc tconn IP:端口`，含等待注册+端口变化检测 |
| `shell(_:serial:)` | 执行设备端命令 | `hdc -t 序列号 shell 命令` |
| `uinputClick(x:y:)` | 模拟点击 | `hdc shell uinput -T -c x y` |
| `uinputSwipe(...)` | 模拟滑动 | `hdc shell uinput -T -m ...` |
| `forward(local:remote:)` | 端口转发 | `hdc fport tcp:X localabstract:Y` |
| `deviceProfile(serial:)` | 读取设备名称和型号 | `param get const.product.name` 等 |
| `displaySize(serial:)` | 获取屏幕分辨率 | `hdc shell hidumper -s DisplayManagerService` |

### 2. DeviceDiscovery — 自动发现设备

**文件**：`HarmonyMirror/HDC/DeviceDiscovery.swift`

每 2 秒轮询一次已连接设备，每 12 秒扫描一次局域网。

发现流程：

```
USB 设备：hdc list targets → 直接显示
Wi-Fi 设备：
  ① 先尝试重连上次成功过的 IP:端口 (knownWiFiTargets 缓存)
  ② 扫描 Mac 所有网卡所在 /24 网段
  ③ 对每个 IP 并行探测 [10178, 43101] 端口
  ④ 端口可达 → 执行 hdc tconn 连接
  ⑤ 连接成功 → 记住这个 IP，下次优先尝试
```

### 3. MirrorService — 投屏流程管理

**文件**：`HarmonyMirror/Core/MirrorService.swift`

投屏的完整生命周期：

```
用户点击"连接"
   │
   ▼
startMirroring(device:)
   │
   ├── 1. 创建 InputInjector（准备触摸注入）
   ├── 2. 准备设备端：
   │      a. 杀掉旧的 libscreen_casting.z.so 进程
   │      b. 启动新的投屏服务
   │      c. 建立 hdc 端口转发
   ├── 3. 启动 Python bridge（gRPC → TCP 转发）
   ├── 4. 等待 bridge TCP 服务就绪
   ├── 5. 创建 H264VideoLayer + TCPStreamReceiver
   ├── 6. 连接 bridge，开始接收视频帧
   └── 7. 启动屏幕尺寸监控（每 1.5 秒检测横竖屏变化）
```

**Bridge 复用**：断开投屏后 bridge 延迟 60 秒才终止，重连同一设备时直接复用，实现秒连。

### 4. H264VideoLayer — 视频解码与显示

**文件**：`HarmonyMirror/VideoStream/H264VideoLayer.swift`

把原始 H.264 二进制数据变成 Mac 屏幕上的画面：

```
原始 H.264 数据 (Annex-B 或 AVCC 格式)
   │
   ▼ 检测格式 (detectAnnexB)
   │
   ▼ 解析 NAL 单元 (parseNALUnits)
   │
   ├── SPS (序列参数集) → 解析视频宽高
   ├── PPS (图像参数集) → 创建格式描述
   └── I/P 帧 → 构建 AVCC 格式缓冲区
   │
   ▼ 创建 CMSampleBuffer
   │
   ▼ enqueue 到 AVSampleBufferDisplayLayer
   │
   ▼ macOS VideoToolbox 硬件解码 + 显示
```

### 5. InputInjector — 触摸输入

**文件**：`HarmonyMirror/HDC/InputInjector.swift`

采用 **150ms 延迟阈值** 区分点击和长按/拖拽：

| 操作 | 触发条件 | 发送的命令 |
|------|---------|-----------|
| 普通点击 | 按下后 <150ms 松开，移动 <5pt | `uinput -T -c x y` |
| 长按 | 按下后 >150ms 仍按住 | `uinput -T -d` → 等待 → `uinput -T -u` |
| 拖拽 | 移动 >5pt | `uinput -T -d` → `uinput -T -m`(10Hz) → `uinput -T -u` |

坐标映射考虑了视频 aspect-fit 显示产生的黑边，黑边区域的点击会被丢弃。

**顶部边缘区域检测**：视频顶部 6% 定义为"状态栏区域"。从此区域开始的拖拽，`touchDown` 自动将 y 坐标吸附到 0（屏幕最顶行像素），以模拟从屏幕边缘开始的滑动手势，用于触发通知中心（左半屏）或控制中心（右半屏）。短距离点击（<5pt）不受影响，仍发送原始坐标。

---

## 连接方式

### USB 连接（推荐，最稳定）

1. 手机/平板用 USB 线连接 Mac
2. 手机上开启 USB 调试（设置 → 系统 → 开发者选项）
3. App 自动发现设备，点击"连接"

### Wi-Fi 连接

**前提**：设备和 Mac 在同一局域网，设备已开启无线调试。

两种方式：
- **自动发现**：App 每 12 秒扫描局域网，自动连接发现的设备
- **手动输入**：在"设备 IP"输入框填写 `IP:端口`（如 `10.1.2.224:10178`），点击"连接 Wi-Fi"

**已知问题**：
- 部分路由器开启了"客户端隔离"，导致同一 Wi-Fi 下设备互不可达
- 首次 Wi-Fi 连接可能需要在设备上确认信任弹窗
- 解决方案优先级：同一路由器 > 手机开热点让 Mac 连 > Mac 共享网络

### 通过 USB 开启 Wi-Fi 调试

1. 先用 USB 连接设备
2. 点击"开启无线调试"按钮
3. App 自动执行 `hdc -t 序列号 tmode port 10178`
4. 获取设备 Wi-Fi IP 并填入输入框
5. 拔掉 USB 线，点击"连接 Wi-Fi"

---

## 窗口布局

```
┌──────────────────────────────────────────┐
│  HUAWEI Mate 70 Pro+  竖屏  Back Home ☀ 🔔 ⚙ 断开 │  ← 工具栏 (48px)
├──────────────────────────────────────────┤
│                                          │
│                                          │
│           视频画面区域                     │  ← 按设备分辨率等比缩放
│         (AVSampleBufferDisplayLayer)      │
│                                          │
│                                          │
├──────────────────────────────────────────┤
│  45 fps │ 1316x2832                      │  ← 状态栏 (40px)
└──────────────────────────────────────────┘

连接中/等待视频流/断开时，视频区域上方显示半透明遮罩 + 加载动画 + 状态文字提示。
```

工具栏按钮说明：

| 按钮 | 图标/文字 | 功能 |
|------|----------|------|
| Back | 文字 | 返回上一级 |
| Home | 文字 | 回到桌面 |
| ☀ | `sun.max` 图标 | 唤醒设备屏幕（KEY_POWER） |
| 🔔 | `bell` 图标 | 拉下通知中心（从 y=0 滑动） |
| ⚙ | `slider.horizontal.3` 图标 | 拉下控制中心（从 y=0 滑动） |
| 断开 | 文字 | 停止投屏 |

- 窗口大小根据设备分辨率自动适配
- 手动拖拽调整窗口大小后不会被自动重置
- 横竖屏切换时自动调整窗口比例

---

## 项目文件结构

```
HarmonyMirror/
├── App/
│   └── HarmonyMirrorApp.swift        # App 入口，窗口管理
├── Core/
│   ├── MirrorService.swift           # 投屏流程管理（核心）
│   └── Models.swift                  # 数据模型定义
├── HDC/
│   ├── HDCCommand.swift              # hdc 命令封装
│   ├── DeviceDiscovery.swift         # 设备自动发现
│   ├── InputInjector.swift           # 触摸输入注入
│   └── ScreenCapture.swift           # 屏幕截图
├── Views/
│   ├── DeviceListView.swift          # 设备列表页面
│   ├── MirrorWindow.swift            # 投屏窗口页面
│   └── Components/
│       ├── DeviceCard.swift          # 设备卡片组件
│       ├── ConnectionStatusBar.swift # 底部状态栏
│       └── ScreenImageView.swift     # 截图查看
├── VideoStream/
│   ├── H264VideoLayer.swift          # H.264 解码渲染
│   ├── TCPStreamReceiver.swift       # TCP 视频帧接收
│   └── VideoPlayerView.swift         # 视频显示 NSView
├── Utils/
│   ├── Constants.swift               # 常量配置
│   └── Logger.swift                  # 日志系统
└── tools/
    └── deveco_cast_bridge.py         # Python gRPC→TCP 桥接
```

---

## 已知局限

| 问题 | 原因 | 影响 |
|------|------|------|
| 拖拽有轻微跳跃 | 每次 touchMove 需启动 hdc shell 进程，往返 ~100ms | 拖拽不够丝滑 |
| 边缘手势不完整 | uinput 无法触发状态栏系统面板；已对通知/控制中心改用 uitest swipe | 桌面可打开通知栏/控制中心，锁屏仍受系统限制 |
| 侧滑返回失效 | 系统级手势需要从屏幕外缘开始，uinput 无法模拟负坐标 | 无法触发侧滑返回 |
| 首帧延迟 | 关键帧间隔 2 秒，连接时需等待下一个关键帧 | 连接后短暂黑屏 |
| 锁屏/密码界面不可操作 | 安全窗口（FLAG_SECURE）拒绝 hdc 注入的触摸事件，录屏服务也屏蔽安全窗口画面 | 需手动解锁设备 |
| 平板 Wi-Fi 连接不稳定 | hdc Wi-Fi 调试功能本身尚不稳定 | 可能需要重试 |

---

## 安全屏幕专题分析

### 什么是安全屏幕？

鸿蒙系统（和 Android 类似）对锁屏、密码输入、支付等敏感场景使用 **FLAG_SECURE** 标记。被标记的窗口有以下限制：

1. **录屏屏蔽**：`libscreen_casting.z.so` 检测到安全窗口时会主动黑屏或冻结画面
2. **输入拒绝**：`uinput` / `uitest` 注入的触摸事件被系统丢弃
3. **截屏屏蔽**：`snapshot_display` 截图也会被拦截

这意味着：锁屏状态下 Mac 端**看不到**密码输入界面，也**无法远程操作**解锁。

### 为什么华为远程协同可以？

华为内置的"远程协同"（超级终端）能操作锁屏并看到密码界面，因为它运行在完全不同的权限层级：

```
华为远程协同                          HarmonyMirror (hdc 方案)
─────────────                        ────────────────────────
DSoftBus (分布式软总线)                hdc (调试桥接)
  │ 系统服务级权限                       │ 用户/debug 级权限
  ▼                                    ▼
设备信任认证 (已配对的设备)              无认证，仅 USB/TCP 连接
  │ 通过安全芯片验证身份                  │
  ▼                                    ▼
安全屏幕截取 API                       libscreen_casting.z.so
  │ 能捕获 FLAG_SECURE 窗口内容          │ 被 FLAG_SECURE 窗口屏蔽
  ▼                                    ▼
系统级输入注入通道                      uinput / uitest
  │ 能向安全窗口发送触摸事件              │ 被安全窗口拒绝
  ▼                                    ▼
锁屏可操作、密码界面可见 ✓              锁屏不可操作、密码界面不可见 ✗
```

**核心差距**：远程协同走 DSoftBus **系统服务通道**，经设备信任认证后获得安全窗口的读写权限。`hdc` 调试工具运行在用户态，系统不允许操作安全窗口。

### 解决方案对比

| 方案 | 能否解锁 | 难度 | 说明 |
|------|---------|------|------|
| 用户关闭锁屏密码 | 间接解决 | 零 | 设置锁屏方式为"无"或"滑动" |
| DSoftBus SDK | ✓ | 极高 | 需要华为开放 SDK 并在 macOS 实现 DSoftBus 协议 |
| OpenHarmony 源码移植 | ✓ | 极高 | DSoftBus 开源但 macOS 端需自行实现设备认证+加密通道 |
| HarmonyAgent 系统签名 | ✓ | 高 | 设备端 Agent 需系统级权限，需获取系统签名或 root |
| 当前 hdc 方案 | ✗ | - | 受限于用户态权限，无法突破 |

### 短期应对策略

1. **唤醒按钮**（已实现）：点击后发送电源键事件，可唤醒黑屏设备
2. **提示用户手动解锁**：设备亮屏后，用户在物理屏幕上完成解锁，Mac 端自动恢复画面
3. **建议用户使用滑动解锁**：如需远程操控，可将锁屏方式设为"无密码"或"滑动"

---

## 开发路线图

### P0 — 已完成

- [x] USB 设备发现与连接
- [x] Wi-Fi 设备连接（手动 + 局域网自动扫描）
- [x] H.264 视频流解码显示
- [x] 触摸/滑动/长按输入注入
- [x] Back / Home / 唤醒 按钮
- [x] 横竖屏自动切换
- [x] 设备分辨率自适应窗口大小
- [x] Bridge 复用与延迟终止（秒连）
- [x] 手机 / 平板自动识别
- [x] **投屏等待动画与状态提示** — 连接中/等待视频流/断开连接时显示加载动画和文字
- [x] **设备友好名称** — 优先显示 `const.product.name`（如 "HUAWEI Mate 70 Pro+"）而非型号编码（如 "PLA-AL10"）
- [x] **应用图标** — 鸿蒙蓝圆角矩形 + 手机播放 + 信号波纹
- [x] **屏幕唤醒按钮** — 工具栏太阳图标，发送 KEY_POWER 唤醒设备，实测有效
- [x] **Wi-Fi 连接可靠性优化** — tconn 后等待设备注册、list targets 验证、支持端口变化检测
- [x] **断开清屏** — 断开投屏时清除残留画面
- [x] **顶部边缘区域检测** — 视频顶部 6% 为状态栏区域，拖拽时 y 吸附到 0 模拟边缘手势
- [x] **通知中心/控制中心按钮** — 工具栏铃铛/滑块按钮，改用 `uitest uiInput swipe`，实测桌面状态可打开通知栏和控制中心
- [x] **紧凑工具栏/状态栏** — 竖屏窗口下按钮、fps、分辨率完整显示
- [x] **连接前分辨率初始化** — startMirroring 前先读取设备显示尺寸，窗口和输入坐标提前对齐
- [x] **HarmonyAgent Phase 1 原型** — 已新增设备端 C Agent 和 macOS AgentSocketClient 协议客户端
- [ ] **mac 触控板手势适配**
  - 双指滑动作为滚动输入
  - 双指张开 / 捏合用于缩放窗口或画面
  - 与底部缩放按钮共用状态，避免手势和按钮互相打架

### P1 — 待开发（短期，1-2 天）

- [x] **锁屏解锁（已验证不可行）** — 安全窗口拒绝 hdc 注入，详见"安全屏幕专题分析"

- [ ] **网络诊断工具**
  - 显示 Mac 当前 IP 和默认网关
  - 对目标 IP 做 TCP 端口探测
  - tconn 失败时给出具体建议（如"请尝试手机热点"）

### P2 — HarmonyAgent 设备端常驻代理（中期，1-2 周）

#### 目标

在 HarmonyOS 设备上部署一个 C 语言编写的常驻代理进程，Mac 端通过 TCP 直接与其通信。解决当前 hdc 方案的两大核心痛点：

| 痛点 | 当前表现 | HarmonyAgent 目标 |
|------|---------|-------------------|
| 触摸延迟高 | ~100ms/次（每次启动 hdc shell 进程） | **<2ms**（TCP 直连 + 内核写入） |
| 安全屏幕不可操作 | 锁屏/密码界面拒绝 uinput 事件 | 探索系统级输入通道 |

#### 整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                        macOS HarmonyMirror                          │
│                                                                     │
│  ┌───────────────────┐      ┌──────────────────┐                    │
│  │  InputInjector     │      │ MirrorService    │                    │
│  │  (触摸事件生成)    │      │ (投屏流程管理)   │                    │
│  └────────┬──────────┘      └────────┬─────────┘                    │
│           │                          │                               │
│           ▼                          ▼                               │
│  ┌──────────────────┐     ┌──────────────────────┐                   │
│  │ AgentSocketClient │     │ TCPStreamReceiver    │                   │
│  │ 发送 TouchFrame   │     │ 接收 H.264 视频帧   │                   │
│  └────────┬─────────┘     └──────────┬───────────┘                   │
│           │                          │                               │
└───────────┼──────────────────────────┼───────────────────────────────┘
            │                          │
     hdc fport TCP               hdc fport TCP
   (触摸事件通道)              (视频流通道，可选)
            │                          │
┌───────────┼──────────────────────────┼───────────────────────────────┐
│           ▼                          ▼                               │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │               HarmonyAgent (设备端常驻进程)                   │    │
│  │                                                              │    │
│  │  ┌────────────────┐  ┌────────────────┐  ┌───────────────┐  │    │
│  │  │ TouchHandler   │  │ VideoRelay     │  │ CommandServer │  │    │
│  │  │ ↓              │  │ ↓              │  │ ↓             │  │    │
│  │  │ write(uinput)  │  │ TCP 转发 H.264 │  │ 执行 shell    │  │    │
│  │  └────────────────┘  └────────────────┘  └───────────────┘  │    │
│  │                                                              │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                        HarmonyOS 设备                               │
└──────────────────────────────────────────────────────────────────────┘
```

#### 触摸协议（TCP 二进制帧）

每帧固定 8 字节，端到端延迟 <2ms：

```c
// 触摸事件帧
struct TouchFrame {
    uint8_t  cmd;        // 命令类型
                         //   0x01 = TOUCH_DOWN    手指按下
                         //   0x02 = TOUCH_UP      手指抬起
                         //   0x03 = TOUCH_MOVE    手指移动
                         //   0x04 = KEY_EVENT     按键事件
                         //   0x05 = PIN_CODE      PIN 码输入
                         //   0x80 = PING          心跳
                         //   0x81 = PONG          心跳回复
    uint8_t  slot;       // 手指编号 (0-9，支持多点触控)
                         // KEY_EVENT 时为按键码
    uint16_t x;          // X 坐标 (0~65535 归一化，设备端按屏幕分辨率还原)
    uint16_t y;          // Y 坐标 (0~65535 归一化)
    uint16_t reserved;   // 预留 (压力值、触摸面积等)
} __attribute__((packed));

// PIN 码输入帧 (cmd=0x05)
// slot = PIN 长度，x/y 各存一个数字 (BCD 编码)
// 可一次发送多位 PIN，设备端模拟连续按键
```

#### 与远程协同的对比

```
              华为远程协同               HarmonyAgent
              ────────────             ────────────
通信协议      DSoftBus (加密)          hdc fport TCP
设备认证      安全芯片 + 配对          hdc 调试信任
权限级别      系统服务级               shell 用户级 (可探索 root)
安全屏幕      可操作 ✓                 待实测 (核心风险点)
触摸延迟      <1ms                     <2ms
视频获取      系统截取 API             libscreen_casting.z.so
部署方式      系统内置                 hdc file send + shell 启动
```

#### 安全屏幕突破方案

HarmonyAgent 尝试突破安全窗口限制的三个层级（从易到难）：

**层级 1：验证 /dev/uinput 权限（Phase 1）**
- Agent 作为 shell 用户直接 `open("/dev/uinput", O_WRONLY)`
- 如果 shell 用户有写入权限 → 基础触摸可用，但安全窗口仍可能拒绝
- 实测方法：推送 Agent → 运行 → 在锁屏界面尝试 click

**层级 2：探索 input 通道（Phase 2）**
- 尝试 `/dev/input/eventX` 直接写入 `input_event` 结构体
- 尝试 `ioctl(uinput_fd, UI_SET_PROPBIT, INPUT_PROP_DIRECT)` 设置设备属性
- 部分设备的安全窗口检查输入源属性，设置正确的设备属性可能绕过检查

**层级 3：root / 系统签名（Phase 3，高风险）**
- 部分鸿蒙设备可通过 `hdc shell` 获取 root：`hdc shell "su -c 'xxx'"`
- root 权限下可访问安全输入通道
- 需要 `setenforce 0` 关闭 SELinux 或添加安全策略规则
- 风险：可能影响设备安全性，不建议日常使用

#### 实施路线

**Phase 1（2-3 天）：Agent 原型 — 验证连通性和基础触摸**
1. 编写最小 C 程序：监听 TCP → 接收 TouchFrame → 写入 /dev/uinput
2. 交叉编译 ARM aarch64 二进制（使用 HarmonyOS NDK 或通用 ARM 工具链）
3. `hdc file send` 推送到 `/data/local/tmp/harmony_agent`
4. `hdc shell chmod +x && hdc shell ./harmony_agent`
5. Mac 端新增 `AgentSocketClient`，发送 TouchFrame 测试 click/swipe
6. **验收标准**：普通界面点击延迟 <5ms

**Phase 2（3-5 天）：完整协议 + 安全屏幕实验**
1. 实现多点触控（slot 管理）、KEY 事件
2. 在锁屏界面测试触摸注入是否生效
3. 如果被拒绝，尝试 `/dev/input/eventX` 直接写入
4. 尝试不同的 uinput 设备属性组合
5. **验收标准**：明确安全屏幕是否可操作，记录可行的权限提升路径

**Phase 3（5-7 天）：视频流合并（可选）**
1. Agent 直接读取 gRPC socket，TCP 转发 H.264 到 Mac
2. 替代 Python bridge，减少一个进程
3. 可在 Agent 内做帧分析（关键帧缓存、首帧加速）
4. **验收标准**：去掉 Python 依赖，首帧延迟 <0.5s

**Phase 4（可选）：DSoftBus 探索**
1. 研究 OpenHarmony DSoftBus 开源代码（gitee.com/openharmony）
2. 分析设备认证和加密握手协议
3. 评估在 macOS 实现 DSoftBus 客户端的可行性
4. 如可行，可替代 hdc fport 实现更可靠的安全连接

#### macOS 端代码改动

1. `InputInjector` 新增 Agent 模式：
   - 当前：`hdc shell uinput -T -c x y`（~100ms）
   - Agent：发送 8 字节 TouchFrame 到 TCP socket（<2ms）
   - 运行时自动检测：Agent 可用 → 使用 Agent；不可用 → 回退 hdc

2. 新增 `AgentSocketClient`：
   ```swift
   class AgentSocketClient {
       private var connection: NWConnection?
       func connect(host: String, port: UInt16)
       func sendTouch(cmd: UInt8, slot: UInt8, x: UInt16, y: UInt16)
       func sendKey(keyCode: UInt16)
       func disconnect()
   }
   ```

3. `MirrorService` 集成：
   - `startMirroring` 时自动推送并启动 Agent
   - 通过 `hdc fport` 为 Agent 开辟 TCP 通道
   - `InputInjector` 根据是否连接 Agent 选择输入路径

#### 兼容性策略

Agent 是增量替换，不影响现有功能：
```
优先级：Agent TCP → hdc shell uinput → hdc shell uitest
                            ↓ 失败回退
```

- 视频流：继续使用 Python bridge + `libscreen_casting.z.so`
- 触摸输入：新增 Agent 路径，旧 `hdc shell` 路径保留作为 fallback
- 通过 `UserDefaults` 或运行时自动检测切换

### P3 — 远期规划

- [ ] **DSoftBus 服务发现与通信**
  - 研究 OpenHarmony DSoftBus 开源实现（gitee.com/openharmony）
  - 使用 CoAP/mDNS 协议自动发现局域网内的鸿蒙设备
  - 解决设备 IP/端口动态变化的问题，替代当前的端口扫描方案
  - 长期目标：实现设备信任认证，获取系统级权限以操作安全屏幕

- [ ] **音频转发**：将设备音频流转发到 Mac 播放
- [ ] **剪贴板同步**：Mac ↔ 设备双向剪贴板
- [ ] **文件拖放**：从 Mac 拖拽文件到设备
- [ ] **多设备同时投屏**：支持同时显示多台设备画面

---

## 环境要求

### Mac 端

- macOS 13.0+
- Xcode 15.0+
- [DevEco Studio](https://developer.huawei.com) 或 [DevEco Testing](https://developer.huawei.com)（提供 hdc 工具）
- Python 3.9+（含 grpcio、protobuf 依赖）

### 设备端

- HarmonyOS 4.0+
- 开启开发者模式和 USB 调试
- 设备上需要存在 `/data/local/tmp/libscreen_casting.z.so`（首次使用需先通过 DevEco Testing 打开一次投屏）

### 构建与运行

```shell
# 构建
xcodebuild -project HarmonyMirror.xcodeproj \
  -scheme HarmonyMirror \
  -configuration Debug \
  build

# 运行（必须通过 open 启动，不能直接执行二进制）
open ~/Library/Developer/Xcode/DerivedData/HarmonyMirror-*/Build/Products/Debug/HarmonyMirror.app
```

---

## 技术词汇表

| 术语 | 解释 |
|------|------|
| hdc | HarmonyOS Device Connector，华为的设备调试命令行工具，类似 Android 的 adb |
| gRPC | 高性能 RPC 框架，投屏视频流通过它传输 |
| H.264 | 视频编码格式，手机录制屏幕后编码成这个格式传给 Mac |
| Annex-B / AVCC | H.264 数据的两种封装格式，前者用起始码分隔，后者用长度前缀 |
| NAL Unit | H.264 的基本数据单元，包含 SPS、PPS、I 帧、P 帧等类型 |
| SPS | 序列参数集，包含视频宽高等关键信息 |
| PPS | 图像参数集，包含编码参数 |
| I 帧 | 关键帧，可以独立解码，是画面的完整快照 |
| P 帧 | 预测帧，参考前面的帧解码，体积小但不能独立解码 |
| uinput | Linux 内核的虚拟输入设备接口，可以模拟触摸、按键等输入 |
| AVSampleBufferDisplayLayer | macOS 的硬件视频渲染层，直接用 GPU 解码显示视频 |
| VideoToolbox | macOS 的硬件视频编解码框架 |
| 端口转发 | 把设备上的端口映射到 Mac 本地端口，让 Mac 可以直接访问设备服务 |
| Bridge | 桥接程序，把一种协议转换成另一种（这里把 gRPC 转成 TCP） |
