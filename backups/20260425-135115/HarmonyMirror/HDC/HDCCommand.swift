import Foundation

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
        let output = try await execute(["list", "targets", "-v"])
        let targets = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "[Empty]" }
            .compactMap { line -> String? in
                let columns = line.components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                guard let target = columns.first else { return nil }
                if columns.count >= 3 {
                    return columns[2] == "Connected" ? target : nil
                }
                return target
            }
        if !targets.isEmpty {
            return targets
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

    func connectWiFi(host: String, port: Int = AppConstants.wifiDebugPort) async throws -> String {
        let target = Self.wifiTarget(from: host, defaultPort: port)
        _ = try? await execute(["tconn", target, "-remove"])
        do {
            let output = try await execute(["tconn", target])
            try await validateTarget(target)
            return output
        } catch {
            _ = try? await execute(["kill", "-r"])
            _ = try? await execute(["tconn", target, "-remove"])
            let output = try await execute(["tconn", target])
            try await validateTarget(target)
            return output
        }
    }

    func disconnectWiFi(host: String, port: Int = AppConstants.wifiDebugPort) async throws -> String {
        try await execute(["tconn", Self.wifiTarget(from: host, defaultPort: port), "-remove"])
    }

    func enableWiFiDebug(serial: String, port: Int = AppConstants.wifiDebugPort) async throws -> String {
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

    static func wifiTarget(from input: String, defaultPort: Int = AppConstants.wifiDebugPort) -> String {
        var target = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let firstToken = target.components(separatedBy: .whitespacesAndNewlines).first {
            target = firstToken
        }
        target = target
            .replacingOccurrences(of: "hdc://", with: "")
            .replacingOccurrences(of: "tcp://", with: "")
        if target.hasPrefix("[") {
            return target.contains("]:") ? target : "\(target):\(defaultPort)"
        }
        return target.contains(":") ? target : "\(target):\(defaultPort)"
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

        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
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
