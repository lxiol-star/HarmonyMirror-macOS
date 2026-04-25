import SwiftUI
import AppKit

struct ScreenImageView: NSViewRepresentable {
    let image: NSImage?
    var onMouseDown: ((CGPoint, CGSize) -> Void)?
    var onMouseUp: ((CGPoint, CGSize) -> Void)?
    var onMouseDragged: ((CGPoint, CGSize) -> Void)?
    var onRightClick: (() -> Void)?

    func makeNSView(context: Context) -> ScreenNSView {
        let view = ScreenNSView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.onMouseDown = onMouseDown
        view.onMouseUp = onMouseUp
        view.onMouseDragged = onMouseDragged
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: ScreenNSView, context: Context) {
        nsView.image = image
        nsView.onMouseDown = onMouseDown
        nsView.onMouseUp = onMouseUp
        nsView.onMouseDragged = onMouseDragged
        nsView.onRightClick = onRightClick
    }
}

final class ScreenNSView: NSImageView {
    var onMouseDown: ((CGPoint, CGSize) -> Void)?
    var onMouseUp: ((CGPoint, CGSize) -> Void)?
    var onMouseDragged: ((CGPoint, CGSize) -> Void)?
    var onRightClick: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: -1, height: -1) }

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
}
