import SwiftUI
import AVFoundation

struct VideoPlayerView: NSViewRepresentable {
    var onLayerReady: ((AVSampleBufferDisplayLayer) -> Void)?
    var onMouseDown: ((CGPoint, CGSize) -> Void)?
    var onMouseUp: ((CGPoint, CGSize) -> Void)?
    var onMouseDragged: ((CGPoint, CGSize) -> Void)?
    var onRightClick: (() -> Void)?
    var onScrollBegin: ((CGPoint, CGSize) -> Void)?
    var onScrollDelta: ((CGFloat, CGFloat) -> Void)?
    var onScrollEnd: (() -> Void)?
    var onScrollCancel: (() -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    var onMagnifyPhase: ((CGFloat, NSEvent.Phase) -> Void)?
    /// Multi-touch callbacks (slot-based)
    var onTouchBegan: ((CGPoint, CGSize, UInt8) -> Void)?
    var onTouchMoved: ((CGPoint, CGSize, UInt8) -> Void)?
    var onTouchEnded: ((CGPoint, CGSize, UInt8) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        let videoLayer = AVSampleBufferDisplayLayer()
        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.frame = container.bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        container.layer?.addSublayer(videoLayer)
        context.coordinator.videoLayer = videoLayer

        // Notify the parent that the layer is ready
        DispatchQueue.main.async {
            self.onLayerReady?(videoLayer)
        }

        let overlay = TouchOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onMouseDown = onMouseDown
        overlay.onMouseUp = onMouseUp
        overlay.onMouseDragged = onMouseDragged
        overlay.onRightClick = onRightClick
        overlay.onScrollBegin = onScrollBegin
        overlay.onScrollDelta = onScrollDelta
        overlay.onScrollEnd = onScrollEnd
        overlay.onScrollCancel = onScrollCancel
        overlay.onMagnify = onMagnify
        overlay.onMagnifyPhase = onMagnifyPhase
        overlay.onTouchBegan = onTouchBegan
        overlay.onTouchMoved = onTouchMoved
        overlay.onTouchEnded = onTouchEnded
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.overlay = overlay

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let overlay = context.coordinator.overlay
        overlay?.onMouseDown = onMouseDown
        overlay?.onMouseUp = onMouseUp
        overlay?.onMouseDragged = onMouseDragged
        overlay?.onRightClick = onRightClick
        overlay?.onScrollBegin = onScrollBegin
        overlay?.onScrollDelta = onScrollDelta
        overlay?.onScrollEnd = onScrollEnd
        overlay?.onScrollCancel = onScrollCancel
        overlay?.onMagnify = onMagnify
        overlay?.onMagnifyPhase = onMagnifyPhase
        overlay?.onTouchBegan = onTouchBegan
        overlay?.onTouchMoved = onTouchMoved
        overlay?.onTouchEnded = onTouchEnded
    }

    class Coordinator {
        var videoLayer: AVSampleBufferDisplayLayer?
        var overlay: TouchOverlayView?
        init(_ parent: VideoPlayerView) {}
    }
}

final class TouchOverlayView: NSView {
    var onMouseDown: ((CGPoint, CGSize) -> Void)?
    var onMouseUp: ((CGPoint, CGSize) -> Void)?
    var onMouseDragged: ((CGPoint, CGSize) -> Void)?
    var onRightClick: (() -> Void)?
    var onScrollBegin: ((CGPoint, CGSize) -> Void)?
    var onScrollDelta: ((CGFloat, CGFloat) -> Void)?
    var onScrollEnd: (() -> Void)?
    var onScrollCancel: (() -> Void)?
    var onMagnify: ((CGFloat) -> Void)?
    var onMagnifyPhase: ((CGFloat, NSEvent.Phase) -> Void)?
    var onTouchBegan: ((CGPoint, CGSize, UInt8) -> Void)?
    var onTouchMoved: ((CGPoint, CGSize, UInt8) -> Void)?
    var onTouchEnded: ((CGPoint, CGSize, UInt8) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        allowedTouchTypes = [.direct, .indirect]
        needsLayout = true
        // Fullscreen transitions may temporarily detach the view from its window,
        // or the window may not be key yet when viewDidMoveToWindow fires.
        // Retry multiple times to ensure first responder status.
        ensureFirstResponder()
    }

