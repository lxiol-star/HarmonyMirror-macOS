import SwiftUI

struct DeviceCard: View {
    let group: DeviceGroup
    let onConnect: (HarmonyDevice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    if !infoLine.isEmpty {
                        Text(infoLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            HStack(spacing: 8) {
                // USB button
                if let usb = group.usbDevice {
                    connectionButton(
                        label: "USB",
                        systemImage: "cable.connector",
                        isActive: true,
                        device: usb
                    )
                } else {
                    connectionButton(
                        label: "USB",
                        systemImage: "cable.connector",
                        isActive: false,
                        device: nil
                    )
                }

                // WiFi button
                if let wifi = group.wifiDevice {
                    connectionButton(
                        label: "Wi-Fi",
                        systemImage: "wifi",
                        isActive: true,
                        device: wifi
                    )
                } else {
                    connectionButton(
                        label: "Wi-Fi",
                        systemImage: "wifi",
                        isActive: false,
                        device: nil
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.background)
        .cornerRadius(8)
        .shadow(radius: 1)
    }

    private func connectionButton(label: String, systemImage: String, isActive: Bool, device: HarmonyDevice?) -> some View {
        Button {
            if let device {
                onConnect(device)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.caption)
                Text(label)
                    .font(.caption)
                if isActive {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!isActive)
        .help(isActive ? "通过 \(label) 连接 \(group.displayName)" : "未检测到 \(label) 连接")
    }

    private var iconName: String {
        switch group.formFactor {
        case .tablet: return "ipad"
        case .phone:  return "iphone"
        case .unknown: return "display"
        }
    }

    private var infoLine: String {
        var parts: [String] = []
        let hw = group.hardwareModel
        if !hw.isEmpty {
            parts.append(hw)
        } else {
            // Show truncated identifier for debugging
            let id = group.id
            if id.contains(":") {
                parts.append(id)
            } else {
                parts.append(String(id.suffix(8)))
            }
        }
        if !group.model.isEmpty, group.model != hw {
            parts.append(group.model)
        }
        if let res = group.resolutionLabel { parts.append(res) }
        if let orient = group.orientationLabel { parts.append(orient) }
        return parts.joined(separator: " · ")
    }
}
