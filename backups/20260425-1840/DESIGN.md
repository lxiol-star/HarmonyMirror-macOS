# DevEcoCastMac 方案设计

## 目标

做一个本地自用的 macOS 投屏工具，优先满足日常使用，不做发布上架。工具复用 DevEco Testing 已验证可用的设备侧投屏扩展：

- 设备侧扩展：`/data/local/tmp/libscreen_casting.z.so`
- 启动入口：`uitest start-daemon singleness --extension-name libscreen_casting.z.so ...`
- 控制/视频通道：`localabstract:scrcpy_grpc_socket`
- 视频格式：Annex-B H.264，经实测可由 VideoToolbox 解码

## 已验证事实

1. DevEco Testing 打开“设备投屏”后，设备上存在 `libscreen_casting.z.so` 进程。
2. `hdc fport tcp:<port> localabstract:scrcpy_grpc_socket` 后，可以用 DevEco Testing 自带 `scrcpy_pb2.py` / `scrcpy_pb2_grpc.py` 读取 `ScrcpyService/onStart`。
3. `ReplyMessage.payload["data"].val_bytes` 是 H.264 Annex-B 数据。
4. 本机样本 `/tmp/deveco-casting-probe.h264` 被 `ffprobe` 识别为 `h264 658x1416 25fps`。
5. gRPC Python 客户端必须清理 `http_proxy/https_proxy/ALL_PROXY`，否则会误连本地代理端口。

## 总体架构（v4 当前实现，2026-04-25）

```text
SwiftUI App
  ├─ DeviceDiscovery：USB/TCP 设备轮询、局域网 10178 端口自动发现、设备资料缓存
  ├─ HDCCommand：hdc target 解析、USB/Wi-Fi 连接、设备资料读取、输入注入
  ├─ MirrorService：启动/停止投屏流程，设备侧 casting 准备，bridge 复用与延迟终止，屏幕尺寸/方向状态同步
  ├─ TCPStreamReceiver：读取本地 TCP 帧流
  ├─ H264VideoLayer：H.264 解析、SPS/PPS 提取、CMSampleBuffer 构建、AVSampleBufferDisplayLayer 硬件渲染
  ├─ InputInjector：触摸坐标映射、黑边点击过滤、150ms 延迟阈值、FIFO Actor 队列
  └─ Python bridge：连接已转发的 scrcpy_grpc_socket，把 gRPC payload 转成简单 TCP 帧

HarmonyOS Device
  └─ libscreen_casting.z.so
      └─ localabstract:scrcpy_grpc_socket
```

Swift 与 Python bridge 之间使用本地 TCP：

```text
[UInt32 payloadLength big-endian][UInt8 flags][Int64 pts big-endian][H264 bytes]
```

其中 `payloadLength = 1 + 8 + len(H264)`，`flags & 1` 表示关键帧。

## 触摸交互设计（2026-04-25 更新）

采用 scrcpy 模式的 **150ms 延迟阈值** 区分点击与长按/拖拽：

| macOS 事件 | 设备端行为 | 实现方式 |
|-----------|-----------|---------|
| 快速点击 (<150ms) | 标准点击 | `uinput -T -c` |
| 长按 (>150ms) | 长按/三连 | `uinput -T -d` + 等待 + `uinput -T -u` |
| 拖拽 (>5pt) | 平滑滑动 | `uinput -T -d` + `uinput -T -m` (10Hz, 50ms smooth) + `uinput -T -u` |
| Home 按钮 | 返回桌面 | `uitest uiInput keyEvent Home` |
| Back 按钮 | 返回上一级 | `uitest uiInput keyEvent Back` |

### 事件语义映射

1. `mouseDown` 时**不立即发送任何事件**，启动 150ms 定时器。
2. 如果在 150ms 内松开 → 发送 `uinputClick`（标准点击，避免长按误判）。
3. 如果超过 150ms 仍按住，或移动超过 5pt → 发送 `touchDown` + 后续 `touchMove`/`touchUp`。

