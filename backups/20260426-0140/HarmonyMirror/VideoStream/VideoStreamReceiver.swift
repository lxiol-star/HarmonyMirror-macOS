import Foundation
import Combine

final class VideoStreamReceiver: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var fps: Int = 0

    var onFrameReceived: ((Data, Int64, Bool) -> Void)?

    private let session = URLSession(configuration: .default)
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var lastFpsTime = Date()
    private var frameCount = 0
    private var messageCount = 0

    func connect(serial: String) {
        disconnect()

        let path = "\(serial)_\(AppConstants.castingRemoteHost)_\(AppConstants.castingRemotePort)"
        guard let url = URL(string: "ws://127.0.0.1:\(AppConstants.castingWebSocketPort)/\(path)") else {
            return
        }

        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        let sizeMessage = #"{"type":"size","sn":"\#(serial)"}"#
        let screenMessage = #"{"type":"screen","sn":"\#(serial)","remoteIp":"\#(AppConstants.castingRemoteHost)","remotePort":"\#(AppConstants.castingRemotePort)"}"#
        task.send(.string(sizeMessage)) { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.isConnected = false
                    Log.mirror.error("casting websocket size failed: \(error.localizedDescription)")
                }
                return
            }
            task.send(.string(screenMessage)) { [weak self] error in
                if let error {
                    DispatchQueue.main.async {
                        self?.isConnected = false
                        Log.mirror.error("casting websocket screen failed: \(error.localizedDescription)")
                    }
                    return
                }
                DispatchQueue.main.async {
                    self?.isConnected = true
                }
            }
        }

        receiveLoop()
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        DispatchQueue.main.async {
            self.isConnected = false
            self.fps = 0
            self.messageCount = 0
        }
    }

    private func receiveLoop() {
        guard let task = webSocketTask else { return }

        receiveTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    try Task.checkCancellation()
                    await self.handle(message: message)
                } catch {
                    await MainActor.run {
                        self.isConnected = false
                        self.fps = 0
                    }
                    Log.mirror.error("casting websocket receive failed: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    @MainActor
    private func handle(message: URLSessionWebSocketTask.Message) {
        messageCount += 1
        switch message {
        case .data(let data):
            if messageCount <= 5 {
                Log.mirror.info("casting data message \(self.messageCount), bytes=\(data.count)")
            }
            handleFrameData(data)
        case .string(let text):
            if messageCount <= 5 {
                Log.mirror.info("casting string message \(self.messageCount), chars=\(text.count), prefix=\(String(text.prefix(80)))")
            }
            if text.hasPrefix("video cast error") {
                Log.mirror.error("casting error: \(text)")
                isConnected = false
                return
            }
            if text.hasPrefix("screenSize:") {
                let payload = String(text.dropFirst("screenSize:".count))
                let parts = payload.split(separator: "x")
                if parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) {
                    if width > 0 && height > 0 {
                        Log.mirror.info("casting screen size \(width)x\(height)")
                    }
                }
                return
            }

            if let data = Data(base64Encoded: text, options: [.ignoreUnknownCharacters]), !data.isEmpty {
                handleFrameData(data)
            }
        @unknown default:
            break
        }
    }

    @MainActor
    private func handleFrameData(_ data: Data) {
        guard !data.isEmpty else { return }
        onFrameReceived?(data, timeStampMicros(), true)
        frameCount += 1
        let now = Date()
        if now.timeIntervalSince(lastFpsTime) >= 1.0 {
            fps = frameCount
            frameCount = 0
            lastFpsTime = now
        }
    }

    private func timeStampMicros() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000)
    }
}
