import Foundation
import AppKit

@MainActor
final class ScreenCapture: ObservableObject {
    @Published private(set) var currentFrame: NSImage?
    @Published private(set) var fps: Int = 0
    @Published private(set) var screenWidth: Int = 0
    @Published private(set) var screenHeight: Int = 0
    @Published private(set) var deviceWidth: Int = 0
    @Published private(set) var deviceHeight: Int = 0

    private let hdcCommand: HDCCommand
    private let serial: String
    private var captureTask: Task<Void, Never>?
    private var frameCount = 0
    private var fpsTimer: Timer?
    private let captureWidth = 658
    private let captureHeight = 1416

    init(hdcCommand: HDCCommand, serial: String) {
        self.hdcCommand = hdcCommand
        self.serial = serial
    }

    func start() {
        guard captureTask == nil else { return }
        startFPSCounter()
        let hdc = hdcCommand
        let ser = serial
        let w = captureWidth
        let h = captureHeight
        captureTask = Task.detached { [weak self] in
            await Self.captureLoop(self: self, hdc: hdc, serial: ser, width: w, height: h)
        }
    }

    func stop() {
        captureTask?.cancel()
        captureTask = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        fps = 0
    }

    private static func captureLoop(self ref: ScreenCapture?, hdc: HDCCommand, serial: String, width: Int, height: Int) async {
        let pid = ProcessInfo.processInfo.processIdentifier
        let localPath = NSTemporaryDirectory() + "hm_screen_\(pid).jpeg"
        let remotePath = AppConstants.remoteScreenPath
        var gotDeviceRes = false

        while !Task.isCancelled {
            do {
                let output = try await hdc.shell(
                    "snapshot_display -w \(width) -h \(height) -f \(remotePath)",
                    serial: serial
                )

                if !gotDeviceRes, let (dw, dh) = Self.parseActualResolution(output) {
                    gotDeviceRes = true
                    await MainActor.run {
                        ref?.deviceWidth = dw
                        ref?.deviceHeight = dh
                    }
                }

                try await hdc.fileRecv(remote: remotePath, local: localPath, serial: serial)

                guard let data = try? Data(contentsOf: URL(fileURLWithPath: localPath)),
                      let image = NSImage(data: data) else { continue }

                let pw = Int(image.representations.first?.pixelsWide ?? 0)
                let ph = Int(image.representations.first?.pixelsHigh ?? 0)

                await MainActor.run {
                    guard let self = ref else { return }
                    self.currentFrame = image
                    self.frameCount += 1
                    if pw > 0 && ph > 0 {
                        self.screenWidth = pw
                        self.screenHeight = ph
                    }
                }
            } catch {
                if !Task.isCancelled {
                    Log.capture.error("Capture error: \(error.localizedDescription)")
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
        try? FileManager.default.removeItem(atPath: localPath)
    }

    private static func parseActualResolution(_ output: String) -> (Int, Int)? {
        // Parse "process: display 0, file type: jpeg, width: 1316, height: 2832"
        guard let wRange = output.range(of: "width: "),
              let hRange = output.range(of: "height: ") else { return nil }
        let afterW = output[wRange.upperBound...]
        let afterH = output[hRange.upperBound...]
        guard let w = Int(afterW.prefix(while: { $0.isNumber })),
              let h = Int(afterH.prefix(while: { $0.isNumber })) else { return nil }
        return (w, h)
    }

    private func startFPSCounter() {
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.fps = self.frameCount
                self.frameCount = 0
            }
        }
    }
}
