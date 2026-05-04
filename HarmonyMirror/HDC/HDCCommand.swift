import Foundation
import CoreGraphics

final class HDCCommand {
    let hdcPath: String?
    private static let defaultTimeout: TimeInterval = 15

    init() {
        self.hdcPath = Self.findHDC()
    }

    private static func findHDC() -> String? {
        for path in AppConstants.hdcPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        let whichResult = try? run("/usr/bin/which", arguments: ["hdc"])
        if let path = whichResult?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let cachePath = NSHomeDirectory() + "/Library/Caches/hdc_tools/hdc"
        if FileManager.default.isExecutableFile(atPath: cachePath) {
            return cachePath
        }
        return nil
    }

    func ensureHDC() throws -> String {
        guard let path = hdcPath else { throw MirrorError.hdcNotFound }
        return path
    }

    func listTargets() async throws -> [String] {
        let detailedTargets = try await listTargetDetails()
        let connectedTargets = detailedTargets
            .filter(\.isConnected)
            .map(\.serial)
        if !connectedTargets.isEmpty {
            return connectedTargets
        }

        let fallback = try await execute(["list", "targets"])
        return fallback.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "[Empty]" }
            .compactMap { line in
                line.components(separatedBy: .whitespacesAndNewlines).first
            }
            .filter { !$0.isEmpty }
    }

    func listTargetDetails() async throws -> [HDCTarget] {
        let output = try await execute(["list", "targets", "-v"])
        let targets = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "[Empty]" }
            .compactMap { line -> HDCTarget? in
                let columns = line.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                guard let target = columns.first else { return nil }
                if columns.count >= 3 {
                    return HDCTarget(
                        serial: target,
                        transport: columns[1],
                        status: columns[2],
                        endpoint: columns.count >= 4 ? columns[3] : nil
                    )
                }
                return HDCTarget(
                    serial: target,
                    transport: target.contains(":") ? "TCP" : "USB",
                    status: "Connected",
                    endpoint: nil
                )
            }
        if !targets.isEmpty {
            return targets
        }

        let fallback = try await execute(["list", "targets"])
        return fallback.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "[Empty]" }
            .compactMap { line in
                line.components(separatedBy: .whitespacesAndNewlines).first.map {
                    HDCTarget(serial: $0, transport: $0.contains(":") ? "TCP" : "USB", status: "Connected", endpoint: nil)
                }
            }
            .filter { !$0.serial.isEmpty }
    }

    func connectWiFi(host: String, port: Int = AppConstants.wifiDebugPorts.first ?? 10178) async throws -> String {
        let target = Self.wifiTarget(from: host, defaultPort: port)

        // Validate IP format before attempting connection
        let hostPart = target.components(separatedBy: ":").first ?? target
        if !isValidIPv4(hostPart) && !hostPart.hasPrefix("[") {
            throw MirrorError.commandFailed("无效的 IP 地址格式: \(hostPart)")
        }

        _ = try? await execute(["tconn", target, "-remove"])
        try? await Task.sleep(nanoseconds: 300_000_000)

        let output = try await execute(["tconn", target])
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Verify device in list targets (more reliable than immediate shell echo ok)
        let hostPrefix = target.components(separatedBy: ":").first ?? target
        for attempt in 0..<5 {
            if let targets = try? await listTargetDetails() {
                if targets.contains(where: { $0.serial == target && $0.isConnected }) {
                    try await validateTarget(target)
                    return output
                }
                if let match = targets.first(where: { $0.serial.hasPrefix(hostPrefix + ":") && $0.isConnected }) {
                    Log.hdc.info("Device registered as \(match.serial) instead of \(target)")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    try await validateTarget(match.serial)
                    return output
                }
            }
            if attempt < 4 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        // Last resort: restart server and retry
        Log.hdc.info("WiFi connect last resort: restarting hdc server")
        _ = try? await execute(["kill", "-r"])
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        _ = try? await execute(["tconn", target, "-remove"])
        try? await Task.sleep(nanoseconds: 500_000_000)
        let retryOutput = try await execute(["tconn", target])
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        try await validateTarget(target)
        return retryOutput
    }

    private func isValidIPv4(_ ip: String) -> Bool {
        let components = ip.components(separatedBy: ".")
        guard components.count == 4 else { return false }
        return components.allSatisfy { component in
            guard let num = Int(component), num >= 0, num <= 255 else { return false }
            return true
        }
    }

    func disconnectWiFi(host: String, port: Int = AppConstants.wifiDebugPorts.first ?? 10178) async throws -> String {
        try await execute(["tconn", Self.wifiTarget(from: host, defaultPort: port), "-remove"])
    }

    func enableWiFiDebug(serial: String, port: Int = AppConstants.wifiDebugPorts.first ?? 10178) async throws -> String {
        try await execute(["-t", serial, "tmode", "port", "\(port)"])
    }

    func deviceWiFiAddress(serial: String) async throws -> String? {
        let output = try await shell("ifconfig wlan0", serial: serial)
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = trimmed.range(of: "inet addr:") {
                let value = trimmed[range.upperBound...]
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first
                return value.map(String.init)
            }
            if trimmed.hasPrefix("inet ") {
                let value = trimmed
                    .dropFirst("inet ".count)
                    .split(separator: "/")
                    .first?
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first
                return value.map(String.init)
            }
        }
        return nil
    }

    func displaySize(serial: String) async throws -> CGSize? {
        let output = try await shell("hidumper -s DisplayManagerService -a -a", serial: serial)
        var inDefaultDisplay = false
        var width: Int?
        var height: Int?

        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("---------------- Display ID: 0") {
                inDefaultDisplay = true
                width = nil
                height = nil
                continue
            }
            if inDefaultDisplay, line.hasPrefix("---------------- Display ID:"), !line.hasPrefix("---------------- Display ID: 0") {
                break
            }
            guard inDefaultDisplay else { continue }

            if line.hasPrefix("Width:") {
                width = line.components(separatedBy: .whitespacesAndNewlines)
                    .compactMap(Int.init)
                    .first
            } else if line.hasPrefix("Height:") {
                height = line.components(separatedBy: .whitespacesAndNewlines)
                    .compactMap(Int.init)
                    .first
            }

            if let width, let height, width > 0, height > 0 {
                return CGSize(width: width, height: height)
            }
        }

        return nil
    }

    func deviceProfile(serial: String) async -> DeviceProfile {
        // Fetch sequentially — concurrent hdc shell calls over USB can overwhelm
        // the connection and cause spurious failures. TCP handles concurrency
        // better, but we serialize for consistency across transports.
        let model = await optionalShellParam("const.product.model", serial: serial)
        let name = await optionalShellParam("const.product.name", serial: serial)
        let deviceType = await optionalShellParam("const.product.devicetype", serial: serial)
        let btName = await optionalShellParam("bluetooth.name", serial: serial)
        let sysName = await optionalShellParam("persist.sys.device_name", serial: serial)
        return DeviceProfile(
            productModel: model,
            productName: name,
            deviceType: deviceType,
            userName: !btName.isEmpty ? btName : sysName
        )
    }

    func switchToUSB(serial: String) async throws -> String {
        try await execute(["-t", serial, "tmode", "usb"])
    }

    func forward(local: String, remote: String, serial: String? = nil) async throws -> String {
        var args: [String] = []
        if let serial { args += ["-t", serial] }
        args += ["fport", local, remote]
        return try await execute(args)
    }

    func removeForward(local: String, remote: String, serial: String? = nil) async {
        var args: [String] = []
        if let serial { args += ["-t", serial] }
        args += ["fport", "rm", local, remote]
        _ = try? await execute(args)
    }

    func cleanupHarmonyAgent(serial: String) async throws -> String {
        _ = try? await shell("killall harmony_agent", serial: serial)
        try? await Task.sleep(for: .milliseconds(200))

        if let pidOutput = try? await shell("pidof harmony_agent", serial: serial) {
            let pids = pidOutput
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .compactMap { Int($0) }
            if !pids.isEmpty {
                _ = try? await shell("kill -9 \(pids.map(String.init).joined(separator: " "))", serial: serial)
            }
        }

        let cleanupPaths = [
            "/data/local/tmp/harmony_agent",
            "/data/local/tmp/harmony_agent.log",
            "/data/local/tmp/nohup.out",
            AppConstants.remoteScreenPath
        ]
        _ = try await shell("rm -f \(cleanupPaths.joined(separator: " "))", serial: serial)

        let removedForwards = await cleanupAgentForwards(serial: serial)
        let remainingAgent = (try? await shell("find /data/local/tmp -maxdepth 1 -name '*harmony_agent*'", serial: serial))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let remainingPid = (try? await shell("pidof harmony_agent", serial: serial))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !remainingPid.isEmpty || !remainingAgent.isEmpty {
            var leftovers: [String] = []
            if !remainingPid.isEmpty { leftovers.append("进程仍存在: \(remainingPid)") }
            if !remainingAgent.isEmpty { leftovers.append("文件仍存在: \(remainingAgent)") }
            throw MirrorError.commandFailed(leftovers.joined(separator: "；"))
        }

        return removedForwards > 0 ? "已清理 Agent，并移除 \(removedForwards) 条端口转发" : "已清理 Agent"
    }

    func shell(_ command: String, serial: String? = nil) async throws -> String {
        var args: [String] = []
        if let serial { args += ["-t", serial] }
        args += ["shell", command]
        return try await execute(args)
    }

    func fileRecv(remote: String, local: String, serial: String? = nil) async throws {
        var args: [String] = []
        if let serial { args += ["-t", serial] }
        args += ["file", "recv", remote, local]
        _ = try await execute(args)
    }

    func fileSend(local: String, remote: String, serial: String? = nil) async throws {
        var args: [String] = []
        if let serial { args += ["-t", serial] }
        args += ["file", "send", local, remote]
        _ = try await execute(args)
    }

    func snapshot(serial: String? = nil) async throws -> String {
        let localPath = NSTemporaryDirectory() + "harmony_screen_\(ProcessInfo.processInfo.processIdentifier).jpeg"
        _ = try await shell("snapshot_display -f \(AppConstants.remoteScreenPath)", serial: serial)
        try await fileRecv(remote: AppConstants.remoteScreenPath, local: localPath, serial: serial)
        return localPath
    }

    func inputClick(x: Int, y: Int, serial: String? = nil) async throws {
        _ = try await shell("uitest uiInput click \(x) \(y)", serial: serial)
    }

    func inputSwipe(x1: Int, y1: Int, x2: Int, y2: Int, speed: Int = 600, serial: String? = nil) async throws {
        _ = try await shell("uitest uiInput swipe \(x1) \(y1) \(x2) \(y2) \(speed)", serial: serial)
    }

    func inputKeyEvent(_ keyCode: Int, serial: String? = nil) async throws {
        _ = try await shell("uitest uiInput keyEvent \(keyCode)", serial: serial)
    }

    func inputTouchEvent(action: Int, x: Int, y: Int, serial: String? = nil) async throws {
        _ = try await shell("uitest uiInput injectTouchEvent \(action) \(x) \(y)", serial: serial)
    }

    // MARK: - uinput (kernel-level injection, lower latency than uitest uiInput)

    func uinputClick(x: Int, y: Int, serial: String? = nil) async throws {
        _ = try await shell("uinput -T -c \(x) \(y)", serial: serial)
    }

    func uinputSwipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int = 200, serial: String? = nil) async throws {
        _ = try await shell("uinput -T -m \(x1) \(y1) \(x2) \(y2) \(durationMs)", serial: serial)
    }

    func uinputDrag(x1: Int, y1: Int, x2: Int, y2: Int, pressTimeMs: Int = 500, totalTimeMs: Int = 1000, serial: String? = nil) async throws {
        _ = try await shell("uinput -T -g \(x1) \(y1) \(x2) \(y2) \(pressTimeMs) \(totalTimeMs)", serial: serial)
    }

    func uinputTouchDown(x: Int, y: Int, serial: String? = nil) async throws {
        _ = try await shell("uinput -T -d \(x) \(y)", serial: serial)
    }

    func uinputTouchUp(x: Int, y: Int, serial: String? = nil) async throws {
        _ = try await shell("uinput -T -u \(x) \(y)", serial: serial)
    }

    func uinputTouchMove(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Int = 1, serial: String? = nil) async throws {
        _ = try await shell("uinput -T -m \(x1) \(y1) \(x2) \(y2) \(durationMs)", serial: serial)
    }

    func uinputKeyEvent(_ keyCode: Int, serial: String? = nil) async throws {
        _ = try await shell("uinput -K -d \(keyCode) -i 50 -u \(keyCode)", serial: serial)
    }

    func uitestHome(serial: String? = nil) async throws {
        _ = try await shell("uitest uiInput keyEvent Home", serial: serial)
    }

    func uitestBack(serial: String? = nil) async throws {
        _ = try await shell("uitest uiInput keyEvent Back", serial: serial)
    }

    func validateTarget(_ target: String) async throws {
        _ = try await shell("echo ok", serial: target)
    }

    private func optionalShellParam(_ key: String, serial: String) async -> String {
        // USB hdc shell channel may not be ready immediately after connect;
        // retry once with a delay if the first attempt throws.
        let isUSB = !serial.contains(":")
        for attempt in 0..<(isUSB ? 2 : 1) {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(3))
            }
            guard let output = try? await shell("param get \(key)", serial: serial) else { continue }
            let value = output
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.hasPrefix("[") && !$0.lowercased().contains("fail") } ?? ""
            if value == "default" || value == "unknown" || value == key {
                return ""
            }
            if !value.isEmpty { return value }
            // If shell succeeded but value was empty/filtered, the param
            // genuinely doesn't exist — no point retrying.
            break
        }
        return ""
    }

    static func wifiTarget(from input: String, defaultPort: Int = AppConstants.wifiDebugPorts.first ?? 10178) -> String {
        var target = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstToken = target.components(separatedBy: .whitespacesAndNewlines).first {
            target = firstToken
        }
        target = target
            .replacingOccurrences(of: "hdc://", with: "")
            .replacingOccurrences(of: "tcp://", with: "")

        // IPv6 format
        if target.hasPrefix("[") {
            return target.contains("]:") ? target : "\(target):\(defaultPort)"
        }

        // IPv4 format: validate and normalize
        let parts = target.components(separatedBy: ":")
        if parts.count == 2 {
            // Already has port, validate IP part
            let ipPart = parts[0]
            let portPart = parts[1]
            let normalizedIP = normalizeIPv4(ipPart)
            return "\(normalizedIP):\(portPart)"
        } else if parts.count == 1 {
            // No port, add default
            let normalizedIP = normalizeIPv4(parts[0])
            return "\(normalizedIP):\(defaultPort)"
        } else {
            // Multiple colons, might be malformed - try to extract valid IP
            let ipPart = parts.dropLast().joined(separator: ".")
            let normalizedIP = normalizeIPv4(ipPart)
            if let port = parts.last, !port.isEmpty {
                return "\(normalizedIP):\(port)"
            }
            return "\(normalizedIP):\(defaultPort)"
        }
    }

    private static func normalizeIPv4(_ input: String) -> String {
        // Remove any extra dots and validate IPv4 format
        let components = input.components(separatedBy: ".")
            .filter { !$0.isEmpty }
            .compactMap { Int($0) }
            .filter { $0 >= 0 && $0 <= 255 }

        if components.count == 4 {
            return components.map(String.init).joined(separator: ".")
        }

        // If invalid, return original (will fail later with proper error)
        return input
    }

    private func cleanupAgentForwards(serial: String) async -> Int {
        var removed = 0
        guard let output = try? await execute(["-t", serial, "fport", "ls"]) else { return removed }
        for line in output.components(separatedBy: "\n") {
            let columns = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard columns.count >= 2, line.contains("tcp:\(AppConstants.agentRemotePort)") else { continue }
            let local = columns[0]
            let remote = columns[1]
            _ = try? await execute(["-t", serial, "fport", "rm", local, remote])
            removed += 1
        }
        return removed
    }

    private func execute(_ arguments: [String]) async throws -> String {
        let path = try ensureHDC()
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                do {
                    let result = try Self.run(path, arguments: arguments)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    @discardableResult
    private static func run(_ path: String, arguments: [String], timeout: TimeInterval = defaultTimeout) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        var didTimeOut = false
        timer.setEventHandler {
            if process.isRunning {
                didTimeOut = true
                process.terminate()
            }
        }
        timer.resume()

        process.waitUntilExit()
        timer.cancel()

        // Read output safely - pipe might be closed if process was terminated
        let outputData: Data
        let errorData: Data
        do {
            outputData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
            errorData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
        } catch {
            // If reading fails (e.g., pipe closed), return timeout error
            if didTimeOut {
                throw MirrorError.commandFailed("hdc \(arguments.joined(separator: " ")) 超时，请检查设备网络或端口是否可达")
            }
            throw MirrorError.commandFailed("hdc \(arguments.joined(separator: " ")) 执行失败: \(error.localizedDescription)")
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        if didTimeOut {
            throw MirrorError.commandFailed("hdc \(arguments.joined(separator: " ")) 超时，请检查设备网络或端口是否可达")
        }

        if output.contains("[Fail]") || errorOutput.contains("[Fail]") {
            throw MirrorError.commandFailed("hdc \(arguments.joined(separator: " ")): \(errorOutput.isEmpty ? output : errorOutput)")
        }

        if process.terminationStatus != 0 {
            if !output.contains("No Error") && !errorOutput.contains("No Error") {
                throw MirrorError.commandFailed("hdc \(arguments.joined(separator: " ")): \(errorOutput.isEmpty ? output : errorOutput)")
            }
        }
        return output
    }
}
