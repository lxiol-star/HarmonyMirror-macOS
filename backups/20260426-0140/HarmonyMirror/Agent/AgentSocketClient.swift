import Foundation
import Network

final class AgentSocketClient {
    enum Command: UInt8 {
        case touchDown = 0x01
        case touchUp = 0x02
        case touchMove = 0x03
        case key = 0x04
        case ping = 0x7f
    }

    private let queue = DispatchQueue(label: "com.harmonymirror.agent-socket")
    private var connection: NWConnection?
    private(set) var isConnected = false

    func connect(host: String = "127.0.0.1", port: UInt16, onReady: (() -> Void)? = nil) {
        disconnect()
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isConnected = true
                onReady?()
            case .failed, .cancelled:
                self?.isConnected = false
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
    }

    func sendTouch(_ command: Command, slot: UInt8 = 0, x: UInt16, y: UInt16) {
        sendFrame(command: command.rawValue, slot: slot, x: x, y: y)
    }

    func sendKey(_ keyCode: UInt16) {
        sendFrame(command: Command.key.rawValue, slot: 0, x: keyCode, y: 0)
    }

    func ping() {
        sendFrame(command: Command.ping.rawValue, slot: 0, x: 0, y: 0)
    }

    private func sendFrame(command: UInt8, slot: UInt8, x: UInt16, y: UInt16) {
        guard let connection else { return }
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = command
        bytes[1] = slot
        bytes[2] = UInt8(x & 0xff)
        bytes[3] = UInt8((x >> 8) & 0xff)
        bytes[4] = UInt8(y & 0xff)
        bytes[5] = UInt8((y >> 8) & 0xff)
        bytes[6] = 0
        bytes[7] = 0
        connection.send(content: Data(bytes), completion: .contentProcessed { error in
            if let error {
                Log.input.error("Agent send failed: \(error.localizedDescription)")
            }
        })
    }
}
