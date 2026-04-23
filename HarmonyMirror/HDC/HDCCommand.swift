import Foundation

final class HDCCommand {
    let hdcPath: String?

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
        // Check user home caches
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
        let output = try await execute(["list", "targets"])
        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "[Empty]" }
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
    private static func run(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 && !output.contains("No Error") {
            throw MirrorError.commandFailed("hdc \(arguments.joined(separator: " ")): \(output)")
        }
        return output
    }
}
