import SwiftUI
import AVFoundation

struct MirrorWindow: View {
    @ObservedObject var service: MirrorService
    @State private var dragStart: CGPoint?
    @State private var dragStartTime: Date?
    @State private var isDragging = false
    @State private var hasSentTouchDown = false
    @State private var pendingTouchDownTask: Task<Void, Never>?
    private let dragThreshold: CGFloat = 5
    private let longPressThreshold: TimeInterval = 0.15

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
            .padding(.vertical, 8)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            ConnectionStatusBar(
                fps: service.fps,
                width: service.screenWidth,
                height: service.screenHeight
            )
        }
        .frame(
            minWidth: service.preferredMinWindowSize.width,
            minHeight: service.preferredMinWindowSize.height
        )
    }
}
