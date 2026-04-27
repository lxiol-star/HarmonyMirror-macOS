# HarmonyMirror Agent 触控方案审查报告

> 审查范围: TouchOverlayView → MirrorWindow 手势机 → InputQueue → InputInjector → AgentSocketClient → harmony_agent.c → uinput
> 问题描述: 操作不跟手、双指滑动被误读、双击/滑动混淆

---

## 一、触控链路总览

```
Mac App 端
┌──────────────────────────────────────────────────────────────────────┐
│ TouchOverlayView (NSView)                                            │
│  mouseDown / mouseDragged / mouseUp / scrollWheel / magnify          │
│  ⬇                                                                   │
│ MirrorWindow gesture state machine                                   │
│  ⬇  150ms long-press delay ← ⚠️                                      │
│ InputInjector.enqueue()                                              │
│  ⬇                                                                   │
│ InputQueue (actor) — 串行化, 去重                                    │
│  ⬇                                                                   │
│ executeWithAgentIfAvailable()                                         │
│  ╱                         ╲                                         │
│ ✅ Agent TCP (~2ms)        ❌ hdc uinput (~100ms)                    │
└──────────────────────────────────────────────────────────────────────┘

Device 端
┌──────────────────────────────────────────────────────────────────────┐
│ harmony_agent.c (监听 127.0.0.1:8711)                               │
│  ⬇  8 字节 TouchFrame 协议                                          │
│ send_touch() → /dev/uinput                                           │
│  → EV_ABS / EV_KEY / EV_SYN                                         │
│  → 鸿蒙系统 input 子系统                                              │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 二、问题 1：不跟手 — 每笔操作内置 150ms 延迟 🔴

### 根因

MirrorWindow.swift 在每个 `mouseDown` 事件中，**固定延迟 150ms 后才发送 touchDown**：

```swift
// L: 等待区分"轻触"和"长按"
pendingTouchDownTask = Task {
    try? await Task.sleep(nanoseconds: UInt64(longPressThreshold * 1_000_000_000))
    // ↑ 150ms 硬延迟！
    guard !Task.isCancelled else { return }
    hasSentTouchDown = true
    service.inputInjector?.touchDown(windowPoint: point, windowSize: size)
}
```

如果用户在 150ms 内就松手（mouseUp），这个 Task 被 cancel，由 `click()` 替代执行：

```swift
// mouseUp 处理中:
if pressDuration < longPressThreshold {
    service.inputInjector?.click(windowPoint: point, windowSize: size)
    // → click也是: touchDown + 35ms sleep + touchUp
}
```

### 延迟累积

| 阶段 | 延迟 |
|------|:----:|
| mouseDown → 等待长按判断 | **150ms** |
| click 内部 sleep | 35ms |
| InputQueue actor 调度 | ~1-5ms |
| Agent TCP 传输 | ~1-2ms |
| uinput 写入 | ~1ms |
| **合计（每次点击）** | **~190ms** |

这解释了"不跟手"：从手指碰到触控板到手机屏幕响应，最短也要 190ms。

### 类似产品的标杆

| 产品 | 触控延迟 |
|------|:-------:|
| Apple Sidecar | ~40-60ms |
| scrcpy (Android) | ~50-80ms |
| **本方案** | **~190ms** |

### 修复方案

**不要延迟 touchDown。** 立即发送 touchDown，在 mouseUp 时决定是 click 还是长按：

```swift
// mouseDown: 立即发送，不加延迟
func handleMouseDown(point: CGPoint, size: CGSize) {
    touchDownTime = Date()
    isDragging = false
    hasSentTouchDown = true // 不需要 Task 延迟
    service.inputInjector?.touchDown(windowPoint: point, windowSize: size)
}

