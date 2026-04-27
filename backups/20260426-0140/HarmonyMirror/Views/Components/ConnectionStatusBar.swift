import SwiftUI

struct ConnectionStatusBar: View {
    let fps: Int
    let width: Int
    let height: Int

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
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
