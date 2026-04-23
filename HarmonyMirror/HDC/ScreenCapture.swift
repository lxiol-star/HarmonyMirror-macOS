import Foundation
import AppKit

@MainActor
final class ScreenCapture: ObservableObject {
    @Published private(set) var currentFrame: NSImage?
    @Published private(set) var fps: Int = 0
    @Published private(set) var screenWidth: Int = 0
    @Published private(set) var screenHeight: Int = 0

    private let hdcCommand: HDCCommand
    private let serial: String
    private var captureTask: Task<Void, Never>?
    private var frameCount = 0
    private var fpsTimer: Timer?

    init(hdcCommand: HDCCommand, serial: String) {
        self.hdcCommand = hdcCommand
        self.serial = serial
    }

    func start() {
        guard captureTask == nil else { return }
        startFPSCounter()
        captureTask = Task { [weak self] in
            guard let self else { return }
            await self.captureLoop()
        }
    }

    func stop() {
        captureTask?.cancel()
        captureTask = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        fps = 0
    }

    private func captureLoop() async {
        while !Task.isCancelled {
            do {
                let localPath = try await hdcCommand.snapshot(serial: serial)
                guard let image = NSImage(contentsOfFile: localPath) else { continue }
                let w = Int(image.representations.first?.pixelsWide ?? 0)
                let h = Int(image.representations.first?.pixelsHigh ?? 0)
                await MainActor.run {
                    self.currentFrame = image
                    self.frameCount += 1
                    if w > 0 && h > 0 {
                        self.screenWidth = w
                        self.screenHeight = h
                    }
                }
                try? FileManager.default.removeItem(atPath: localPath)
            } catch {
                if !Task.isCancelled {
                    Log.capture.error("Capture error: \(error.localizedDescription)")
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
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
