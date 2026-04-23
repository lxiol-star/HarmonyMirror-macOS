import Foundation
import AppKit

struct HarmonyDevice: Identifiable, Hashable {
    let id: String
    let serial: String
    var name: String = "HarmonyOS Device"
    var screenWidth: Int = 0
    var screenHeight: Int = 0
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
