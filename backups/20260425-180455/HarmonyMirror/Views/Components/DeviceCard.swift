import SwiftUI

struct DeviceCard: View {
    let device: HarmonyDevice
    let onConnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(device.isWireless ? .green : .blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("HarmonyOS NEXT")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(connectTitle, action: onConnect)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("连接 \(device.displayName)")
        }
        .padding(10)
        .background(.background)
        .cornerRadius(8)
        .shadow(radius: 1)
    }

    private var iconName: String {
        switch device.formFactor {
        case .tablet:
            return "ipad"
        case .phone:
            return "iphone"
        case .unknown:
            return device.isWireless ? "antenna.radiowaves.left.and.right" : "display"
        }
    }

    private var connectTitle: String {
        switch device.formFactor {
        case .tablet:
            return "连接平板"
        case .phone:
            return "连接手机"
        case .unknown:
            return "连接"
        }
    }

    private var subtitle: String {
        var parts = [device.connectionKind.rawValue, device.serial]
        if let resolution = device.resolutionLabel {
            parts.append(resolution)
        }
        if let orientation = device.orientationLabel {
            parts.append(orientation)
        }
        return parts.joined(separator: " · ")
    }
}
