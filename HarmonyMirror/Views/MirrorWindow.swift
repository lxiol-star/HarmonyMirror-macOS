import SwiftUI
import AVFoundation

struct MirrorWindow: View {
    @ObservedObject var service: MirrorService
    @State private var dragStart: CGPoint?
    @State private var isDragging = false
    @State private var isDraggingFromTopEdge = false
    @State private var hasTriggeredSystemPullDown = false
    @State private var window: NSWindow?
    @State private var isFullScreen = false
    @State private var lastAutoResizeSize: CGSize?
    @State private var manualVideoScale: CGFloat?
    @State private var pinchSessionActive = false
    @State private var pinchFinger1: CGPoint = .zero
    @State private var pinchFinger2: CGPoint = .zero
    @State private var lastViewSize: CGSize = .zero
    private let dragThreshold: CGFloat = 5
    private let systemPullDownThreshold: CGFloat = 32
    private let longPressThreshold: TimeInterval = 0.15
    private let toolbarHeight: CGFloat = 36
    private let statusHeight: CGFloat = 26
    private let windowMargin: CGFloat = 24
    private enum ResizeAnchor {
        case top
        case bottom
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(service.windowTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if service.screenWidth > 0, service.screenHeight > 0 {
                    Text(service.orientationLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    toolbarButton("返回", systemImage: "chevron.left") {
                        service.inputInjector?.back()
                    }
                    toolbarButton("主页", systemImage: "house") {
                        service.inputInjector?.home()
                    }
                    toolbarButton("唤醒屏幕", systemImage: "sun.max") {
                        service.inputInjector?.wake()
                    }
                    toolbarButton("通知中心", systemImage: "bell") {
                        service.inputInjector?.statusBarPullDown(fromLeft: true)
                    }
                    toolbarButton("控制中心", systemImage: "slider.horizontal.3") {
                        service.inputInjector?.statusBarPullDown(fromLeft: false)
                    }
                    toolbarButton("断开", systemImage: "xmark.circle") {
                        service.stopMirroring()
                    }
                }
                .controlSize(.small)
                .layoutPriority(1)
            }
            .padding(.horizontal, 12)
            .frame(height: toolbarHeight)
            .background(.bar)

            GeometryReader { geo in
                let size = videoSize(for: geo.size)
                ZStack {
                    VideoPlayerView(
                        onLayerReady: { layer in
                            service.videoDisplayLayer = layer
                        },
                        onMouseDown: { point, size in
                            dragStart = point
                            isDragging = false
                            lastViewSize = size
                            isDraggingFromTopEdge = service.inputInjector?.isInStatusBarZone(
                                windowPoint: point, windowSize: size
                            ) ?? false
                            hasTriggeredSystemPullDown = false
                        },
                        onMouseUp: { point, size in
                            guard let start = dragStart else {
                                dragStart = nil; return
                            }

                            let dist = hypot(point.x - start.x, point.y - start.y)

                            if hasTriggeredSystemPullDown {
                                // no-op
                            } else if isDragging {
                                // Drag → single swipe from start to end (uitest)
                                service.inputInjector?.drag(
                                    from: start, to: point, windowSize: size
                                )
                            } else if dist < dragThreshold {
                                // Tap → click (uitest)
                                service.inputInjector?.click(windowPoint: point, windowSize: size)
                            }

                            dragStart = nil
                            isDragging = false
                            isDraggingFromTopEdge = false
                            hasTriggeredSystemPullDown = false
                        },
                        onMouseDragged: { point, size in
                            guard let start = dragStart else { return }
                            let dist = hypot(point.x - start.x, point.y - start.y)
                            if isDraggingFromTopEdge,
                               !hasTriggeredSystemPullDown,
                               point.y - start.y >= systemPullDownThreshold {
                                hasTriggeredSystemPullDown = true
                                isDragging = false
                                service.inputInjector?.cancelDrag()
                                service.inputInjector?.statusBarPullDown(fromLeft: start.x < size.width / 2)
                                return
                            }
                            guard !hasTriggeredSystemPullDown else { return }

                            if dist >= dragThreshold && !isDragging {
                                isDragging = true
                            }
                            // No touchMove calls — drag accumulated, dispatched as single swipe on mouseUp
                        },
                        onRightClick: {
                            service.inputInjector?.back()
                        },
                        onScrollBegin: { point, size in
                            service.inputInjector?.scrollBegin(windowPoint: point, windowSize: size)
                        },
                        onScrollDelta: { deltaX, deltaY in
                            service.inputInjector?.scrollDelta(deltaX: deltaX, deltaY: deltaY)
                        },
                        onScrollEnd: {
                            service.inputInjector?.scrollEnd()
                        },
                        onScrollCancel: {
                            service.inputInjector?.scrollCancel()
                        },
                        onMagnifyPhase: { magnification, phase in
                            switch phase {
                            case .began:
                                let center = CGPoint(x: lastViewSize.width / 2, y: lastViewSize.height / 2)
                                let baseDist = lastViewSize.width * 0.1
                                pinchFinger1 = CGPoint(x: center.x - baseDist, y: center.y)
                                pinchFinger2 = CGPoint(x: center.x + baseDist, y: center.y)
                                pinchSessionActive = true
                                service.inputInjector?.multiTouchBegan(windowPoint: pinchFinger1, windowSize: lastViewSize, slot: 0)
                                service.inputInjector?.multiTouchBegan(windowPoint: pinchFinger2, windowSize: lastViewSize, slot: 1)
                            case .changed:
                                guard pinchSessionActive else { return }
                                let center = CGPoint(x: lastViewSize.width / 2, y: lastViewSize.height / 2)
                                let baseDist = lastViewSize.width * 0.1
                                let dist = baseDist * max(0.1, 1 + magnification * 3)
                                pinchFinger1 = CGPoint(x: center.x - dist, y: center.y)
                                pinchFinger2 = CGPoint(x: center.x + dist, y: center.y)
                                service.inputInjector?.multiTouchMoved(windowPoint: pinchFinger1, windowSize: lastViewSize, slot: 0)
                                service.inputInjector?.multiTouchMoved(windowPoint: pinchFinger2, windowSize: lastViewSize, slot: 1)
                            case .ended, .cancelled:
                                guard pinchSessionActive else { return }
                                pinchSessionActive = false
                                service.inputInjector?.multiTouchEnded(slot: 0)
                                service.inputInjector?.multiTouchEnded(slot: 1)
                            default:
                                break
                            }
                        },
                        onTouchBegan: { point, size, slot in
                            service.inputInjector?.multiTouchBegan(windowPoint: point, windowSize: size, slot: slot)
                        },
                        onTouchMoved: { point, size, slot in
                            service.inputInjector?.multiTouchMoved(windowPoint: point, windowSize: size, slot: slot)
                        },
                        onTouchEnded: { _, _, slot in
                            service.inputInjector?.multiTouchEnded(slot: slot)
                        }
                    )
                    .frame(width: size.width, height: size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                    // Loading overlay — must not block touch events to underlying VideoPlayerView
                    if showOverlay {
                        VideoLoadingOverlay(
                            state: service.state,
                            fps: service.fps,
                            deviceName: service.currentDevice?.displayName ?? ""
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                    }
                }
            }
            .background(Color.black)

            ConnectionStatusBar(
                fps: service.fps,
                width: service.screenWidth,
                height: service.screenHeight,
                onZoomOut: {
                    resizeWindow(scale: currentVideoScale() * 0.9)
                },
                onZoomIn: {
                    resizeWindow(scale: currentVideoScale() * 1.1)
                },
                onFit: {
                    manualVideoScale = nil
                    resizeWindowIfNeeded(force: true, anchor: .bottom)
                },
                onFill: {
                    resizeWindow(scale: maxAvailableVideoScale())
                }
            )
            .frame(height: statusHeight)
        }
        .frame(
            minWidth: service.preferredMinWindowSize.width,
            minHeight: service.preferredMinWindowSize.height
        )
        .background(WindowAccessor { window in
            self.window = window
            resizeWindowIfNeeded()
        } onEnterFullScreen: { window in
            isFullScreen = true
            pinchSessionActive = false
            // Don't reset input state - it may cause input to stop working
            // Just cancel any active pinch gesture
            manualVideoScale = nil
            lastAutoResizeSize = nil
            // Delay resize to allow fullscreen animation to complete
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                resizeWindowIfNeeded(force: true, anchor: .top)
            }
            window.collectionBehavior.insert([.fullScreenPrimary, .fullScreenAllowsTiling])
        } onExitFullScreen: { window in
            isFullScreen = false
            pinchSessionActive = false
            // Don't reset input state - it may cause input to stop working
            lastAutoResizeSize = nil
            // Delay resize to allow fullscreen animation to complete
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                resizeWindowIfNeeded(force: true, anchor: .top)
            }
            window.collectionBehavior.insert([.fullScreenPrimary, .fullScreenAllowsTiling])
        })
        .onChange(of: screenSizeKey) {
            lastAutoResizeSize = nil
            manualVideoScale = nil
            resizeWindowIfNeeded(force: true)
        }
    }

