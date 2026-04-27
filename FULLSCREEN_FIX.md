# 全屏卡死问题修复

## 问题分析

用户报告切换全屏后应用卡死。经过代码审查,发现以下潜在问题:

### 1. 主线程阻塞
**位置**: `MirrorWindow.swift` 第225-240行

**问题**: 
- 全屏切换的通知回调中直接调用 `resetInputState()`
- `resetInputState()` 会调用 `enqueue()` 发送输入事件到设备
- 如果设备通信阻塞,会导致主线程卡死

**修复**:
```swift
// 修改前
service.inputInjector?.resetInputState()

// 修改后
Task { @MainActor in
    service.inputInjector?.resetInputState()
}
```

### 2. 窗口约束冲突
**位置**: `MirrorWindow.swift` 第406-410行

**问题**:
- 在全屏模式下设置 `window.contentAspectRatio` 
- 这与全屏窗口的约束冲突,可能导致布局死锁

**修复**:
```swift
private func configureResizeConstraints(for window: NSWindow, target: CGSize) {
    window.minSize = service.preferredMinWindowSize
    // 只在非全屏模式下设置宽高比
    if !isFullScreen {
        window.contentAspectRatio = target
    }
    window.collectionBehavior.insert([.fullScreenPrimary, .fullScreenAllowsTiling])
}
```

### 3. 窗口调整时机
**位置**: `MirrorWindow.swift` 第225-240行

**问题**:
- 全屏动画还在进行时就调用 `resizeWindowIfNeeded()`
- 可能与系统的全屏动画冲突

**修复**:
```swift
// 延迟窗口调整,等待全屏动画完成
Task { @MainActor in
    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
    resizeWindowIfNeeded(force: true, anchor: .top)
}
```

### 4. 线程安全
**位置**: `MirrorWindow.swift` 第464-472行

**问题**:
- 虽然通知观察者指定了 `queue: .main`
- 但为了确保线程安全,显式使用 `DispatchQueue.main.async`

**修复**:
```swift
observers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] note in
    guard let window = note.object as? NSWindow else { return }
    // 确保回调在主线程执行
    DispatchQueue.main.async {
        self?.onEnterFullScreen(window)
    }
})
```

## 修复内容总结

1. **异步化输入状态重置** - 避免主线程阻塞
2. **条件化宽高比约束** - 避免全屏模式下的约束冲突
3. **延迟窗口调整** - 等待全屏动画完成
4. **显式主线程调度** - 确保线程安全

## 测试建议

1. **基本全屏切换**:
   - 点击绿色全屏按钮进入全屏
   - 按 ESC 或点击退出全屏
   - 应该流畅无卡顿

2. **快速切换测试**:
   - 快速多次进入/退出全屏
   - 不应该出现卡死或崩溃

3. **全屏下的交互**:
   - 在全屏模式下点击、滑动设备屏幕
   - 输入应该正常响应

4. **网络断开测试**:
   - 在全屏模式下断开设备连接
   - 切换全屏时应该正常处理

## 技术细节

### InputQueue 机制
`InputInjector` 使用 actor-based 的 `InputQueue` 来序列化输入事件:
- 所有输入事件都通过队列异步执行
- 避免并发访问设备导致的问题
- 但如果设备通信阻塞,队列会积压

### 全屏动画时序
macOS 的全屏切换是一个复杂的动画过程:
1. 发送 `willEnterFullScreen` 通知
2. 执行全屏动画 (~0.3秒)
3. 发送 `didEnterFullScreen` 通知
4. 窗口约束生效

在步骤3时立即调整窗口可能与步骤4冲突,因此需要延迟。

### 窗口约束优先级
在全屏模式下:
- 系统强制窗口填满整个屏幕
- `contentAspectRatio` 约束会被忽略或导致冲突
- 应该只在窗口模式下使用宽高比约束

## 相关代码文件

- `HarmonyMirror/Views/MirrorWindow.swift` - 主要修复位置
- `HarmonyMirror/HDC/InputInjector.swift` - 输入队列机制
- `HarmonyMirror/Core/MirrorService.swift` - 服务状态管理

## 预防措施

为了避免类似问题,建议:

1. **避免在通知回调中执行耗时操作**
   - 使用 `Task` 异步执行
   - 或者使用 `DispatchQueue.global()` 后台执行

2. **窗口约束要考虑全屏模式**
   - 检查 `window.styleMask.contains(.fullScreen)`
   - 或维护 `isFullScreen` 状态

3. **动画完成后再调整布局**
   - 使用适当的延迟
   - 或监听动画完成通知

4. **测试边界情况**
   - 快速切换
   - 网络断开时切换
   - 设备旋转时切换
