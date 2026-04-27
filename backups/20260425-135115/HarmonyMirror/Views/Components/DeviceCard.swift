import SwiftUI

struct DeviceCard: View {
    let device: HarmonyDevice
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.title2)
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.serial)
                    .font(.headline)
                Text("HarmonyOS NEXT")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("连接", action: onConnect)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(10)
        .background(.background)
        .cornerRadius(8)
        .shadow(radius: 1)
    }
}