    private func toolbarButton(_ help: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(help)
    }

    private func targetContentSize(for window: NSWindow?) -> CGSize {
        guard service.screenWidth > 0, service.screenHeight > 0 else {
            return service.preferredMinWindowSize
        }
        let source = sourceVideoSize()
        let limits = videoLimits(for: window)
        let scale: CGFloat
        if let manualVideoScale {
            scale = clamp(manualVideoScale, minVideoScale(), maxAvailableVideoScale())
        } else {
            let maxWidth = min(limits.maxWidth, source.width >= source.height ? 1040 : 560)
            let maxHeight = min(limits.maxHeight, source.width >= source.height ? 640 : limits.maxHeight)
            scale = min(maxWidth / source.width, maxHeight / source.height, 1)
        }
        let video = videoSize(forScale: scale)
        return CGSize(width: video.width, height: toolbarHeight + video.height + statusHeight)
    }

    private func sourceVideoSize() -> CGSize {
        CGSize(width: max(1, service.screenWidth), height: max(1, service.screenHeight))
    }

    private func videoSize(forScale scale: CGFloat) -> CGSize {
        let source = sourceVideoSize()
        let boundedScale = clamp(scale, minVideoScale(), maxAvailableVideoScale())
        return CGSize(
            width: floor(source.width * boundedScale),
            height: floor(source.height * boundedScale)
        )
    }

