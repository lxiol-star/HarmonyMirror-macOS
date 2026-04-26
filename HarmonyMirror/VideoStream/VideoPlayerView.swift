import SwiftUI
import AVFoundation

struct VideoPlayerView: NSViewRepresentable {
    var onLayerReady: ((AVSampleBufferDisplayLayer) -> Void)?
    var onMouseDown: ((CGPoint, CGSize) -> Void)?
    var onMouseUp: ((CGPoint, CGSize) -> Void)?
    var onMouseDragged: ((CGPoint, CGSize) -> Void)?
    var onRightClick: (() -> Void)?
    var onScroll: ((CGPoint, CGSize, CGFloat, CGFloat) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?

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
        overlay.onScroll = onScroll
        overlay.onMagnify = onMagnify
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
        context.coordinator.overlay?.onMouseDown = onMouseDown
        context.coordinator.overlay?.onMouseUp = onMouseUp
        context.coordinator.overlay?.onMouseDragged = onMouseDragged
        context.coordinator.overlay?.onRightClick = onRightClick
        context.coordinator.overlay?.onScroll = onScroll
        context.coordinator.overlay?.onMagnify = onMagnify
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
    var onScroll: ((CGPoint, CGSize, CGFloat, CGFloat) -> Void)?
    var onMagnify: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private func flipped(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?(flipped(event), bounds.size)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseDragged?(flipped(event), bounds.size)
    }

    override func mouseUp(with event: NSEvent) {
        onMouseUp?(flipped(event), bounds.size)
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func scrollWheel(with event: NSEvent) {
        let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX * 10
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
        onScroll?(flipped(event), bounds.size, dx, dy)
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(event.magnification)
    }
}
