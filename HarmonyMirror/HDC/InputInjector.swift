import Foundation

@MainActor
final class InputInjector {
    private let hdcCommand: HDCCommand
    private let serial: String
    var screenWidth: Int = 1080
    var screenHeight: Int = 1920

    private enum InputAction {
        case click(x: Int, y: Int)
        case swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int)
        case touchDown(x: Int, y: Int)
        case touchUp(x: Int, y: Int)
        case touchMove(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int)
        case uinputKey(keyCode: Int)
        case uitestKey(name: String)
    }

    private actor InputQueue {
        private var queue: [InputAction] = []
        private var isExecuting = false
        private let maxQueueSize = 10  // Prevent queue from growing too large

        func enqueue(_ action: InputAction, executor: @escaping (InputAction) async -> Void) {
            // Deduplicate: keep only the latest touchMove (intermediate drag positions can be dropped)
            switch action {
            case .touchMove:
                queue.removeAll { if case .touchMove = $0 { return true } else { return false } }
            default:
                break
            }

            // Drop old actions if queue is too large
            if queue.count >= maxQueueSize {
                Log.input.warning("Input queue full (\(self.queue.count)), dropping oldest action")
                self.queue.removeFirst()
            }

            queue.append(action)
            guard !isExecuting else { return }
            isExecuting = true
            Task {
                while !queue.isEmpty {
                    let action = queue.removeFirst()
                    await executor(action)
                }
                isExecuting = false
            }
        }

        func drainQueuedSwipes() {
            queue.removeAll { if case .swipe = $0 { return true } else { return false } }
        }

        func clearQueue() {
            queue.removeAll()
        }
    }

    private let inputQueue = InputQueue()
    private var isDragging = false
    private var lastDragPoint: CGPoint?
    private var currentDeviceTouchPoint: (x: Int, y: Int)?
    private var lastTouchMoveTime: Date = .distantPast
    private var lastScrollTime: Date = .distantPast
    private let touchMoveMinInterval: TimeInterval = 1.0 / 10.0  // throttle to ~10Hz
    private let scrollMinInterval: TimeInterval = 1.0 / 8.0     // throttle scroll to ~8Hz
    private let statusBarZoneFraction: CGFloat = 0.06  // top 6% of screen height = status bar zone
    private var agentClient: AgentSocketClient?

    // MARK: - Double-tap detection
    private var lastClickTime: Date = .distantPast
    private var lastClickPoint: (x: Int, y: Int)?
    private let doubleClickThreshold: TimeInterval = 0.3
    private let doubleClickDistance: CGFloat = 40  // max distance in device pixels

    // MARK: - Incremental scroll session
    private var scrollSessionActive = false
    private var scrollTouchPoint: (x: Int, y: Int)?
    private var scrollAccumX: CGFloat = 0
    private var scrollAccumY: CGFloat = 0
    private let scrollMoveThreshold: CGFloat = 4  // minimum accumulated delta to send a touchMove

    init(hdcCommand: HDCCommand, serial: String) {
        self.hdcCommand = hdcCommand
        self.serial = serial
    }

    func setAgentClient(_ client: AgentSocketClient?) {
        agentClient?.disconnect()
        agentClient = client
    }

    func click(windowPoint: CGPoint, windowSize: CGSize) {
        guard let dp = mapToDevice(windowPoint: windowPoint, windowSize: windowSize) else { return }
        enqueue(.click(x: dp.x, y: dp.y))
    }

    func drag(from start: CGPoint, to end: CGPoint, windowSize: CGSize) {
        guard let sp = mapToDevice(windowPoint: start, windowSize: windowSize),
              let ep = mapToDevice(windowPoint: end, windowSize: windowSize) else { return }
        let distance = hypot(CGFloat(ep.x - sp.x), CGFloat(ep.y - sp.y))
        let speed = max(800, min(4000, Int(distance * 10)))
        enqueue(.swipe(x1: sp.x, y1: sp.y, x2: ep.x, y2: ep.y, durationMs: speed))
    }

    func swipe(from start: CGPoint, to end: CGPoint, windowSize: CGSize) {
        guard let sp = mapToDevice(windowPoint: start, windowSize: windowSize),
              let ep = mapToDevice(windowPoint: end, windowSize: windowSize) else { return }
        let distance = hypot(CGFloat(ep.x - sp.x), CGFloat(ep.y - sp.y))
        let durationMs = max(100, min(500, Int(distance / 2)))
        enqueue(.swipe(x1: sp.x, y1: sp.y, x2: ep.x, y2: ep.y, durationMs: durationMs))
    }

    /// Begin a scroll session (on scrollWheel phase .began)
    func scrollBegin(windowPoint: CGPoint, windowSize: CGSize) {
        guard let dp = mapToDevice(windowPoint: windowPoint, windowSize: windowSize) else { return }
        scrollSessionActive = true
        scrollTouchPoint = dp
        scrollAccumX = 0
        scrollAccumY = 0
        enqueue(.touchDown(x: dp.x, y: dp.y))
    }

    /// Accumulate scroll delta and send touchMove when threshold exceeded
    func scrollDelta(deltaX: CGFloat, deltaY: CGFloat) {
        guard scrollSessionActive else { return }

        scrollAccumX += deltaX
        scrollAccumY += deltaY

        let dist = hypot(scrollAccumX, scrollAccumY)
        guard dist >= scrollMoveThreshold else { return }

        let scale: CGFloat = 3
        let dx = Int(scrollAccumX * scale)
        let dy = Int(scrollAccumY * scale)

        guard var point = scrollTouchPoint else { return }
        let newX = max(0, min(screenWidth - 1, point.x - dx))
        let newY = max(0, min(screenHeight - 1, point.y - dy))
        let fromX = point.x
        let fromY = point.y
        point = (x: newX, y: newY)
        scrollTouchPoint = point
        scrollAccumX = 0
        scrollAccumY = 0

        enqueue(.touchMove(x1: fromX, y1: fromY, x2: point.x, y2: point.y, durationMs: 10))
    }

    /// End a scroll session (on scrollWheel phase .ended)
    func scrollEnd() {
        guard scrollSessionActive, let point = scrollTouchPoint else { return }
        scrollSessionActive = false
        scrollTouchPoint = nil
        scrollAccumX = 0
        scrollAccumY = 0
        enqueue(.touchUp(x: point.x, y: point.y))
    }

    /// Cancel scroll session (on scrollWheel phase .cancelled)
    func scrollCancel() {
        guard scrollSessionActive else { return }
        scrollSessionActive = false
        scrollTouchPoint = nil
        scrollAccumX = 0
        scrollAccumY = 0
    }

    func back() {
        enqueue(.uitestKey(name: "Back"))
    }

    func home() {
        enqueue(.uitestKey(name: "Home"))
    }

    // MARK: - Screen wake & unlock

    func wake() {
        enqueue(.uinputKey(keyCode: 116)) // KEY_POWER
    }

    func swipeUpToUnlock() {
        let centerX = screenWidth / 2
        let startY = Int(Double(screenHeight) * 0.9)
        let endY = Int(Double(screenHeight) * 0.1)
        Task {
            do {
                try await hdcCommand.uinputTouchDown(x: centerX, y: startY, serial: serial)
                try? await Task.sleep(nanoseconds: 150_000_000)
                try await hdcCommand.uinputTouchMove(x1: centerX, y1: startY, x2: centerX, y2: endY, durationMs: 500, serial: serial)
                try? await Task.sleep(nanoseconds: 80_000_000)
                try await hdcCommand.uinputTouchUp(x: centerX, y: endY, serial: serial)
            } catch {
                Log.input.error("Unlock swipe failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Real-time touch events

    private var touchDownTime: Date?
    private let minPressDuration: TimeInterval = 0.02  // 20ms minimum press time for accidental touch rejection

    func touchDown(windowPoint: CGPoint, windowSize: CGSize) {
        guard let dp = mapToDevice(windowPoint: windowPoint, windowSize: windowSize) else { return }
        isDragging = true
        touchDownTime = Date()
        lastDragPoint = windowPoint
        lastTouchMoveTime = .distantPast
        currentDeviceTouchPoint = dp
        enqueue(.touchDown(x: dp.x, y: dp.y))
    }

    func touchMove(windowPoint: CGPoint, windowSize: CGSize) {
        guard let dp = mapToDevice(windowPoint: windowPoint, windowSize: windowSize),
              let current = currentDeviceTouchPoint else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTouchMoveTime) >= touchMoveMinInterval else { return }
        lastTouchMoveTime = now
        lastDragPoint = windowPoint
        enqueue(.touchMove(x1: current.x, y1: current.y, x2: dp.x, y2: dp.y, durationMs: 50))
        currentDeviceTouchPoint = dp
    }

    func touchUp(windowPoint: CGPoint, windowSize: CGSize) {
        guard let dp = mapToDevice(windowPoint: windowPoint, windowSize: windowSize) else { return }
        isDragging = false
        lastDragPoint = nil
        lastTouchMoveTime = .distantPast
        currentDeviceTouchPoint = nil
        let downTime = touchDownTime
        touchDownTime = nil

        let pressDuration = Date().timeIntervalSince(downTime ?? .distantPast)
        let now = Date()

        // Double-tap detection
        let timeSinceLastClick = now.timeIntervalSince(lastClickTime)
        if timeSinceLastClick < doubleClickThreshold,
           let lastPt = lastClickPoint,
           hypot(CGFloat(dp.x - lastPt.x), CGFloat(dp.y - lastPt.y)) < doubleClickDistance {
            // This is a double-tap: send two quick touch events
            // First touchUp for the current tap
            enqueue(.touchUp(x: dp.x, y: dp.y))
            // Reset for next
            lastClickTime = .distantPast
            lastClickPoint = nil
            return
        }

        lastClickTime = now
        lastClickPoint = dp

        let remaining = max(0, minPressDuration - pressDuration)
        if remaining > 0 {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                enqueue(.touchUp(x: dp.x, y: dp.y))
            }
        } else {
            enqueue(.touchUp(x: dp.x, y: dp.y))
        }
    }

    func cancelDrag() {
        isDragging = false
        lastDragPoint = nil
        currentDeviceTouchPoint = nil
        touchDownTime = nil
    }

    /// Reset all in-progress input state. Call when window transitions (fullscreen, etc.)
    /// to prevent stuck touches on the device.
    func resetInputState() {
        if scrollSessionActive {
            if let point = scrollTouchPoint {
                enqueue(.touchUp(x: point.x, y: point.y))
            }
            scrollSessionActive = false
            scrollTouchPoint = nil
            scrollAccumX = 0
            scrollAccumY = 0
        }
        cancelDrag()
    }

    // MARK: - Multi-touch (slot-based)

    func multiTouchBegan(windowPoint: CGPoint, windowSize: CGSize, slot: UInt8) {
        guard let dp = mapToDevice(windowPoint: windowPoint, windowSize: windowSize) else { return }
        Task { [weak self] in
            guard let self, let client = agentClient, client.isConnected else { return }
            client.sendMultiTouch(down: true, slot: slot, x: normalizedX(dp.x), y: normalizedY(dp.y))
        }
    }

    func multiTouchMoved(windowPoint: CGPoint, windowSize: CGSize, slot: UInt8) {
        guard let dp = mapToDevice(windowPoint: windowPoint, windowSize: windowSize) else { return }
        Task { [weak self] in
            guard let self, let client = agentClient, client.isConnected else { return }
            client.sendTouch(.touchMove, slot: slot, x: normalizedX(dp.x), y: normalizedY(dp.y))
        }
    }

    func multiTouchEnded(slot: UInt8) {
        Task { [weak self] in
            guard let self, let client = agentClient, client.isConnected else { return }
            client.sendMultiTouch(down: false, slot: slot, x: 0, y: 0)
        }
    }

    // MARK: - Status bar edge detection

    func isInStatusBarZone(windowPoint: CGPoint, windowSize: CGSize) -> Bool {
        guard let dp = mapToDevice(windowPoint: windowPoint, windowSize: windowSize) else { return false }
        let threshold = Int(CGFloat(screenHeight) * statusBarZoneFraction)
        return dp.y <= threshold
    }

    func touchDownFromEdge(windowPoint: CGPoint, windowSize: CGSize) {
        guard let dp = mapToDevice(windowPoint: windowPoint, windowSize: windowSize) else { return }
        let threshold = Int(CGFloat(screenHeight) * statusBarZoneFraction)
        let snappedY = dp.y <= threshold ? 0 : dp.y
        isDragging = true
        touchDownTime = Date()
        lastDragPoint = windowPoint
        lastTouchMoveTime = .distantPast
        currentDeviceTouchPoint = (x: dp.x, y: snappedY)
        enqueue(.touchDown(x: dp.x, y: snappedY))
    }

    func statusBarPullDown(fromLeft: Bool) {
        Task {
            await inputQueue.drainQueuedSwipes()
        }
        let startX = fromLeft ? screenWidth / 4 : Int(Double(screenWidth) * 0.95)
        let startY = fromLeft ? 5 : max(12, min(48, Int(Double(screenHeight) * 0.02)))
        let endY = Int(CGFloat(screenHeight) * (fromLeft ? 0.42 : 0.45))
        let speed = fromLeft ? 700 : 2_000
        Task {
            do {
                try await hdcCommand.inputSwipe(
                    x1: startX,
                    y1: startY,
                    x2: startX,
                    y2: endY,
                    speed: speed,
                    serial: serial
                )
            } catch {
                Log.input.error("Status bar pull down failed: \(error.localizedDescription)")
            }
        }
    }

    private func enqueue(_ action: InputAction) {
        Task {
            await inputQueue.enqueue(action) { [weak self] action in
                guard let self else { return }
                do {
                    if await self.executeWithAgentIfAvailable(action) {
                        return
                    }
                    switch action {
                    case .click(let x, let y):
                        try await self.hdcCommand.inputClick(x: x, y: y, serial: self.serial)
                    case .swipe(let x1, let y1, let x2, let y2, let durationMs):
                        try await self.hdcCommand.inputSwipe(x1: x1, y1: y1, x2: x2, y2: y2, speed: durationMs, serial: self.serial)
                    case .touchDown(let x, let y):
                        try await self.hdcCommand.uinputTouchDown(x: x, y: y, serial: self.serial)
                    case .touchUp(let x, let y):
                        try await self.hdcCommand.uinputTouchUp(x: x, y: y, serial: self.serial)
                    case .touchMove(let x1, let y1, let x2, let y2, let durationMs):
                        try await self.hdcCommand.uinputTouchMove(x1: x1, y1: y1, x2: x2, y2: y2, durationMs: durationMs, serial: self.serial)
                    case .uinputKey(let keyCode):
                        try await self.hdcCommand.uinputKeyEvent(keyCode, serial: self.serial)
                    case .uitestKey(let name):
                        if name == "Home" {
                            try await self.hdcCommand.uitestHome(serial: self.serial)
                        } else if name == "Back" {
                            try await self.hdcCommand.uitestBack(serial: self.serial)
                        }
                    }
                } catch {
                    Log.input.error("Input action failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func executeWithAgentIfAvailable(_ action: InputAction) async -> Bool {
        guard let agentClient, agentClient.isConnected else { return false }

        switch action {
        case .click(let x, let y):
            agentClient.sendTouch(.touchDown, x: normalizedX(x), y: normalizedY(y))
            try? await Task.sleep(nanoseconds: 15_000_000)
            agentClient.sendTouch(.touchUp, x: normalizedX(x), y: normalizedY(y))
        case .swipe(let x1, let y1, let x2, let y2, let durationMs):
            agentClient.sendTouch(.touchDown, x: normalizedX(x1), y: normalizedY(y1))
            let half = min(durationMs / 2, 200)
            try? await Task.sleep(nanoseconds: UInt64(half) * 1_000_000)
            agentClient.sendTouch(.touchMove, x: normalizedX(x2), y: normalizedY(y2))
            try? await Task.sleep(nanoseconds: UInt64(min(half, 200)) * 1_000_000)
            agentClient.sendTouch(.touchUp, x: normalizedX(x2), y: normalizedY(y2))
        case .touchDown(let x, let y):
            agentClient.sendTouch(.touchDown, x: normalizedX(x), y: normalizedY(y))
        case .touchUp(let x, let y):
            agentClient.sendTouch(.touchUp, x: normalizedX(x), y: normalizedY(y))
        case .touchMove(_, _, let x2, let y2, _):
            agentClient.sendTouch(.touchMove, x: normalizedX(x2), y: normalizedY(y2))
        case .uinputKey(let keyCode):
            guard (0...65_535).contains(keyCode) else { return false }
            agentClient.sendKey(UInt16(keyCode))
        case .uitestKey:
            return false
        }
        return true
    }

    private func normalizedX(_ x: Int) -> UInt16 {
        normalized(value: x, maxValue: screenWidth)
    }

    private func normalizedY(_ y: Int) -> UInt16 {
        normalized(value: y, maxValue: screenHeight)
    }

    private func normalized(value: Int, maxValue: Int) -> UInt16 {
        guard maxValue > 1 else { return 0 }
        let clamped = max(0, min(maxValue - 1, value))
        let normalized = Double(clamped) / Double(maxValue - 1) * Double(UInt16.max)
        return UInt16(max(0, min(Int(UInt16.max), Int(normalized.rounded()))))
    }

    private func mapToDevice(windowPoint: CGPoint, windowSize: CGSize) -> (x: Int, y: Int)? {
        guard windowSize.width > 0, windowSize.height > 0, screenWidth > 0, screenHeight > 0 else { return nil }

        let deviceAspect = CGFloat(screenWidth) / CGFloat(screenHeight)
        let windowAspect = windowSize.width / windowSize.height

        let videoRect: CGRect
        if deviceAspect > windowAspect {
            let vw = windowSize.width
            let vh = vw / deviceAspect
            videoRect = CGRect(x: 0, y: (windowSize.height - vh) / 2, width: vw, height: vh)
        } else {
            let vh = windowSize.height
            let vw = vh * deviceAspect
            videoRect = CGRect(x: (windowSize.width - vw) / 2, y: 0, width: vw, height: vh)
        }

        guard videoRect.contains(windowPoint) else { return nil }

        let nx = max(0, min(1, (windowPoint.x - videoRect.minX) / videoRect.width))
        let ny = max(0, min(1, (windowPoint.y - videoRect.minY) / videoRect.height))

        return (x: Int(nx * CGFloat(screenWidth)), y: Int(ny * CGFloat(screenHeight)))
    }
}