// mouseUp: 根据按住时长判断
func handleMouseUp(point: CGPoint, size: CGSize) {
    let pressDuration = Date().timeIntervalSince(touchDownTime)
    let dist = hypot(point.x - dragStart.x, point.y - dragStart.y)
    
    if isDragging {
        service.inputInjector?.touchUp(windowPoint: point, windowSize: size)
    } else if pressDuration < longPressThreshold && dist < dragThreshold {
        // 短按 + 小位移 = click
        // 但 touchDown 已发送，只需 touchUp
        // 或者更好的方案: touchDown → wait 35ms → touchUp 由 click() 合并处理
        service.inputInjector?.touchUp(windowPoint: point, windowSize: size)
    } else {
        // 长按 = 保持 touchDown 状态
        service.inputInjector?.touchUp(windowPoint: point, windowSize: size)
    }
}
```

**关键改动**：去掉 mouseDown 中的 Task.sleep，改为立即发送。这样可以节省 150ms。

---

## 三、问题 2：双指滑动被胡乱解读 🔴

### 根因 2a：Mac 双指滑动被映射为单点 swipe

`TouchOverlayView` 只处理鼠标事件，**没有实现任何多点触控手势识别**：

```swift
// TouchOverlayView 支持的事件
override func mouseDown(with event: NSEvent) → 单指
override func mouseDragged(with event: NSEvent) → 单指
override func mouseUp(with event: NSEvent) → 单指
override func rightMouseDown(with event: NSEvent) → 右键
override func scrollWheel(with event: NSEvent) → 双指滑动触发
override func magnify(with event: NSEvent) → 双指捏合
```

**关键事实**：Mac 触控板上双指滑动产生的是 `scrollWheel` 事件，不是 `mouseDragged`。当前代码收到 `scrollWheel` 后走 `InputInjector.scroll()`，它被转换为**单点 swipe** 发送到设备：

```swift
func scroll(windowPoint: CGPoint, windowSize: CGSize, deltaX: CGFloat, deltaY: CGFloat) {
    // 8Hz 节流
    guard now.timeIntervalSince(lastScrollTime) >= scrollMinInterval else { return }
    ...
    enqueue(.swipe(
        x1: start.x, y1: start.y,
        x2: endX, y2: endY,
        durationMs: max(80, min(220, Int(distance / 3)))
    ))
    // ⚠️ .swipe 在 InputQueue 中去重排队
    // ⚠️ 单点 swipe ≠ 双指滑动
}
```

当用户双指滑动时，系统产生 `scrollWheel`（带 smooth delta），代码将其当作"滑动到某位置"。但设备端收到的是一个**手指从 A 点移动到 B 点**的 swipe 动作——这不等于双指滚动手势。

### 根因 2b：InputQueue 去重导致中间帧丢失

InputQueue 对 `.swipe` 和 `.touchMove` 有去重逻辑：

```swift
func enqueue(_ action: InputAction, executor: ...) {
    switch action {
    case .touchMove:
        queue.removeAll { if case .touchMove = $0 { return true } else { return false } }
    case .swipe:
        queue.removeAll { if case .swipe = $0 { return true } else { return false } }
    ...
    }
}
```

当快速连续产生多个 scrollWheel 事件时，InputQueue 只保留**最后一个**。中间的滑动轨迹全部丢失，用户看到的就是跳跃式的"乱动"。

### 根因 2c：双指滑动与点击混淆

当用户双指轻触触控板（而非滑动），某些 Mac 可能产生极小幅度的 scrollWheel 事件或 mouseDown 事件。这些被解读为：
- scrollWheel → swipe → 设备端手指开始移动
- 如果同时有误触发的 mouseDown → tap/click

两种事件的混合导致"胡乱解读"。

### 修复方案

**方案 A（推荐）**：将 Mac 双指滑动映射为鸿蒙系统的双指手势

```swift
// scrollWheel 不发送单点 swipe
// 改为: 使用 hdc shell 执行双指滑动命令
// 鸿蒙系统: input touchscreen swipe <x1> <y1> <x2> <y2>
// 或: uinput 模拟多指操作 (slot 0 + slot 1 同时 move)

