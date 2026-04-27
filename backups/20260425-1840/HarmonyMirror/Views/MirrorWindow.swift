import SwiftUI
import AVFoundation

struct MirrorWindow: View {
    @ObservedObject var service: MirrorService
    @State private var dragStart: CGPoint?
    @State private var dragStartTime: Date?
    @State private var isDragging = false
    @State private var hasSentTouchDown = false
    @State private var pendingTouchDownTask: Task<Void, Never>?
    @State private var window: NSWindow?
    private let dragThreshold: CGFloat = 5
    private let longPressThreshold: TimeInterval = 0.15
    private let toolbarHeight: CGFloat = 44
    private let statusHeight: CGFloat = 34
    private let titleBarAllowance: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(service.windowTitle)
                    .font(.headline)
                    .lineLimit(1)
                if service.screenWidth > 0, service.screenHeight > 0 {
                    Text(service.orientationLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Back") {
                    service.inputInjector?.back()
                }
                .controlSize(.small)
                Button("Home") {
                    service.inputInjector?.home()
                }
                .controlSize(.small)
                Button("断开") {
                    service.stopMirroring()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .frame(height: toolbarHeight)
            .background(.bar)

            VideoPlayerView(
                onLayerReady: { layer in
                    service.videoDisplayLayer = layer
                },
                onMouseDown: { point, size in
                    dragStart = point
                    dragStartTime = Date()
                    isDragging = false
                    hasSentTouchDown = false

                    pendingTouchDownTask = Task {
                        try? await Task.sleep(nanoseconds: UInt64(longPressThreshold * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        hasSentTouchDown = true
                        service.inputInjector?.touchDown(windowPoint: point, windowSize: size)
                    }
                },
                onMouseUp: { point, size in
                    pendingTouchDownTask?.cancel()
                    pendingTouchDownTask = nil

                    guard let start = dragStart, let startTime = dragStartTime else {
                        dragStart = nil
                        dragStartTime = nil
                        return
                    }

                    let dist = hypot(point.x - start.x, point.y - start.y)
                    let pressDuration = Date().timeIntervalSince(startTime)

                    if isDragging {
                        if hasSentTouchDown {
                            service.inputInjector?.touchUp(windowPoint: point, windowSize: size)
                        }
                    } else if dist < dragThreshold {
                        if pressDuration < longPressThreshold {
                            // Short tap -> click (prevents long-press misdetection)
                            service.inputInjector?.click(windowPoint: point, windowSize: size)
                        } else if hasSentTouchDown {
                            // Long press that already sent touchDown -> touchUp
                            service.inputInjector?.touchUp(windowPoint: point, windowSize: size)
                        } else {
                            // Fallback: send touchDown + touchUp
                            service.inputInjector?.touchDown(windowPoint: point, windowSize: size)
                            service.inputInjector?.touchUp(windowPoint: point, windowSize: size)
                        }
                    }

                    dragStart = nil
                    dragStartTime = nil
                    isDragging = false
                    hasSentTouchDown = false
                },
                onMouseDragged: { point, size in
                    guard let start = dragStart else { return }
                    let dist = hypot(point.x - start.x, point.y - start.y)

                    if dist >= dragThreshold && !isDragging {
                        isDragging = true
                        pendingTouchDownTask?.cancel()
                        pendingTouchDownTask = nil

                        if !hasSentTouchDown {
                            hasSentTouchDown = true
                            service.inputInjector?.touchDown(windowPoint: start, windowSize: size)
                        }
                    }

                    if isDragging && hasSentTouchDown {
                        service.inputInjector?.touchMove(windowPoint: point, windowSize: size)
                    }
                },
                onRightClick: {
                    service.inputInjector?.back()
                }
            )
            .frame(width: targetVideoSize.width, height: targetVideoSize.height)
            .background(Color.black)

            ConnectionStatusBar(
                fps: service.fps,
                width: service.screenWidth,
                height: service.screenHeight
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
        })
        .onChange(of: service.screenWidth) { _, _ in
            resizeWindowIfNeeded()
        }
        .onChange(of: service.screenHeight) { _, _ in
            resizeWindowIfNeeded()
        }
    }

    private var targetVideoSize: CGSize {
        guard service.screenWidth > 0, service.screenHeight > 0 else {
            return service.preferredMinWindowSize
        }

        let source = CGSize(width: service.screenWidth, height: service.screenHeight)
        let visibleFrame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let maxWidth = min(visibleFrame.width * 0.92, source.width >= source.height ? 980 : 560)
        let availableVideoHeight = visibleFrame.height - titleBarAllowance - toolbarHeight - statusHeight - 40
        let maxHeight = min(availableVideoHeight, source.width >= source.height ? 620 : 720)
        let scale = min(maxWidth / source.width, maxHeight / source.height, 1)
        return CGSize(
            width: max(service.preferredMinWindowSize.width, floor(source.width * scale)),
            height: max(280, floor(source.height * scale))
        )
    }

    private var targetContentSize: CGSize {
        CGSize(
            width: targetVideoSize.width,
            height: toolbarHeight + targetVideoSize.height + statusHeight
        )
    }

    private func resizeWindowIfNeeded() {
        guard let window, service.screenWidth > 0, service.screenHeight > 0 else { return }
        let target = targetContentSize
        let current = window.contentLayoutRect.size
        guard abs(current.width - target.width) > 8 || abs(current.height - target.height) > 8 else { return }

        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: target))
        frame.origin.x = window.frame.origin.x
        frame.origin.y = window.frame.maxY - frame.height

        if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }

        window.setFrame(frame, display: true, animate: true)
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onWindowAvailable: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindowAvailable(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindowAvailable(window)
            }
        }
    }
}
