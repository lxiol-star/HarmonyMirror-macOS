# 黑屏和会话清理问题修复

## 问题分析

### 1. 连接后黑屏

**根本原因**:
- `H264VideoLayer` 在 line 145 检查 `layer.superlayer != nil`
- 初始连接时,layer 可能还没有添加到视图层级
- 导致前几帧被丢弃,出现黑屏

**表现**:
- TCP 连接成功
- 收到视频数据
- 但屏幕一直黑屏,没有画面

**修复**:
```swift
// 修改前
guard let self, let layer = self._displayLayer, layer.superlayer != nil else { return }

// 修改后
guard let self, let layer = self._displayLayer else { return }
// AVSampleBufferDisplayLayer 会缓冲帧,直到被添加到视图层级
```

### 2. 视频层状态未重置

**根本原因**:
- `flushAndRemoveImage()` 只清理了显示层
- 没有重置解码器状态: `formatDescription`, `spsData`, `ppsData`, `firstPts` 等
- 重新连接时使用旧的格式信息,导致解码失败

**表现**:
- 第一次连接正常
- 断开后重新连接黑屏或花屏
- 日志显示 "Failed to create sample buffer"

**修复**:
```swift
func flushAndRemoveImage() {
    displayLayer.flushAndRemoveImage()
    // 重置所有状态,确保干净的重连
    formatDescription = nil
    spsData = nil
    ppsData = nil
    previousWasAnnexB = nil
    decodeCount = 0
    lastWidth = 0
    lastHeight = 0
    firstPts = nil
}
```

### 3. Bridge 进程复用导致冲突

**根本原因**:
- 尝试复用同一设备的 bridge 进程
- 但不同连接可能有不同的参数(分辨率、帧率等)
- 复用导致参数不匹配,视频流异常

**表现**:
- 断开后重新连接很慢
- 切换设备后卡顿
- 有时需要多次尝试才能连接成功

**修复**:
```swift
// 移除 bridge 复用逻辑,每次都重新启动
terminateBridge()
do {
    try await prepareDeviceForBridge(serial: serial)
    try startBridge(serial: serial)
} catch {
    // 错误处理
}
```

### 4. 断开连接清理不彻底

**根本原因**:
- `stopMirroring()` 延迟 60 秒才终止 bridge
- 目的是支持快速重连,但导致:
  - 端口被占用
  - 进程残留
  - 切换设备时冲突

**表现**:
- 断开后立即连接其他设备很卡
- 端口冲突错误
- 需要等待或重启应用

**修复**:
```swift
func stopMirroring() {
    // ... 清理代码 ...
    
    // 立即终止 bridge,不延迟
    // 用户明确断开或切换设备时,应该彻底清理
    bridgeTerminationTask?.cancel()
    bridgeTerminationTask = nil
    terminateBridge()
}
```

## 修复内容总结

### H264VideoLayer.swift

1. **移除 superlayer 检查** (line 145)
   - 允许在 layer 未添加到视图前就开始缓冲帧
   - 避免初始帧丢失导致的黑屏

2. **完整重置状态** (line 46-58)
   - 清理所有解码器状态
   - 确保重新连接时从干净状态开始

3. **添加绑定日志** (line 32-34)
   - 帮助调试 layer 绑定时机问题

### MirrorService.swift

1. **移除 bridge 复用** (line 99-114)
   - 每次连接都重新启动 bridge
   - 避免参数不匹配导致的问题

2. **立即终止 bridge** (line 428-444)
   - 断开连接时立即清理
   - 避免端口占用和进程残留

3. **改进日志** (line 177)
   - 添加 "waiting for first frame" 提示
   - 帮助诊断黑屏问题

## 性能影响

### 移除 bridge 复用的影响

**优点**:
- 连接更可靠,避免状态冲突
- 切换设备更快,不需要等待清理
- 代码更简单,更容易维护

**缺点**:
- 重新连接同一设备稍慢 (~1-2秒)
- 但这是可接受的,因为用户通常不会频繁断开重连

### 立即终止 bridge 的影响

**优点**:
- 切换设备更快
- 资源释放更及时
- 避免端口冲突

**缺点**:
- 无法快速重连同一设备
- 但实际使用中,用户断开后通常是要切换设备或结束使用

## 测试建议

### 1. 黑屏测试
```
1. 连接设备
2. 观察是否立即显示画面
3. 如果黑屏,检查日志:
   - "H264VideoLayer bound to display layer"
   - "H264VideoLayer input #1, bytes=..."
   - "SPS found", "PPS found"
```

### 2. 重连测试
```
1. 连接设备 A
2. 断开
3. 立即重新连接设备 A
4. 应该能正常显示画面
5. 重复 3-5 次,确保稳定
```

### 3. 切换设备测试
```
1. 连接设备 A
2. 断开
3. 立即连接设备 B
4. 应该流畅,不卡顿
5. 来回切换 A/B 多次
```

### 4. 快速切换测试
```
1. 连接设备
2. 立即断开
3. 立即重新连接
4. 重复 10 次
5. 不应该出现端口占用错误
```

## 调试技巧

### 查看日志
```bash
# 实时查看应用日志
log stream --predicate 'process == "HarmonyMirror"' --level debug

# 查看最近的错误
log show --predicate 'process == "HarmonyMirror"' --last 5m | grep -i error
```

### 检查进程
```bash
# 查看 bridge 进程
ps aux | grep deveco_cast_bridge

# 查看端口占用
lsof -i :18068  # bridge port
lsof -i :9568   # grpc port
```

### 检查视频流
```bash
# 查看 TCP 连接
netstat -an | grep 18068

# 查看数据传输
nettop -p HarmonyMirror
```

## 相关代码文件

- `HarmonyMirror/VideoStream/H264VideoLayer.swift` - 视频解码和显示
- `HarmonyMirror/Core/MirrorService.swift` - 连接管理和清理
- `HarmonyMirror/VideoStream/TCPStreamReceiver.swift` - TCP 流接收
- `tools/deveco_cast_bridge.py` - Bridge 进程

## 后续优化建议

1. **添加连接超时检测**
   - 如果 10 秒内没有收到第一帧,自动重连
   - 避免用户长时间等待黑屏

2. **优化 bridge 启动**
   - 预检查端口是否可用
   - 如果端口被占用,先清理再启动

3. **添加健康检查**
   - 定期检查视频流是否正常
   - FPS 长时间为 0 时自动重连

4. **改进错误提示**
   - 黑屏时显示具体原因
   - 提供重试按钮