## 连接流程

### USB 模式

1. `hdc list targets` 发现设备。
2. 检查并终止已有 `libscreen_casting.z.so` 进程，避免手机/平板切换时复用僵住的旧流。
3. 验证 `/data/local/tmp/libscreen_casting.z.so` 存在，然后启动：
   ```shell
   hdc -t <serial> shell "/system/bin/uitest start-daemon singleness --extension-name libscreen_casting.z.so -scale 1 -frameRate 60 -bitRate 31457280 -p 8710 -screenId 0 -encodeType 0 -iFrameInterval 2000 -repeatInterval 33"
   ```
4. 清理并重建 `hdc -t <serial> fport tcp:<grpcPort> localabstract:scrcpy_grpc_socket`
5. Python bridge 以 `--skip-device-setup` 方式启动，只读取已准备好的 gRPC 视频帧并转成本地 TCP。
6. Swift App 连接 bridge TCP，解码并显示。

### Bridge 复用策略（2026-04-25 更新）

- 断开投屏时**延迟 60 秒**再终止 bridge 进程。
- 重连同一设备时**复用已有 bridge**，实现秒连。
- 切换设备或首次连接时，Swift 侧负责重启 casting 服务并重建 hdc forward；Python bridge 不再直接调用 hdc 做设备准备，避免 GUI App/Python 子进程下 hdc 偶发 `Connect server failed`。
- Wi-Fi 目标连接前会先尝试 `hdc tconn <ip>:10178` 自动恢复 TCP target。
- Python bridge 保留旧的设备准备逻辑作为命令行诊断路径；App 内默认使用预配置模式。

### Wi-Fi 无线调试与局域网自动发现（2026-04-25 更新）

当前实现同时支持手动连接和自动发现：

1. USB 连接时点击“开启无线调试”：
   ```shell
   hdc -t <serial> tmode port 10178
   ```
2. 手机/平板和 Mac 保持同一局域网。
3. 用户输入设备 IP，点击“连接 Wi-Fi”：
   ```shell
   hdc tconn <ip>:10178
   ```
4. 连接成功后刷新设备列表，后续投屏流程与 USB 一致。
5. 需要关闭时：
   ```shell
   hdc tconn <ip>:10178 -remove
   hdc -t <serial> tmode usb
   ```

自动发现策略：

- `DeviceDiscovery` 每 12 秒读取 Mac 当前 IPv4 网卡，按同 `/24` 网段扫描 `10178` 端口。
- 对探测成功且当前未连接的目标自动执行 `hdc tconn <ip>:10178`。
- `hdc list targets -v` 只展示 `Connected` 目标，忽略 `Offline` 旧 TCP 连接。
- 失败目标短期缓存 60 秒，避免每轮扫描反复打同一个不可用 IP。

### 手机/平板与横竖屏

- 设备列表保存 `ConnectionKind`、`FormFactor`、`DeviceProfile`，UI 区分 USB、Wi-Fi、手机和平板。
- 连接按钮显示“连接手机/连接平板”，并带设备名 accessibility label，便于自动化测试定位。
- `H264VideoLayer` 从 SPS 解析真实视频宽高，`MirrorService` 同步到当前设备、状态栏和窗口最小尺寸。
- 投屏窗口根据当前宽高显示“横屏/竖屏”，横屏设备使用更宽的最小窗口，平板竖屏使用更大的窗口基线。
- 投屏窗口会在真实分辨率变化后主动同步 macOS window frame，视频区域按设备比例固定尺寸，避免横屏或平板竖屏时在窗口内部留下大面积黑边。
- 输入映射继续按视频实际 aspect-fit 区域换算坐标；黑边区域点击会被丢弃，避免横屏/平板窗口中误触屏幕边缘。

### 2026-04-25 实机验证

