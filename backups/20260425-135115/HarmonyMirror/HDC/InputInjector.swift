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

        func enqueue(_ action: InputAction, executor: @escaping (InputAction) async -> Void) {
            // Deduplicate: remove older touchMove entries when a new one arrives
            if case .touchMove = action {
                queue.removeAll { if case .touchMove = $0 { return true } else { return false } }
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
    }

    private let inputQueue = InputQueue()
    private var isDragging = false
    private var lastDragPoint: CGPoint?
    private var currentDeviceTouchPoint: (x: Int, y: Int)?
    private var lastTouchMoveTime: Date = .distantPast
    private let touchMoveMinInterval: TimeInterval = 1.0 / 10.0  // throttle to ~10Hz to reduce hdc shell backlog

    init(hdcCommand: HDCCommand, serial: String) {
        self.hdcCommand = hdcCommand
        self.serial = serial
    }

    func click(windowPoint: CGPoint, windowSize: CGSize) {
        guard let dp = mapToDevice(windowPoint: windowPoint, windowSize: windowSize) else { return }
        enqueue(.click(x: dp.x, y: dp.y))
    }

    func swipe(from start: CGPoint, to end: CGPoint, windowSize: CGSize) {
        guard let sp = mapToDevice(windowPoint: start, windowSize: windowSize),
              let ep = mapToDevice(windowPoint: end, windowSize: windowSize) else { return }
        let distance = hypot(CGFloat(ep.x - sp.x), CGFloat(ep.y - sp.y))
        let durationMs = max(100, min(500, Int(distance / 2)))
        enqueue(.swipe(x1: sp.x, y1: sp.y, x2: ep.x, y2: ep.y, durationMs: durationMs))
    }

    func back() {
        enqueue(.uitestKey(name: "Back"))
    }

    func home() {
        enqueue(.uitestKey(name: "Home"))
    }

    // MARK: - Real-time touch events

    private var touchDownTime: Date?
    private let minPressDuration: TimeInterval = 0.05  // 50ms minimum press time for clicks

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

    private func enqueue(_ action: InputAction) {
        Task {
            await inputQueue.enqueue(action) { [weak self] action in
                guard let self else { return }
                do {
                    switch action {
                    case .click(let x, let y):
                        try await self.hdcCommand.uinputClick(x: x, y: y, serial: self.serial)
                    case .swipe(let x1, let y1, let x2, let y2, let durationMs):
                        try await self.hdcCommand.uinputSwipe(x1: x1, y1: y1, x2: x2, y2: y2, durationMs: durationMs, serial: self.serial)
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

        let nx = max(0, min(1, (windowPoint.x - videoRect.minX) / videoRect.width))
        let ny = max(0, min(1, (windowPoint.y - videoRect.minY) / videoRect.height))

        return (x: Int(nx * CGFloat(screenWidth)), y: Int(ny * CGFloat(screenHeight)))
    }
}
