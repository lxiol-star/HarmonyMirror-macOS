import SwiftUI

struct ConnectionStatusBar: View {
    let fps: Int
    let width: Int
    let height: Int

    var body: some View {
        HStack(spacing: 16) {
            Label("\(fps) fps", systemImage: "speedometer")
            if width > 0 && height > 0 {
                Label("\(width)×\(height)", systemImage: "rectangle.on.rectangle")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