    private func videoLimits(for window: NSWindow?) -> (maxWidth: CGFloat, maxHeight: CGFloat) {
        let baseFrame: CGRect
        if isFullScreen {
            baseFrame = window?.screen?.frame ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        } else {
            baseFrame = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        }
        let chromeHeight = max(0, (window?.frame.height ?? 0) - (window?.contentLayoutRect.height ?? 0))
        let maxContentHeight = max(
            service.preferredMinWindowSize.height,
            baseFrame.height - chromeHeight - windowMargin
        )
        return (
            maxWidth: max(320, baseFrame.width * 0.96),
            maxHeight: max(280, maxContentHeight - toolbarHeight - statusHeight)
        )
    }

    private func minVideoScale() -> CGFloat {
        let source = sourceVideoSize()
        let minSize = service.preferredMinWindowSize
        let minVideoWidth = minSize.width
        let minVideoHeight = max(220, minSize.height - toolbarHeight - statusHeight)
        return max(minVideoWidth / source.width, minVideoHeight / source.height)
    }

    private func maxAvailableVideoScale() -> CGFloat {
        let source = sourceVideoSize()
        let limits = videoLimits(for: window)
        return max(minVideoScale(), min(limits.maxWidth / source.width, limits.maxHeight / source.height))
    }

    private func currentVideoScale() -> CGFloat {
        guard service.screenWidth > 0, service.screenHeight > 0 else { return 1 }
        if let manualVideoScale {
            return clamp(manualVideoScale, minVideoScale(), maxAvailableVideoScale())
        }
        guard let window else {
            let target = targetContentSize(for: nil)
            return max(minVideoScale(), (target.height - toolbarHeight - statusHeight) / sourceVideoSize().height)
        }
        let content = window.contentLayoutRect.size
        let videoHeight = max(1, content.height - toolbarHeight - statusHeight)
        return clamp(videoHeight / sourceVideoSize().height, minVideoScale(), maxAvailableVideoScale())
    }

    private func videoSize(for container: CGSize) -> CGSize {
        guard service.screenWidth > 0, service.screenHeight > 0 else { return container }
        let aspect = CGFloat(service.screenWidth) / CGFloat(service.screenHeight)
        let containerAspect = container.width / container.height
        if aspect > containerAspect {
            let width = container.width
            return CGSize(width: width, height: width / aspect)
        } else {
            let height = container.height
            return CGSize(width: height * aspect, height: height)
        }
    }

