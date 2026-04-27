import Foundation
import Network

final class AgentSocketClient {
    enum Command: UInt8 {
        case touchDown = 0x01
        case touchUp = 0x02
        case touchMove = 0x03
        case key = 0x04
        case pinCode = 0x05
        case setProp = 0x10
        case openEvent = 0x11
        case log = 0x12
        case getInfo = 0x20
        case ping = 0x80
        case pong = 0x81
    }

    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case failed(Error)
    }

    var onStateChange: ((ConnectionState) -> Void)?
    var onPong: (() -> Void)?

    private let queue = DispatchQueue(label: "com.harmonymirror.agent-socket")
    private var connection: NWConnection?
    private(set) var isConnected = false
    private(set) var connectionState: ConnectionState = .disconnected

    private var pingTimer: DispatchSourceTimer?
    private var lastPongTime: Date?
    private let pingInterval: TimeInterval = 5.0
    private let pongTimeout: TimeInterval = 10.0
    private var pongCheckTimer: DispatchSourceTimer?

    func connect(host: String = "127.0.0.1", port: UInt16, onReady: (() -> Void)? = nil) {
        disconnect()
        updateState(.connecting)

        let endpoint = NWEndpoint.Host(host)
        guard let port = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: endpoint, port: port, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isConnected = true
                self?.updateState(.connected)
                self?.startReceiving()
                self?.startPingTimer()
                onReady?()
            case .failed(let error):
                self?.isConnected = false
                self?.updateState(.failed(error))
                self?.stopPingTimer()
            case .cancelled:
                self?.isConnected = false
                self?.updateState(.disconnected)
                self?.stopPingTimer()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func disconnect() {
        stopPingTimer()
        connection?.cancel()
        connection = nil
        isConnected = false
        updateState(.disconnected)
    }

    // MARK: - Touch

    func sendTouch(_ command: Command, slot: UInt8 = 0, x: UInt16, y: UInt16, pressure: UInt16 = 50) {
        guard command == .touchDown || command == .touchUp || command == .touchMove else { return }
        sendFrame(command: command.rawValue, slot: slot, x: x, y: y, reserved: pressure)
    }

    func sendMultiTouch(down: Bool, slot: UInt8, x: UInt16, y: UInt16) {
        let cmd: Command = down ? .touchDown : .touchUp
        sendFrame(command: cmd.rawValue, slot: slot, x: x, y: y)
    }

    // MARK: - Key

    func sendKey(_ keyCode: UInt16) {
        sendFrame(command: Command.key.rawValue, slot: 0, x: keyCode, y: 0)
    }

    // MARK: - PIN Code

    func sendPinCode(_ digits: [UInt8]) {
        guard digits.count <= 16 else { return }
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = Command.pinCode.rawValue
        bytes[1] = UInt8(min(digits.count, 4))
        for i in 0..<min(digits.count, 2) {
            bytes[2 + i] = digits[i] & 0x0F
        }
        if digits.count > 2 {
            for i in 2..<min(digits.count, 4) {
                bytes[3 + (i - 2)] = digits[i] & 0x0F
            }
        }
        sendRaw(Data(bytes))
    }

    // MARK: - Secure Screen Experiments

    func sendSetProperty(_ propBit: UInt8) {
        sendFrame(command: Command.setProp.rawValue, slot: propBit, x: 0, y: 0)
    }

    func sendOpenDirectEvent(eventIndex: UInt16) {
        sendFrame(command: Command.openEvent.rawValue, slot: 0, x: eventIndex, y: 0)
    }

    func sendOpenDirectEventAuto() {
        sendFrame(command: Command.openEvent.rawValue, slot: 0, x: 0, y: 0)
    }

    func requestInfo() {
        sendFrame(command: Command.getInfo.rawValue, slot: 0, x: 0, y: 0)
    }

    func requestLog() {
        sendFrame(command: Command.log.rawValue, slot: 0, x: 0, y: 0)
    }

    // MARK: - Health Check

    func ping() {
        lastPongTime = nil
        sendFrame(command: Command.ping.rawValue, slot: 0, x: 0, y: 0)
    }

    var timeSinceLastPong: TimeInterval? {
        guard let last = lastPongTime else { return nil }
        return Date().timeIntervalSince(last)
    }

    // MARK: - Internal

    private func sendFrame(command: UInt8, slot: UInt8, x: UInt16, y: UInt16, reserved: UInt16 = 0) {
        guard let connection else { return }
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = command
        bytes[1] = slot
        bytes[2] = UInt8(x & 0xff)
        bytes[3] = UInt8((x >> 8) & 0xff)
        bytes[4] = UInt8(y & 0xff)
        bytes[5] = UInt8((y >> 8) & 0xff)
        bytes[6] = UInt8(reserved & 0xff)
        bytes[7] = UInt8((reserved >> 8) & 0xff)
        sendRaw(Data(bytes))
    }

    private func sendRaw(_ data: Data) {
        guard let connection else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                Log.input.error("Agent send failed: \(error.localizedDescription)")
                if self?.isConnected == true {
                    self?.disconnect()
                }
            }
        })
    }

    private func startReceiving() {
        guard let connection else { return }
        receiveFrame()
    }

    private func receiveFrame() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                Log.input.error("Agent receive failed: \(error.localizedDescription)")
                self.disconnect()
                return
            }
            if let data, !data.isEmpty {
                self.handleReceivedData(data)
            }
            if self.isConnected {
                self.receiveFrame()
            }
        }
    }

    private func handleReceivedData(_ data: Data) {
        let bytes = [UInt8](data)

        if bytes.count >= 8 && bytes[0] == Command.pong.rawValue {
            lastPongTime = Date()
            onPong?()
            return
        }

        if bytes.count >= 8 && bytes[0] == Command.getInfo.rawValue {
            let mode = bytes[1]
            let valid = bytes[2]
            Log.input.info("Agent info: mode=\(mode == 0 ? "uinput" : "direct"), input_fd_valid=\(valid != 0)")
            return
        }

        if bytes.count >= 4 && bytes[0] == Command.log.rawValue {
            // Skip cmd byte, read rest as text
            if let text = String(data: Data(bytes.dropFirst()), encoding: .utf8) {
                Log.input.info("Agent log: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return
        }

        // Handle old-style "PONG" text response from Phase 1 agents
        if bytes.count == 4,
           bytes[0] == 0x50, bytes[1] == 0x4F, bytes[2] == 0x4E, bytes[3] == 0x47 {
            lastPongTime = Date()
            onPong?()
        }
    }

    private func startPingTimer() {
        stopPingTimer()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isConnected else { return }
            self.ping()

            if let lastPong = self.lastPongTime,
               Date().timeIntervalSince(lastPong) > self.pongTimeout {
                Log.input.error("Agent pong timeout — disconnecting")
                self.disconnect()
            }
        }
        timer.resume()
        pingTimer = timer

        let checker = DispatchSource.makeTimerSource(queue: queue)
        checker.schedule(deadline: .now() + pongTimeout, repeating: pongTimeout)
        checker.setEventHandler { [weak self] in
            guard let self, self.isConnected else { return }
            if let lastPong = self.lastPongTime,
               Date().timeIntervalSince(lastPong) > self.pongTimeout {
                Log.input.error("Agent health check failed — no pong received")
                self.disconnect()
            }
        }
        checker.resume()
        pongCheckTimer = checker
    }

    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
        pongCheckTimer?.cancel()
        pongCheckTimer = nil
    }

    private func updateState(_ state: ConnectionState) {
        connectionState = state
        if case .connected = state {
            isConnected = true
        } else {
            isConnected = false
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onStateChange?(state)
        }
    }
}
