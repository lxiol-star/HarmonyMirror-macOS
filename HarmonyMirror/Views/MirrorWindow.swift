import SwiftUI

struct MirrorWindow: View {
    @ObservedObject var service: MirrorService
    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("HarmonyMirror")
                    .font(.headline)
                Spacer()
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

            ScreenImageView(
                image: service.currentFrame,
                onMouseDown: { point, size in
                    dragStart = point
                },
                onMouseUp: { point, size in
                    guard let start = dragStart else { return }
                    let dist = hypot(point.x - start.x, point.y - start.y)
                    if dist < 5 {
                        service.inputInjector?.click(windowPoint: point, windowSize: size)
                    } else {
                        service.inputInjector?.swipe(from: start, to: point, windowSize: size)
                    }
                    dragStart = nil
                },
                onRightClick: {
                    service.inputInjector?.back()
                }
            )
            .background(Color.black)

            ConnectionStatusBar(
                fps: service.fps,
                width: service.screenWidth,
                height: service.screenHeight
            )
        }
        .frame(minWidth: 300, minHeight: 500)
    }
}
