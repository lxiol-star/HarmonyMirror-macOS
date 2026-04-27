import Foundation
import AppKit

struct HarmonyDevice: Identifiable, Hashable {
    enum ConnectionKind: String, Hashable {
        case usb = "USB"
        case tcp = "Wi-Fi"
        case lan = "LAN"
        case unknown = "Unknown"
    }

    enum FormFactor: String, Hashable {
        case phone = "手机"
        case tablet = "平板"
        case unknown = "设备"
    }

    let id: String
    let serial: String
    var name: String = "HarmonyOS Device"
    var screenWidth: Int = 0
    var screenHeight: Int = 0
    var connectionKind: ConnectionKind = .unknown
    var formFactor: FormFactor = .unknown
    var model: String = ""
    var endpoint: String?

    var displayName: String {
        if !model.isEmpty { return model }
        if !name.isEmpty && name != "HarmonyOS Device" { return name }
        return formFactor == .unknown ? "HarmonyOS Device" : "HarmonyOS \(formFactor.rawValue)"
    }

    var isWireless: Bool {
        connectionKind == .tcp || connectionKind == .lan || serial.contains(":")
    }

    var orientationLabel: String? {
        guard screenWidth > 0, screenHeight > 0 else { return nil }
        return screenWidth >= screenHeight ? "横屏" : "竖屏"
    }

    var resolutionLabel: String? {
        guard screenWidth > 0, screenHeight > 0 else { return nil }
        return "\(screenWidth)x\(screenHeight)"
    }

    static func inferFormFactor(model: String, serial: String, width: Int = 0, height: Int = 0) -> FormFactor {
        let lower = "\(model) \(serial)".lowercased()
        if lower.contains("pad") || lower.contains("tablet") || lower.contains("matepad") {
            return .tablet
        }
        if width > 0, height > 0 {
            let longSide = max(width, height)
            let shortSide = min(width, height)
            if shortSide >= 1200 || CGFloat(longSide) / CGFloat(shortSide) < 1.55 {
                return .tablet
            }
            return .phone
        }
        return .unknown
    }
}

struct HDCTarget: Hashable {
    let serial: String
    let transport: String
    let status: String
    let endpoint: String?

    var connectionKind: HarmonyDevice.ConnectionKind {
        switch transport.lowercased() {
        case "usb":
            return .usb
        case "tcp":
            return .tcp
        default:
            return serial.contains(":") ? .tcp : .unknown
        }
    }

    var isConnected: Bool {
        let lower = status.lowercased()
        return lower == "connected" || lower == "device" || lower == "online"
    }
}

struct DeviceProfile: Hashable {
    var model: String = ""
    var deviceType: String = ""
    var userName: String = ""

    var displayModel: String {
        if !userName.isEmpty { return userName }
        if !model.isEmpty { return model }
        return deviceType
    }

    var formFactor: HarmonyDevice.FormFactor {
        let lower = "\(model) \(deviceType)".lowercased()
        if lower.contains("pad") || lower.contains("tablet") {
            return .tablet
        }
        if lower.contains("phone") {
            return .phone
        }
        return .unknown
    }
}

enum MirrorState: Equatable {
    case idle
    case connecting
    case connected
    case disconnected(String?)

    static func == (lhs: MirrorState, rhs: MirrorState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.connecting, .connecting), (.connected, .connected):
            return true
        case (.disconnected, .disconnected):
            return true
        default:
            return false
        }
    }
}

enum MirrorError: Error {
    case hdcNotFound
    case deviceNotFound
    case captureError(String)
    case commandFailed(String)
}

extension MirrorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .hdcNotFound:
            return "未找到 hdc，请安装 DevEco Studio 或将 hdc 添加到 PATH"
        case .deviceNotFound:
            return "未找到设备"
        case .captureError(let message), .commandFailed(let message):
            return message
        }
    }
}
