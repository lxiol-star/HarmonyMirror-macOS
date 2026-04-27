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
    @Published private(set) var currentDevice: HarmonyDevice?

    let hdcCommand: HDCCommand
    private(set) var inputInjector: InputInjector?
    private var streamReceiver: TCPStreamReceiver?
    private var h264VideoLayer: H264VideoLayer?
    private var bridgeProcess: Process?
    private var lastBridgeSerial: String?
    private var bridgeTerminationTask: Task<Void, Never>?
    private var orientationMonitorTask: Task<Void, Never>?
    private var isRestartingForDisplayChange = false
    private var cancellables = Set<AnyCancellable>()
    private let grpcPort = 9500 + Int(ProcessInfo.processInfo.processIdentifier % 400)
    private let bridgePort = 18000 + Int(ProcessInfo.processInfo.processIdentifier % 800)
    private let agentPort = 19000 + Int(ProcessInfo.processInfo.processIdentifier % 800)
    private var agentHealthTask: Task<Void, Never>?

    weak var videoDisplayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            if let layer = videoDisplayLayer {
                h264VideoLayer?.bind(displayLayer: layer)
            }
        }
    }

    init(hdcCommand: HDCCommand) {
        self.hdcCommand = hdcCommand
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func applicationWillTerminate() {
        orientationMonitorTask?.cancel()
        orientationMonitorTask = nil
        cleanupStream()
        terminateBridge()
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
        screenWidth = 0
        screenHeight = 0
        var preparedDevice = device
        if let displaySize = try? await hdcCommand.displaySize(serial: serial) {
            let width = Int(displaySize.width)
            let height = Int(displaySize.height)
            if width > 0, height > 0 {
                preparedDevice.screenWidth = width
                preparedDevice.screenHeight = height
                preparedDevice.formFactor = HarmonyDevice.inferFormFactor(
                    model: preparedDevice.model,
                    serial: preparedDevice.serial,
                    width: width,
                    height: height
                )
                screenWidth = width
                screenHeight = height
            }
        }
        currentDevice = preparedDevice

        let injector = InputInjector(hdcCommand: hdcCommand, serial: serial)
        if screenWidth > 0, screenHeight > 0 {
            injector.screenWidth = screenWidth
            injector.screenHeight = screenHeight
        }
        self.inputInjector = injector
        await configureAgentInput(serial: serial, injector: injector)

        // Don't reuse bridge when switching devices - always start fresh
        // Bridge reuse can cause issues with different device parameters
        terminateBridge()
        do {
            try await prepareDeviceForBridge(serial: serial)
            try startBridge(serial: serial)
        } catch {
            state = .disconnected("无法启动投屏 bridge: \(error.localizedDescription)")
            cleanupStream()
            return
        }
        lastBridgeSerial = serial

        // Wait for bridge TCP server to be ready
        // Reduce timeout from 3s to 2s, check more frequently
        var bridgeReady = false
        for attempt in 0..<40 {
            if await isPortOpenAsync(port: bridgePort) {
                bridgeReady = true
                Log.mirror.info("Bridge ready after \(attempt * 50)ms")
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s
        }
        if !bridgeReady {
            state = .disconnected("投屏 bridge 启动超时，请重试")
            cleanupStream()
            return
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
                if var device = self.currentDevice {
                    device.screenWidth = width
                    device.screenHeight = height
                    device.formFactor = HarmonyDevice.inferFormFactor(
                        model: device.model,
                        serial: device.serial,
                        width: width,
                        height: height
                    )
                    self.currentDevice = device
                }
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

        // Wait for connection - reduce timeout and check more frequently
        for attempt in 0..<30 {
            if receiver.isConnected {
                Log.mirror.info("TCP stream connected after \(attempt * 50)ms")
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s
        }

        if receiver.isConnected {
            state = .connected
            startDisplaySizeMonitor(device: device)
            Log.mirror.info("Video stream ready for \(serial), waiting for first frame...")

            // Add timeout detection - if no frame received in 10 seconds, restart
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                guard let self, case .connected = self.state, self.fps == 0 else { return }
                Log.mirror.warning("No video frame received after 10s, restarting connection")
                self.state = .disconnected("未收到视频数据，正在重试...")
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                await self.startMirroring(device: device)
            }
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
            "--remote-port", "8710",
            "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)",
            "--idle-timeout", "90",
            "--skip-device-setup"
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

    private func prepareDeviceForBridge(serial: String) async throws {
        let remoteLibrary = "/data/local/tmp/libscreen_casting.z.so"
        let remotePort = 8710
        let socketName = "localabstract:scrcpy_grpc_socket"
        let startCommand = [
            "/system/bin/uitest start-daemon singleness",
            "--extension-name libscreen_casting.z.so",
            "-scale 1",
            "-frameRate -1",
            "-bitRate 52428800",
            "-p \(remotePort)",
            "-screenId 0",
            "-encodeType 0",
            "-iFrameInterval 2000",
            "-repeatInterval 33"
        ].joined(separator: " ")

        // Skip WiFi reconnection check - device should already be connected
        // This check is slow and usually unnecessary

        // Always restart casting service to ensure fresh stream
        // Check if service is running and kill it
        let existingProcess = try? await hdcCommand.shell("ps -ef | grep libscreen_casting.z.so | grep -v grep", serial: serial)
        if let output = existingProcess, output.contains("libscreen_casting.z.so") {
            // Kill existing process
            for line in output.components(separatedBy: "\n") {
                guard line.contains("libscreen_casting.z.so") else { continue }
                let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if columns.count >= 2, let pid = Int(columns[1]) {
                    _ = try? await hdcCommand.shell("kill -9 \(pid)", serial: serial)
                    Log.mirror.info("Killed existing casting process: \(pid)")
                }
            }
            // Wait for process to die
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // Check library exists
        let libraryCheck = try? await hdcCommand.shell("ls -l \(remoteLibrary)", serial: serial)
        guard libraryCheck?.contains("libscreen_casting.z.so") == true else {
            throw MirrorError.captureError("设备缺少 libscreen_casting.z.so，请先打开 DevEco Testing 投屏一次")
        }

        // Start casting service
        _ = try? await hdcCommand.shell(startCommand, serial: serial)
        // Reduce wait time from 1s to 0.5s
        try? await Task.sleep(nanoseconds: 500_000_000)

        // Verify service started
        let runningProcess = try? await hdcCommand.shell("ps -ef | grep libscreen_casting.z.so | grep -v grep", serial: serial)
        guard runningProcess?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw MirrorError.captureError("screen casting 服务未启动")
        }

        // Setup port forwarding
        await hdcCommand.removeForward(local: "tcp:\(grpcPort)", remote: socketName, serial: serial)
        _ = try await hdcCommand.forward(local: "tcp:\(grpcPort)", remote: socketName, serial: serial)

        // Skip validateTarget - it's slow and forward already validates connection
        Log.mirror.info("Casting service prepared for \(serial), grpcPort=\(self.grpcPort)")
    }

    private func configureAgentInput(serial: String, injector: InputInjector) async {
        // Only set up the agent if it was successfully deployed and started on device.
        // An hdc forward to a port with no listener may still accept local TCP
        // connections, causing the AgentSocketClient to think it's connected and
        // silently swallow all input instead of falling back to hdc commands.
        let agentReady = await deployAndStartAgent(serial: serial)
        guard agentReady else {
            injector.setAgentClient(nil)
            Log.input.info("HarmonyAgent not available for \(serial); using hdc input")
            return
        }

        let local = "tcp:\(agentPort)"
        let remote = "tcp:\(AppConstants.agentRemotePort)"

        await hdcCommand.removeForward(local: local, remote: remote, serial: serial)
        do {
            _ = try await hdcCommand.forward(local: local, remote: remote, serial: serial)
            let client = AgentSocketClient()
            injector.setAgentClient(client)

            var wasConnected = false
            client.onStateChange = { [weak self] state in
                guard let self else { return }
                if case .connected = state {
                    wasConnected = true
                }
                if case .failed = state, wasConnected, case .connected = self.state {
                    Log.input.error("HarmonyAgent disconnected unexpectedly for \(serial)")
                    Task { @MainActor in
                        self.attemptAgentReconnect(serial: serial, injector: injector)
                    }
                }
            }

            client.connect(port: UInt16(agentPort)) {
                Log.input.info("HarmonyAgent input connected for \(serial)")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            if client.isConnected {
                startAgentHealthMonitor(serial: serial, client: client)
            } else {
                injector.setAgentClient(nil)
                Log.input.info("HarmonyAgent input forward ok but connect failed for \(serial); falling back to hdc input")
            }
        } catch {
            injector.setAgentClient(nil)
            Log.input.info("HarmonyAgent input forward unavailable for \(serial): \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func deployAndStartAgent(serial: String) async -> Bool {
        let remotePath = "/data/local/tmp/harmony_agent"
        let agentSourcePath = "\(AppConstants.projectRoot)/agent/harmony_agent"

        // Check if agent is already running on device
        if let psOutput = try? await hdcCommand.shell("ps -ef | grep harmony_agent | grep -v grep", serial: serial),
           psOutput.contains("harmony_agent") {
            Log.input.info("HarmonyAgent already running on \(serial)")
            return true
        }

        // Check if agent binary exists on device (has execute permission = already deployed)
        if let checkOutput = try? await hdcCommand.shell("ls -l \(remotePath)", serial: serial),
           checkOutput.contains(remotePath) {
            Log.input.info("HarmonyAgent binary found on device, starting...")
        } else {
            let binaryExists = FileManager.default.fileExists(atPath: agentSourcePath)
            if binaryExists {
                Log.input.info("Deploying HarmonyAgent to \(serial)...")
                do {
                    try await hdcCommand.fileSend(local: agentSourcePath, remote: remotePath, serial: serial)
                } catch {
                    Log.input.error("Failed to deploy HarmonyAgent: \(error.localizedDescription)")
                    return false
                }
            } else {
                Log.input.info("No pre-built HarmonyAgent binary found at \(agentSourcePath)")
                return false
            }

            // Make executable
            _ = try? await hdcCommand.shell("chmod +x \(remotePath)", serial: serial)
        }

        // Start agent in background on device
        let startCmd = "nohup \(remotePath) -v > /dev/null 2>&1 &"
        _ = try? await hdcCommand.shell(startCmd, serial: serial)
        try? await Task.sleep(nanoseconds: 800_000_000)

        // Verify agent is running
        if let psOutput = try? await hdcCommand.shell("ps -ef | grep harmony_agent | grep -v grep", serial: serial),
           psOutput.contains("harmony_agent") {
            Log.input.info("HarmonyAgent started successfully on \(serial)")
            return true
        } else {
            Log.input.notice("HarmonyAgent may not have started on \(serial) (binary needs aarch64 cross-compilation)")
            return false
        }
    }

    private func attemptAgentReconnect(serial: String, injector: InputInjector) {
        guard case .connected = state else { return }
        agentHealthTask?.cancel()
        agentHealthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            Log.input.info("Attempting to reconnect HarmonyAgent for \(serial)...")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard case .connected = self.state else { return }
            await self.configureAgentInput(serial: serial, injector: injector)
        }
    }

    private func startAgentHealthMonitor(serial: String, client: AgentSocketClient) {
        agentHealthTask?.cancel()
        agentHealthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000) // 15s interval
                guard !Task.isCancelled,
                      let self,
                      case .connected = self.state,
                      client.isConnected else { return }
                client.ping()
            }
        }
    }

    private func isPortOpenAsync(port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let result = Self.checkPortOpen(port: port)
                continuation.resume(returning: result)
            }
        }
    }

    private static func checkPortOpen(port: Int) -> Bool {
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
        orientationMonitorTask?.cancel()
        orientationMonitorTask = nil
        cleanupStream()
        fps = 0
        screenWidth = 0
        screenHeight = 0
        currentDevice = nil
        state = .idle
        Log.mirror.info("Mirroring stopped")

        // Immediately terminate bridge when explicitly stopping
        // Don't delay - user is switching devices or disconnecting
        bridgeTerminationTask?.cancel()
        bridgeTerminationTask = nil
        terminateBridge()
    }

    private func cleanupStream() {
        agentHealthTask?.cancel()
        agentHealthTask = nil
        streamReceiver?.disconnect()
        streamReceiver = nil
        h264VideoLayer?.flushAndRemoveImage()
        h264VideoLayer = nil
        inputInjector?.setAgentClient(nil)
        inputInjector = nil
        cancellables.removeAll()
    }

    private func startDisplaySizeMonitor(device: HarmonyDevice) {
        orientationMonitorTask?.cancel()
        orientationMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var mismatchCount = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, self.currentDevice?.serial == device.serial else { break }
                guard case .connected = self.state else { continue }
                guard !self.isRestartingForDisplayChange else { continue }
                guard self.screenWidth > 0, self.screenHeight > 0 else { continue }
                guard let displaySize = try? await self.hdcCommand.displaySize(serial: device.serial) else { continue }

                let displayWidth = Int(displaySize.width)
                let displayHeight = Int(displaySize.height)
                let displayIsLandscape = displayWidth >= displayHeight
                let videoIsLandscape = self.screenWidth >= self.screenHeight

                if displayWidth > 0,
                   displayHeight > 0,
                   displayIsLandscape != videoIsLandscape {
                    mismatchCount += 1
                } else {
                    mismatchCount = 0
                }

                guard mismatchCount >= 2 else { continue }
                Log.mirror.info("Display orientation changed on device \(device.serial): display=\(displayWidth)x\(displayHeight), video=\(self.screenWidth)x\(self.screenHeight). Restarting casting.")
                await self.restartMirroringForDisplayChange(device: device, width: displayWidth, height: displayHeight)
                break
            }
        }
    }

    private func restartMirroringForDisplayChange(device: HarmonyDevice, width: Int, height: Int) async {
        guard !isRestartingForDisplayChange else { return }
        isRestartingForDisplayChange = true
        orientationMonitorTask?.cancel()
        orientationMonitorTask = nil

        cleanupStream()
        terminateBridge()
        screenWidth = width
        screenHeight = height
        currentDevice?.screenWidth = width
        currentDevice?.screenHeight = height
        state = .idle

        // Wait longer for old bridge to fully terminate and release ports
        for _ in 0..<20 {
            if !(await isPortOpenAsync(port: bridgePort)) {
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        isRestartingForDisplayChange = false
        await startMirroring(device: device)
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

    var windowTitle: String {
        currentDevice?.displayName ?? "HarmonyMirror"
    }

    var orientationLabel: String {
        guard screenWidth > 0, screenHeight > 0 else { return "等待画面" }
        return screenWidth >= screenHeight ? "横屏" : "竖屏"
    }

    var preferredMinWindowSize: CGSize {
        guard screenWidth > 0, screenHeight > 0 else {
            return CGSize(width: 360, height: 560)
        }
        if screenWidth >= screenHeight {
            return CGSize(width: 640, height: 420)
        }
        if currentDevice?.formFactor == .tablet {
            return CGSize(width: 420, height: 620)
        }
        return CGSize(width: 320, height: 560)
    }
}