- 手机 `PLA-AL10`：Wi-Fi `10.1.2.224:10178`，竖屏 `1316x2832`，可出画面。
- 平板 `MLR-AL10`：USB `5KPBB25C21200023`，横屏 `2560x1600`，实测约 `46 fps`，Back/Home 输入按钮可操作。
- 已从手机拉取并上传 `libscreen_casting.z.so` 到平板 `/data/local/tmp/libscreen_casting.z.so`；后续平板不再依赖先打开 DevEco Testing 投屏。

### 局域网拓扑建议

Wi-Fi 调试本质上只要求 Mac 能访问手机的 `10178` 端口。常见家庭路由器、公司网络和访客 Wi-Fi 可能启用客户端隔离，导致同一 Wi-Fi 下也无法 `tconn`。

优先级建议：

1. **同一路由器局域网**：最简单，但受路由器隔离策略影响。
2. **手机开热点，Mac 连接手机热点**：稳定性通常最好，手机 IP 由热点网段分配，Mac 直连手机。
3. **Mac 共享网络给手机**：可作为备用方案，但 macOS 通常不能把同一个 Wi-Fi 同时作为上联网和共享 AP，需要 Mac 通过以太网/USB/其他网卡上网后再共享 Wi-Fi。
4. **反向小内网**：手机先连 Wi-Fi 并开热点，Mac 再连手机热点。这对本 App 是可行的，自动发现会扫描 Mac 所在热点网段并尝试连接 `10178`；问题是部分设备会在开热点时关闭自身 Wi-Fi 或做 NAT 隔离，需要实测。

后续可在 App 中加入“网络诊断”：
- 显示 Mac 当前 IP 与默认网关。
- 对用户输入的手机 IP 做 TCP `10178` 端口探测。
- `tconn` 失败时提示尝试手机热点/关闭路由器客户端隔离。

## 第一版范围

- 设备列表刷新。
- Wi-Fi 调试入口：开启无线端口、按 IP 连接、断开 Wi-Fi 目标。
- 启动本地 Python bridge。
- 连接 `scrcpy_grpc_socket` 并读取 H.264。
- VideoToolbox 解码显示。
- 基础触控/返回/主页等输入注入沿用 hdc/uitest。

## 已知局限（2026-04-25）

## 当前实现更新（2026-04-25 18:40）

- 手机和平板统一走 `HarmonyDevice.formFactor`，设备卡片显示 `连接手机` / `连接平板`。
- 局域网发现通过 `hdc list targets -v` 读取 USB/TCP 目标，列表同时保留手动 IP 入口。
- 投屏启动前由 Swift 端准备设备：复用设备上的 `libscreen_casting.z.so`，启动 `uitest start-daemon`，重建 `scrcpy_grpc_socket` 转发；Python bridge 只负责 gRPC 到本机 TCP/H.264 的转发。
- 投屏窗口按实时视频尺寸自适应。横屏平板使用宽窗口，竖屏设备使用窄高窗口；顶部 `Back/Home/断开` 和底部 `fps + 分辨率` 固定保留。
- 新增设备显示尺寸监控：连接后每 1.5 秒读取 `hidumper DisplayManagerService` 的 `Display ID: 0` 宽高；如果设备横竖屏与当前视频流不一致，自动重启 casting 和 bridge，让 Mac 窗口跟随横竖屏变化。

## 实测结果（2026-04-25 18:40）

- 平板 `MLR-AL10` USB：当前横屏 `2,560×1,600`，Mac 窗口已切换为横向比例，顶部按钮和底部状态栏可见。
- 手机 `PLA-AL10` Wi-Fi：已发现 `10.1.2.224:10178` TCP 目标，保留手动 IP 与卡片连接入口。
- `xcodebuild -project HarmonyMirror.xcodeproj -scheme HarmonyMirror -destination platform=macOS -derivedDataPath .build/DerivedData build` 通过。
- 注意：不要直接执行 `HarmonyMirror.app/Contents/MacOS/HarmonyMirror`。Debug 构建需要通过 LaunchServices 打开 `.app`，否则可能在 AppKit `_RegisterApplication` 阶段 abort。

## 已知局限（2026-04-25）

