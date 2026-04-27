import SwiftUI

struct ConnectionStatusBar: View {
    let fps: Int
    let width: Int
    let height: Int
    let onZoomOut: () -> Void
    let onZoomIn: () -> Void
    let onFit: () -> Void
    let onFill: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text("\(fps) fps")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "speedometer")
            }
            if width > 0 && height > 0 {
                Label {
                    Text("\(width)×\(height)")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "rectangle.on.rectangle")
                }
            }
            Spacer()
            HStack(spacing: 4) {
                controlButton("缩小", systemImage: "minus.magnifyingglass", action: onZoomOut)
                controlButton("放大", systemImage: "plus.magnifyingglass", action: onZoomIn)
                controlButton("适配窗口", systemImage: "arrow.down.right.and.arrow.up.left", action: onFit)
                controlButton("占满屏幕", systemImage: "arrow.up.left.and.arrow.down.right", action: onFill)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private func controlButton(_ help: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 16)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
