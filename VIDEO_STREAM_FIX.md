# 视频流卡住问题修复

## 问题现象

用户报告:"正在接收视频流...等待设备端画面数据" 这个画面卡很久,指令可以执行但画面一直不出来。

## 问题分析

### 状态检查

**TCP 连接**: ✓ 正常
```
TCP localhost:18362->localhost:58985 (ESTABLISHED)
```

**Bridge 进程**: ✓ 运行中
```
[2026-04-27 11:00:26] onStart stream established
```

**Casting 服务**: ✓ 运行中
```
shell 6940 1 0 11:42:23 ? 00:00:01 uitest start-daemon singleness --extension-name libscreen_casting.z.so
```

**问题**: Bridge 日志显示 "onStart stream established" 后没有 "gRPC response" 消息,说明设备端没有推送视频帧。

### 根本原因

1. **Casting 服务状态异常**
   - 服务进程在运行,但没有真正开始编码推流
   - 可能是之前的连接残留状态
   - 需要重启服务才能正常工作

2. **缺少超时检测**
   - TCP 连接成功后,应用一直等待视频帧
   - 没有超时机制,用户只能手动断开重连
   - 体验很差

3. **服务复用导致问题**
   - 之前的优化中,如果服务已运行就跳过启动
   - 但运行中的服务可能处于异常状态
   - 导致新连接无法获取视频流

## 修复方案

### 1. 强制重启 Casting 服务

**修改**: `MirrorService.swift` prepareDeviceForBridge()

```swift
// 修改前: 检查服务是否运行,如果运行就跳过
let isRunning = existingProcess?.contains("libscreen_casting.z.so") == true
if !isRunning {
    // 只在未运行时启动
}

// 修改后: 总是重启服务,确保新鲜的流
let existingProcess = try? await hdcCommand.shell("ps -ef | grep libscreen_casting.z.so | grep -v grep", serial: serial)
if let output = existingProcess, output.contains("libscreen_casting.z.so") {
    // 杀死现有进程
    for line in output.components(separatedBy: "\n") {
        guard line.contains("libscreen_casting.z.so") else { continue }
        let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if columns.count >= 2, let pid = Int(columns[1]) {
            _ = try? await hdcCommand.shell("kill -9 \(pid)", serial: serial)
            Log.mirror.info("Killed existing casting process: \(pid)")
        }
    }
    try? await Task.sleep(nanoseconds: 500_000_000)
}

// 启动新的服务
_ = try? await hdcCommand.shell(startCommand, serial: serial)
try? await Task.sleep(nanoseconds: 500_000_000)
```

**效果**:
- 每次连接都重启 casting 服务
- 确保服务处于干净状态
- 避免残留状态导致的问题

### 2. 添加视频帧超时检测

**修改**: `MirrorService.swift` startMirroring()

```swift
if receiver.isConnected {
    state = .connected
    startDisplaySizeMonitor(device: device)
    Log.mirror.info("Video stream ready for \(serial), waiting for first frame...")

    // 添加超时检测 - 如果 10 秒内没收到帧,自动重启
    Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
        guard let self, case .connected = self.state, self.fps == 0 else { return }
        Log.mirror.warning("No video frame received after 10s, restarting connection")
        self.state = .disconnected("未收到视频数据，正在重试...")
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        await self.startMirroring(device: device)
    }
}
```

**效果**:
- 10 秒内没收到视频帧,自动重试
- 用户不需要手动断开重连
- 提升用户体验

## 性能影响

### 修复前

**连接流程**:
1. 检查服务是否运行
2. 如果运行,跳过启动
3. 连接 TCP
4. 等待视频帧 (可能永远等不到)

**问题**:
- 服务可能处于异常状态
- 没有超时,用户只能手动重试
- 成功率低

### 修复后

**连接流程**:
1. 杀死现有服务 (~0.5s)
2. 启动新服务 (~0.5s)
3. 连接 TCP (~0.2s)
4. 等待视频帧,10 秒超时自动重试