    private func ensureFirstResponder() {
        guard let window = self.window else { return }

        // Try immediately
        if window.firstResponder != self {
            window.makeFirstResponder(self)
        }

        // Retry after a short delay if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder != self {
                window.makeFirstResponder(self)
            }
        }

        // Final retry after fullscreen animation completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let window = self.window else { return }
            if window.firstResponder != self {
                window.makeFirstResponder(self)
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    override func resignFirstResponder() -> Bool {
        return true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        allowedTouchTypes = [.direct, .indirect]
    }

    /// Tracks active finger count via NSTouch.
    /// NSTouch events arrive BEFORE mouse events, so we can use this
    /// to suppress mouseDown/Dragged/Up when 2+ fingers are active
    /// (those should be handled by scrollWheel or multi-touch instead).
    private var activeTouchCount = 0

    private func flipped(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func mouseDown(with event: NSEvent) {
        guard activeTouchCount < 2 else { return }
        onMouseDown?(flipped(event), bounds.size)
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeTouchCount < 2 else { return }
        onMouseDragged?(flipped(event), bounds.size)
    }

    override func mouseUp(with event: NSEvent) {
        guard activeTouchCount < 2 else { return }
        onMouseUp?(flipped(event), bounds.size)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard activeTouchCount < 2 else { return }
        onRightClick?()
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX * 10
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10

        switch event.phase {
        case .began:
            onScrollBegin?(flipped(event), bounds.size)
            onScrollDelta?(dx, dy)
        case .changed:
            onScrollDelta?(dx, dy)
        case .ended:
            onScrollDelta?(dx, dy)
            onScrollEnd?()
        case .cancelled:
            onScrollCancel?()
        default:
            // Momentum phase or no phase info: ignore (momentum should not scroll device)
            if event.phase.isEmpty && event.momentumPhase.isEmpty {
                // No phase info at all — fallback: send as delta
                onScrollDelta?(dx, dy)
            }
        }
    }

    override func magnify(with event: NSEvent) {
        if let onMagnifyPhase = onMagnifyPhase {
            onMagnifyPhase(event.magnification, event.phase)
        } else {
            onMagnify?(event.magnification)
        }
    }

    // MARK: - Multi-Touch (track count for mouse event suppression; forward 3+ finger gestures)

    override func touchesBegan(with event: NSEvent) {
        activeTouchCount += event.touches(matching: .began, in: nil).count
        let allTouches = event.touches(matching: .any, in: nil)
        guard allTouches.count >= 3 else { return }
        for touch in allTouches {
            let p = CGPoint(x: touch.normalizedPosition.x * bounds.width,
                            y: (1 - touch.normalizedPosition.y) * bounds.height)
            let slot = UInt8(abs(touch.identity.hash) % 10)
            onTouchBegan?(p, bounds.size, slot)
        }
    }

    override func touchesMoved(with event: NSEvent) {
        let allTouches = event.touches(matching: .any, in: nil)
        guard allTouches.count >= 3 else { return }
        for touch in allTouches {
            let p = CGPoint(x: touch.normalizedPosition.x * bounds.width,
                            y: (1 - touch.normalizedPosition.y) * bounds.height)
            let slot = UInt8(abs(touch.identity.hash) % 10)
            onTouchMoved?(p, bounds.size, slot)
        }
    }

    override func touchesEnded(with event: NSEvent) {
        activeTouchCount -= event.touches(matching: .ended, in: nil).count
        if activeTouchCount < 0 { activeTouchCount = 0 }
        let allTouches = event.touches(matching: .any, in: nil)
        guard allTouches.count >= 3 else { return }
        for touch in allTouches {
            let slot = UInt8(abs(touch.identity.hash) % 10)
            onTouchEnded?(.zero, .zero, slot)
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        activeTouchCount = 0
        let allTouches = event.touches(matching: .any, in: nil)
        guard allTouches.count >= 3 else { return }
        for touch in allTouches {
            let slot = UInt8(abs(touch.identity.hash) % 10)
            onTouchEnded?(.zero, .zero, slot)
        }
    }
}