override func scrollWheel(with event: NSEvent) {
    // 识别两指水平/垂直滑动
    if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
        // 水平滑动 → 左右切换、返回等
        // 映射到鸿蒙系统特定手势
    } else {
        // 垂直滑动 → 页面滚动
        // 映射到 touchevent + uinput 双指模式
    }
}
```

**方案 B（更实际）**：scrollWheel 转换为增量式触摸事件

```swift
// 不再发送固定起点终点的 .swipe
// 改为持续 touchMove 增量
func scroll(windowPoint: CGPoint, windowSize: CGSize, deltaX: CGFloat, deltaY: CGFloat) {
    // 1. 如果还没有 touchDown → 先发送 touchDown
    // 2. 根据 delta 累积触摸位置
    // 3. 发送 touchMove 到新位置
    // 4. 用户手指离开触控板 → touchUp
}
```

**方案 C（最低改动）**：增加 scroll 启用手势过滤

```swift
// 在 TouchOverlayView 中:
// 忽略非预期的 scrollWheel 组合
override func scrollWheel(with event: NSEvent) {
    // 只有明确的双指滑动才处理
    guard event.phase != .cancelled, event.momentumPhase != .begin else { return }
    // 将双指从 "swipe" 改为 "touchMove 序列"
    onDragScroll?(flipped(event), bounds.size, dx, dy)
}
```

---

## 四、问题 3：双击/长按/滑动的歧义 🔴

### 根因

当前手势状态机用一个 key 参数尝试区分所有交互：

```swift
@State private var dragStart: CGPoint?
@State private var dragStartTime: Date?
@State private var isDragging = false
@State private var hasSentTouchDown = false
// ↑ 6 个 @State 变量维护一个复杂的 FSM
```

且 mouseUp 中的判断逻辑链路过长：

```swift
if isDragging {
    // 拖拽 → touchUp
} else if dist < dragThreshold {
    if pressDuration < longPressThreshold {
        // → click
    } else if hasSentTouchDown {
        // → touchUp
    } else {
        // → touchDown + touchUp
    }
}
```

问题：当用户**快速双击**时：
1. 第一次点击：mouseDown → 150ms Task → cancelled → click
2. 第一次松开：mouseUp → click (touchDown + 35ms + touchUp)
3. 第二次点击：mouseDown → 150ms Task → ... 
4. **设备实际上收到的是两个独立的点击间隔 35ms**

鸿蒙系统可能将两个快速独立点击解读为**双指操作**或**缩放**，取决于系统手势识别逻辑。

### 修复方案

```swift
// 在 InputInjector 实现双击检测
private var lastClickTime: Date = .distantPast
private let doubleClickThreshold: TimeInterval = 0.3

func handleTap(point: CGPoint) {
    let now = Date()
    if now.timeIntervalSince(lastClickTime) < doubleClickThreshold {
        // 双击 → 发送双击事件或缩放
        // 例如: 发送两个 touchDown+touchUp 序列，间隔 80ms
        sendDoubleClick(point)
        lastClickTime = .distantPast
    } else {
        lastClickTime = now
        sendSingleClick(point)
    }
}
```

---

## 五、问题 4：多指触控缺失 🟡

### 根因

`harmony_agent.c` 支持 10 点触控（slot 0-9），但 `TouchOverlayView` 只有单点 mouse 事件。多指触控的入口是 `NSTouch` 和 `NSGestureRecognizer`，但代码里一个都没实现。

```swift
// TouchOverlayView 缺少的方法:
override func touchesBegan(with event: NSEvent)  // ❌
override func touchesMoved(with event: NSEvent)  // ❌
override func touchesEnded(with event: NSEvent)  // ❌
```

现代 macOS 触控板支持 `NSTouch`，用 `event.touches(matching:)` 可以获取所有触控点。如果这块不实现，多指操作（双指平移、三指切换）永远无法正常工作。

### 修复方案

```swift
final class TouchOverlayView: NSView {
    override var acceptsTouchEvents: Bool { true }
    
    override func touchesBegan(with event: NSEvent) {
        let touches = event.touches(matching: .any)
        for touch in touches {
            let normPoint = normalize(touch.normalizedPosition)
            if touch.phase == .began {
                agent.sendTouch(.touchDown, slot: UInt8(touch.identity.hash), 
                                x: normPoint.x, y: normPoint.y)
            }
        }
    }
    
