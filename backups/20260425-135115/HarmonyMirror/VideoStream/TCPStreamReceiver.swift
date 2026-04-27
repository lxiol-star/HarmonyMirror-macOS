import Foundation

final class TCPStreamReceiver: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var fps: Int = 0

    var onFrameReceived: ((Data, Int64, Bool) -> Void)?

    private var tcpSocket: Int32 = -1
    private var receiveTask: Task<Void, Never>?
    private var lastFpsTime = Date()
    private var frameCount = 0
    private let stateQueue = DispatchQueue(label: "com.harmonymirror.tcpstate")

    func connect(host: String, port: Int) {
        disconnect()

        receiveTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                await MainActor.run { self.isConnected = false }
                return
            }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            inet_pton(AF_INET, host, &addr.sin_addr)

            let connectResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            guard connectResult == 0 else {
                Darwin.close(sock)
                await MainActor.run { self.isConnected = false }
                Log.mirror.error("TCP connection failed: \(errno)")
                return
            }

            self.stateQueue.sync { self.tcpSocket = sock }
            await MainActor.run { self.isConnected = true }
            await self.readLoop(socket: sock)
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        stateQueue.sync {
            if tcpSocket >= 0 {
                Darwin.shutdown(tcpSocket, SHUT_RDWR)
                Darwin.close(tcpSocket)
                tcpSocket = -1
            }
        }
        DispatchQueue.main.async {
            self.isConnected = false
            self.fps = 0
        }
    }

    private func readLoop(socket: Int32) async {
        defer {
            close(socket)
            DispatchQueue.main.async {
                self.isConnected = false
                self.fps = 0
            }
        }

        while !Task.isCancelled {
            guard let lengthData = readExactly(socket: socket, count: 4) else {
                Log.mirror.error("TCP read length failed")
                return
            }
            let payloadLength = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            guard payloadLength > 0, payloadLength < 2 * 1024 * 1024 else {
                Log.mirror.error("Invalid payload length: \(payloadLength), disconnecting")
                return
            }

            guard let payload = readExactly(socket: socket, count: Int(payloadLength)) else {
                Log.mirror.error("TCP read payload failed")
                return
            }

            guard payload.count >= 9 else { continue }
            let flags = payload[0]
            let pts = payload.subdata(in: 1..<9).withUnsafeBytes { $0.load(as: Int64.self).bigEndian }
            let h264Data = payload.subdata(in: 9..<payload.count)
            let isKeyFrame = (flags & 1) != 0

            try? Task.checkCancellation()

            await MainActor.run {
                self.onFrameReceived?(h264Data, pts, isKeyFrame)
                self.frameCount += 1
                let now = Date()
                if now.timeIntervalSince(self.lastFpsTime) >= 1.0 {
                    self.fps = self.frameCount
                    self.frameCount = 0
                    self.lastFpsTime = now
                }
            }
        }
    }

    private func readExactly(socket: Int32, count: Int) -> Data? {
        var data = Data()
        data.reserveCapacity(count)
        var remaining = count

        while remaining > 0 {
            var buffer = [UInt8](repeating: 0, count: remaining)
            let bytesRead = recv(socket, &buffer, remaining, 0)
            if bytesRead <= 0 {
                return nil
            }
            data.append(buffer, count: bytesRead)
            remaining -= bytesRead
        }

        return data
    }
}