1. **拖拽跳跃**：`hdc shell` 每次命令往返约 100ms，10Hz touchMove 下仍有可感知的跳跃。根治需设备端常驻代理。
2. **边缘手势失效**：系统级音量/亮度手势需要触摸从屏幕外缘（x<0）开始，`uinput -T` 无法模拟负坐标。
3. **偶发重连延迟**：IDR 关键帧间隔 2 秒，新客户端连接时若错过 IDR，平均等待约 0.5-1 秒。

## 中长期架构：HarmonyAgent（设备端常驻代理）

**目标**：在 HarmonyOS 设备上运行 C 编写的常驻二进制，macOS 端通过 `hdc fport` 转发的 TCP socket 直接发送触摸事件，Agent **直接 `write(/dev/uinput)`** 注入内核，彻底绕开 `hdc shell` 的进程创建开销。

### 架构图

```
┌─────────────────┐         TCP (hdc fport)         ┌─────────────────────┐
│  macOS Swift端  │  ◄────────────────────────────►  │  HarmonyAgent (设备) │
│                 │    低延迟二进制协议 (<5ms RTT)    │                     │
│  TouchOverlay   │                                    │  ┌─────────────┐   │
│       ↓         │                                    │  │ gRPC Reader │   │
│  InputInjector  │                                    │  │  (video)    │   │
│       ↓         │                                    │  └──────┬──────┘   │
│  SocketSender   │───────────────────────────────────►│         ↓          │
│  (TCP 127.0.0.1)│   触摸事件帧: [cmd][payload]       │  ┌─────────────┐   │
└─────────────────┘                                    │  │  UInputHub  │   │
                                                       │  │  /dev/uinput│   │
                                                       │  └─────────────┘   │
                                                       └─────────────────────┘
```

### 触摸协议（TCP 二进制流）

```c
// 事件帧头: 固定 8 字节
struct TouchFrame {
    uint8_t  cmd;        // 0x01=DOWN, 0x02=UP, 0x03=MOVE, 0x04=KEY
    uint8_t  slot;       // 手指 slot (0-9, 支持多点)
    uint16_t x;          // 绝对坐标 X (0~65535 归一化)
    uint16_t y;          // 绝对坐标 Y (0~65535 归一化)
    uint16_t reserved;   // 预留 (pressure 等)
} __attribute__((packed));
```

### 延迟对比

| 方案 | 单次 touchMove 延迟 |
|-----|-------------------|
| 当前 `hdc shell uinput` | ~100ms（shell 创建 + 协议往返 + 解析） |
| HarmonyAgent | **<2ms**（TCP 本地环回 + 直接内核写入） |

### 实施路线图

1. **Phase 1**（2-3 天）：Agent 原型 — TCP echo + 单点 click 验证连通性
2. **Phase 2**（3-5 天）：完整协议 — 多点触控、KEY 事件、边缘手势实验
3. **Phase 3**（5-7 天，可选）：视频流合并 — Agent 替代 Python bridge

### 兼容性

Agent 路径是增量替换：
- 视频流：继续使用现有 Python bridge + `libscreen_casting.z.so`
- 触摸输入：新增 Agent 路径，旧 `hdc shell uinput` 路径保留作为 fallback
- 通过编译条件或运行时配置切换：`#if USE_AGENT` 或 `UserDefaults`

## 风险与处理

- DevEco 投屏 UI 与本 App 同时读取同一个 socket 时，可能只有一个 reader 能拿到帧。日常使用应由本 App 接管投屏；调试时避免同时打开 DevEco 投屏页面。
- 如果设备上没有 `libscreen_casting.z.so`，第一版提示用户先用 DevEco Testing 打开一次投屏；后续版本可从本机缓存或设备拉取。
- gRPC Python 依赖 `grpcio/protobuf`，第一版复用 `/Users/wyj/project/code/local/harmony/.venv-deveco-mirror`。
- HarmonyOS 可能限制 `/dev/uinput` 访问。备选：使用 `libinput` 或设备厂商提供的 HIDL 接口。