    private var showOverlay: Bool {
        switch service.state {
        case .connecting:
            return true
        case .connected:
            return service.fps == 0
        case .disconnected:
            return true
        default:
            return false
        }
    }

    private var screenSizeKey: String {
        "\(service.screenWidth)x\(service.screenHeight)"
    }

    private func resizeWindow(scale: CGFloat) {
        manualVideoScale = clamp(scale, minVideoScale(), maxAvailableVideoScale())
        resizeWindowIfNeeded(force: true, anchor: .bottom)
    }

    private func resizeWindowIfNeeded(force: Bool = false, anchor: ResizeAnchor = .top) {
        guard let window, service.screenWidth > 0, service.screenHeight > 0 else { return }
        let target = targetContentSize(for: window)
        let current = window.contentLayoutRect.size
        configureResizeConstraints(for: window, target: target)

        if isFullScreen {
            lastAutoResizeSize = target
            return
        }

        guard force || abs(current.width - target.width) > 8 || abs(current.height - target.height) > 8 else {
            lastAutoResizeSize = current
            return
        }

        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: target))
        frame.origin.x = window.frame.origin.x
        switch anchor {
        case .top:
            frame.origin.y = window.frame.maxY - frame.height
        case .bottom:
            frame.origin.y = window.frame.minY
        }

        if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }

        window.setFrame(frame, display: true, animate: true)
        lastAutoResizeSize = target
    }

    private func configureResizeConstraints(for window: NSWindow, target: CGSize) {
        window.minSize = service.preferredMinWindowSize
        // Don't set aspect ratio in fullscreen mode - it conflicts with fullscreen constraints
        if !isFullScreen {
            window.contentAspectRatio = target
        }
        window.collectionBehavior.insert([.fullScreenPrimary, .fullScreenAllowsTiling])
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onWindowAvailable: (NSWindow) -> Void
    let onEnterFullScreen: (NSWindow) -> Void
    let onExitFullScreen: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEnterFullScreen: onEnterFullScreen, onExitFullScreen: onExitFullScreen)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attachIfNeeded(to: view.window, onWindowAvailable: onWindowAvailable)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attachIfNeeded(to: nsView.window, onWindowAvailable: onWindowAvailable)
        }
    }

    final class Coordinator {
        private let onEnterFullScreen: (NSWindow) -> Void
        private let onExitFullScreen: (NSWindow) -> Void
        private weak var observedWindow: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(onEnterFullScreen: @escaping (NSWindow) -> Void, onExitFullScreen: @escaping (NSWindow) -> Void) {
            self.onEnterFullScreen = onEnterFullScreen
            self.onExitFullScreen = onExitFullScreen
        }

        deinit {
            removeObservers()
        }

        func attachIfNeeded(to window: NSWindow?, onWindowAvailable: (NSWindow) -> Void) {
            guard let window else { return }
            guard observedWindow !== window else { return }

            removeObservers()
            observedWindow = window
            onWindowAvailable(window)
            window.collectionBehavior.insert([.fullScreenPrimary, .fullScreenAllowsTiling])

            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                // Ensure callback runs on main thread
                DispatchQueue.main.async {
                    self?.onEnterFullScreen(window)
                }
            })
            observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                // Ensure callback runs on main thread
                DispatchQueue.main.async {
                    self?.onExitFullScreen(window)
                }
            })
        }

        private func removeObservers() {
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers.removeAll()
        }
    }
}

private struct VideoLoadingOverlay: View {
    let state: MirrorState
    let fps: Int
    let deviceName: String

    var body: some View {
        VStack(spacing: 16) {
            switch state {
            case .connecting:
                ProgressView()
                    .controlSize(.large)
                Text("正在连接\(deviceName.isEmpty ? "设备" : deviceName)...")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("请稍候，首次连接可能需要数秒")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            case .connected:
                ProgressView()
                    .controlSize(.large)
                Text("正在接收视频流...")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("等待设备端画面数据")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            case .disconnected(let msg):
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.7))
                Text("连接已断开")
                    .font(.headline)
                    .foregroundStyle(.white)
                if let msg, !msg.isEmpty {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.75))
    }
}
