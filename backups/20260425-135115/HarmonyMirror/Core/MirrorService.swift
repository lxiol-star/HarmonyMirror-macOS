import Foundation
import Combine
import AppKit
import CoreMedia
import AVFoundation

@MainActor
final class MirrorService: ObservableObject {
    @Published private(set) var state: MirrorState = .idle
    @Published private(set) var fps: Int = 0
    @Published private(set) var screenWidth: Int = 0
    @Published private(set) var screenHeight: Int = 0

    let hdcCommand: HDCCommand
    private(set) var inputInjector: InputInjector?
    private var streamReceiver: TCPStreamReceiver?
    private var h264VideoLayer: H264VideoLayer?
    private var bridgeProcess: Process?
    private var lastBridgeSerial: String?
    private var bridgeTerminationTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let grpcPort = 9500 + Int(ProcessInfo.processInfo.processIdentifier % 400)
    private let bridgePort = 18000 + Int(ProcessInfo.processInfo.processIdentifier % 800)

    weak var videoDisplayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            if let layer = videoDisplayLayer {
                h264VideoLayer?.bind(displayLayer: layer)
            }
        }
    }

    init(hdcCommand: HDCCommand) {
        self.hdcCommand = hdcCommand
    }

    func startMirroring(device: HarmonyDevice) async {
        if case .connecting = state { return }
        if case .connected = state { return }

        // Cancel any pending bridge termination so we can reuse it
        bridgeTerminationTask?.cancel()
        bridgeTerminationTask = nil

        cleanupStream()
        state = .connecting
        let serial = device.serial

        let injector = InputInjector(hdcCommand: hdcCommand, serial: serial)
        self.inputInjector = injector

        // Reuse bridge if it's already running for the same device
        let reuseBridge = (lastBridgeSerial == serial && bridgeProcess?.isRunning == true)
        if !reuseBridge {
            terminateBridge()
            do {
                try startBridge(serial: serial)
            } catch {
                state = .disconnected("无法启动投屏 bridge: \(error.localizedDescription)")
                cleanupStream()
                return
            }
            lastBridgeSerial = serial
        } else {
            Log.mirror.info("Reusing existing bridge for \(serial)")
        }

        // Wait for bridge TCP server to be ready
        for _ in 0..<30 {
            if isPortOpen(port: bridgePort) {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        let videoLayer = H264VideoLayer()
        if let displayLayer = self.videoDisplayLayer {
            videoLayer.bind(displayLayer: displayLayer)
        }
        videoLayer.onVideoDimensions = { [weak self] width, height in
            guard let self = self else { return }
            if self.screenWidth != width || self.screenHeight != height {
                self.screenWidth = width
                self.screenHeight = height
                self.inputInjector?.screenWidth = width
                self.inputInjector?.screenHeight = height
            }
        }
        self.h264VideoLayer = videoLayer

        let receiver = TCPStreamReceiver()
        receiver.onFrameReceived = { [weak videoLayer] data, pts, isKeyFrame in
            videoLayer?.feed(data, pts: pts, isKeyFrame: isKeyFrame)
        }
        receiver.$fps
            .receive(on: DispatchQueue.main)
            .assign(to: \.fps, on: self)
            .store(in: &cancellables)
        self.streamReceiver = receiver

        receiver.connect(host: "127.0.0.1", port: bridgePort)

        // Wait for connection
        for _ in 0..<20 {
            if receiver.isConnected {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        if receiver.isConnected {
            state = .connected
            Log.mirror.info("Video stream connected for \(serial)")
        } else {
            state = .disconnected("无法连接投屏服务，请检查设备是否已连接")
            cleanupStream()
        }
    }

    private func startBridge(serial: String) throws {
        let bridgePath = "\(AppConstants.projectRoot)/tools/deveco_cast_bridge.py"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        process.arguments = [
            bridgePath,
            "--serial", serial,
            "--grpc-port", "\(grpcPort)",
            "--bridge-port", "\(bridgePort)",
            "--remote-port", "8710"
        ]
        process.terminationHandler = { [weak self] _ in
            Log.mirror.info("Bridge process terminated")
            Task { @MainActor in
                self?.bridgeProcess = nil
            }
        }
        try process.run()
        bridgeProcess = process
        Log.mirror.info("Bridge process started for \(serial)")
    }

    private func isPortOpen(port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 {
            return true
        }
        return false
    }

    func stopMirroring() {
        cleanupStream()
        fps = 0
        screenWidth = 0
        screenHeight = 0
        state = .idle
        Log.mirror.info("Mirroring stopped")

        // Delay bridge termination by 60 seconds to allow quick reconnect
        bridgeTerminationTask?.cancel()
        bridgeTerminationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard let self, self.state == .idle else { return }
            self.terminateBridge()
        }
    }

    private func cleanupStream() {
        streamReceiver?.disconnect()
        streamReceiver = nil
        h264VideoLayer = nil
        inputInjector = nil
        cancellables.removeAll()
    }

    private func terminateBridge() {
        bridgeTerminationTask?.cancel()
        bridgeTerminationTask = nil
        if let process = bridgeProcess, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak process] in
                if let process = process, process.isRunning {
                    kill(pid_t(process.processIdentifier), SIGKILL)
                }
            }
        }
        bridgeProcess = nil
        lastBridgeSerial = nil
    }
}