    override func touchesMoved(with event: NSEvent) {
        let touches = event.touches(matching: .any)
        for touch in touches {
            let normPoint = normalize(touch.normalizedPosition)
            agent.sendTouch(.touchMove, slot: UInt8(touch.identity.hash),
                            x: normPoint.x, y: normPoint.y)
        }
    }
    
    override func touchesEnded(with event: NSEvent) {
        let touches = event.touches(matching: .any)
        for touch in touches {
            agent.sendTouch(.touchUp, slot: UInt8(touch.identity.hash),
                            x: 0, y: 0)
        }
    }
}
```

---

## 六、方案可行性评估

### Agent 方案本身可行吗？

**可行，但当前实现有 4 个关键缺陷：**

| # | 缺陷 | 影响 | 修复难度 |
|---|------|------|:-------:|
| 1 | 150ms 固定延迟 | 每笔操作不跟手 | 低 |
| 2 | 无多指触控支持 | 双指操作不可用 | 中 |
| 3 | scrollWheel 被映射为单点 swipe | 双指滑动失效 | 低~中 |
| 4 | 无双击检测 | 双击被拆成两个独立 tap | 低 |

Agent → uinput 路径本身是**正确的技术方向**。它比 hdc 快约 50x（~2ms vs ~100ms）。uinput 设备创建、多 slot、压力/触摸区域等实现质量较高。只要修复上述 4 个问题，方案是可行的。

### 不可行的部分

**`/dev/input/eventX` 直接写入模式**（CMD_OPEN_EVENT）不可行。鸿蒙系统有 SELinux 策略限制，非 root 应用无法打开 `/dev/input/event*`。这属于实验性代码，在 Review 中已标注为 "code written but untested"。建议移除或标记为实验性。

### 性能基准目标

修复后可达：
| 指标 | 当前 | 目标 |
|------|:---:|:---:|
| 点击延迟 | ~190ms | <50ms |
| 滑动响应 | ~150ms | <30ms |
| 多指支持 | 无 | 2 指基础操作 |
| 双击准确 | ❌ 会误判 | ✅ 可靠 |
| scroll 映射 | swipe → 单点 | 双指手势正确映射 |

---

## 七、修复优先级

### P0 — 必须立即修复

1. **删除 mouseDown 的 150ms Task.sleep**（见 §二）
   - 文件：MirrorWindow.swift
   - 改动：5 行
   - 效果：点击延迟从 190ms → 40ms

2. **scrollWheel 不再映射为单点 swipe**（见 §三）
   - 文件：TouchOverlayView.swift / InputInjector.swift
   - 改动：10-15 行
   - 效果：双指滑动不再被"胡乱解读"

### P1 — 强烈建议修复

3. **TouchOverlayView 实现多点触控**（见 §五）
   - 文件：TouchOverlayView.swift
   - 改动：30-50 行
   - 效果：双指、三指手势正确工作

4. **InputInjector 实现双击检测**（见 §四）
   - 文件：InputInjector.swift
   - 改动：15-20 行

### P2 — 建议优化

5. 滑动增量改为 touchMove 流（替代 swipe 点对点）
6. 移除 `CMD_OPEN_EVENT` 相关不可行代码
7. 添加 `NSTouch` 事件捕获

---

## 八、结论

**Agent 触控方案本身是可行的，但当前 macOS 端的手势处理实现有严重缺陷，导致了"不跟手"和"双指被胡乱解读"两个用户体验问题。**

不同于不可修复的架构问题（如 hdc CLI 的固有限制），这里的 4 个问题都可以通过**修改 Mac 端 Swift 代码**解决，无需改动 C agent 或设备端。核心改动在 MirrorWindow 和 TouchOverlayView 两个文件，总共约 60-90 行代码变更。

如果修复全部实施，预期用户体验可以接近 scrcpy 级别（50ms 点击延迟 + 正确的多指手势映射）。

> ⚠️ 标注"不可行"的部分：`CMD_OPEN_EVENT`（direct event 模式）在非 root 鸿蒙设备上被 SELinux 阻止，此路径不可用，应标记为实验性代码。

---

## 九、修复实施记录（2026-04-26）

### 已完成修复

| # | 问题 | 文件 | 修复方式 | 状态 |
|---|------|------|---------|:--:|
| P0-1 | 150ms 延迟 | `MirrorWindow.swift` | 删除 `pendingTouchDownTask` + `Task.sleep(150ms)`，mouseDown 立即发送 touchDown | ✅ |
| P0-2 | scrollWheel→swipe | `VideoPlayerView.swift` + `InputInjector.swift` | scrollWheel 按 phase 分发（.began → touchDown, .changed → touchMove, .ended → touchUp）；scrollDelta 改为增量 touchMove（修复起点终点相同的 bug） | ✅ |
| P0-3 | agent 二进制缺失 | `agent/harmony_agent.c` | 用 HarmonyOS NDK clang 编译 `harmony_agent`（ELF aarch64 静态链接），`InputInjector` 双通道中 Agent TCP 路径生效 | ✅ |
| P1-1 | 双指滑动=点击 | `VideoPlayerView.swift` | 添加 `activeTouchCount`（NSTouch 跟踪），双指时抑制 mouseDown/rightMouseDown 事件，让 scrollWheel 独占控制 | ✅ |
| P1-2 | 多指触控 | `VideoPlayerView.swift` + `InputInjector.swift` | `touchesBegan/Moved/Ended` 处理 ≥3 指；`multiTouchBegan/Moved/Ended` (slot-based) | ✅ |
| P1-3 | 双击检测 | `InputInjector.swift` | lastClickTime + lastClickPoint 跟踪，300ms / 40px 阈值检测双击 | ✅ |
| P1-4 | 捏合→设备 | `MirrorWindow.swift` | onMagnifyPhase 替换 onMagnify；双 slot (0+1) 发送捏合手势到设备 | ✅ |
| P2-1 | 全屏后触控失效 | `MirrorWindow.swift` + `VideoPlayerView.swift` | `resetInputState()` 清理卡住的 scroll session；`viewDidMoveToWindow()` 恢复触控能力；`.allowsHitTesting(false)` 防止 loading overlay 拦截 | ✅ |
| P2-2 | 窗口双开 | `HarmonyMirrorApp.swift` | 删除 AppDelegate 重复创建 NSWindow 的 Timer/dispatch 逻辑 | ✅ |
| P2-3 | USB 无 Agent 延迟高 | `agent/harmony_agent` | 编译 agent 二进制，触控延迟从 ~100ms → ~2ms | ✅ |
| P2-4 | USB/WiFi 多卡片 | `Models.swift` + `DeviceDiscovery.swift` + `DeviceCard.swift` | DeviceGroup 合并模型；双向 profile 交叉填充（productName/deviceType 匹配）；合并模式保留 USB 设备 | ✅ |

### 未修复的已知问题

| 问题 | 原因 | 备注 |
|------|------|------|
| 帧率上限 46fps | 设备端 H.264 编码器硬件上限 | `-frameRate -1` 已尝试，提升有限 |
| 全屏触控偶尔失效 | SwiftUI 全屏动画可能破坏 NSViewRepresentable 事件链 | `viewDidMoveToWindow()` 加固已添加，需持续观察 |
| `/dev/input/eventX` 直写模式 | SELinux 阻止非 root 访问 | 实验性代码，不建议使用 |

### 核心架构变更

```
修复前: mouseDown → Task.sleep(150ms) → touchDown → hdc(~100ms) → /dev/uinput
修复后: mouseDown → touchDown(0ms) → Agent TCP(~2ms) → /dev/uinput

修复前: scrollWheel → .swipe(单点) → InputQueue 去重丢帧
修复后: scrollWheel → .began→touchDown / .changed→touchMove / .ended→touchUp (增量流)
```