**改进**:
- 连接时间增加 ~1 秒 (可接受)
- 成功率大幅提升
- 自动重试,无需手动干预

## 其他可能的原因

如果修复后仍然卡住,可能是:

### 1. 设备屏幕关闭

**检查**:
```bash
hdc -t <serial> shell "dumpsys power | grep 'Display Power'"
```

**解决**: 唤醒屏幕
```bash
hdc -t <serial> shell "input keyevent 26"  # Power key
```

### 2. 设备性能不足

**现象**: 设备 CPU 占用 100%,无法编码

**检查**:
```bash
hdc -t <serial> shell "top -n 1 | grep uitest"
```

**解决**: 降低编码参数
- 降低分辨率: `-scale 0.5`
- 降低帧率: `-frameRate 15`
- 降低码率: `-bitRate 10485760`

### 3. gRPC 连接问题

**检查**: Bridge 日志
```bash
tail -f /tmp/DevecoCastMac-bridge.log
```

**关键日志**:
- "gRPC channel ready" - gRPC 连接成功
- "onStart stream established" - 流建立成功
- "gRPC response #N" - 收到视频帧

**如果没有 "gRPC response"**: 
- 检查端口转发: `hdc fport ls`
- 检查 gRPC 端口: `lsof -i :9862`
- 重启 hdc server: `hdc kill -r`

### 4. 网络问题

**检查延迟**:
```bash
ping <device-ip>
```

**如果延迟 > 100ms**:
- WiFi 信号弱
- 网络拥塞
- 建议使用 USB 连接

## 调试建议

### 启用详细日志

在 `MirrorService.swift` 中添加:

```swift
// 连接成功后
Log.mirror.info("TCP connected, waiting for video frames...")

// 收到第一帧后
Log.mirror.info("First video frame received! fps=\(fps)")
```

在 `H264VideoLayer.swift` 中添加:

```swift
// 收到帧数据
if decodeCount <= 10 {
    Log.mirror.info("Frame #\(decodeCount): \(data.count) bytes, isKeyFrame=\(isKeyFrame)")
}
```

### 监控 Bridge

实时查看 bridge 日志:
```bash
tail -f /tmp/DevecoCastMac-bridge.log | grep -E "(gRPC|frame|client)"
```

### 检查设备状态

```bash
# 检查屏幕状态
hdc -t <serial> shell "dumpsys window | grep mAwake"

# 检查 CPU 使用率
hdc -t <serial> shell "top -n 1 | head -20"

# 检查内存
hdc -t <serial> shell "cat /proc/meminfo | grep MemAvailable"
```

## 测试建议

### 1. 正常连接测试
```
1. 连接设备
2. 应该在 3-5 秒内看到画面
3. 如果 10 秒没画面,应该自动重试
```

### 2. 重连测试
```
1. 连接设备,看到画面
2. 断开连接
3. 立即重新连接
4. 应该能正常显示画面
```

### 3. 异常状态测试
```
1. 手动启动 casting 服务但不连接
2. 等待 1 分钟让服务进入异常状态
3. 尝试连接
4. 应该能自动重启服务并显示画面
```

### 4. 超时测试
```
1. 连接设备
2. 在设备上手动杀死 casting 进程
3. 应该在 10 秒后自动重试
```

## 相关代码

- `HarmonyMirror/Core/MirrorService.swift` - 连接管理和超时检测
- `HarmonyMirror/VideoStream/TCPStreamReceiver.swift` - TCP 流接收
- `HarmonyMirror/VideoStream/H264VideoLayer.swift` - 视频解码
- `tools/deveco_cast_bridge.py` - Bridge 进程

## 后续优化

1. **更智能的重试策略**
   - 第一次失败: 重启服务
   - 第二次失败: 重启 bridge
   - 第三次失败: 重启 hdc server
   - 第四次失败: 提示用户检查设备

2. **健康检查**
   - 定期检查 fps
   - 如果 fps 长时间为 0,自动重连
   - 避免"假连接"状态

3. **用户提示优化**
   - 显示重试次数
   - 显示具体的错误原因
   - 提供手动重试按钮
