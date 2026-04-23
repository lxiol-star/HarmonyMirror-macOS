import Foundation
import Combine
import AppKit

@MainActor
final class MirrorService: ObservableObject {
    @Published private(set) var state: MirrorState = .idle
    @Published private(set) var currentFrame: NSImage?
    @Published private(set) var fps: Int = 0
    @Published private(set) var screenWidth: Int = 0
    @Published private(set) var screenHeight: Int = 0

    let hdcCommand: HDCCommand
    private var screenCapture: ScreenCapture?
    private(set) var inputInjector: InputInjector?
    private var cancellables = Set<AnyCancellable>()

    init(hdcCommand: HDCCommand) {
        self.hdcCommand = hdcCommand
    }

    func startMirroring(device: HarmonyDevice) async {
        state = .connecting
        let serial = device.serial

        let capture = ScreenCapture(hdcCommand: hdcCommand, serial: serial)
        self.screenCapture = capture

        let injector = InputInjector(hdcCommand: hdcCommand, serial: serial)
        self.inputInjector = injector

        capture.$currentFrame
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentFrame)
        capture.$fps
            .receive(on: DispatchQueue.main)
            .assign(to: &$fps)
        capture.$screenWidth
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak injector] w in
                self?.screenWidth = w
                injector?.screenWidth = w
            }
            .store(in: &cancellables)
        capture.$screenHeight
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak injector] h in
                self?.screenHeight = h
                injector?.screenHeight = h
            }
            .store(in: &cancellables)

        capture.start()
        state = .connected
        Log.mirror.info("Mirroring started for \(serial)")
    }

    func stopMirroring() {
        screenCapture?.stop()
        screenCapture = nil
        inputInjector = nil
        cancellables.removeAll()
        currentFrame = nil
        fps = 0
        screenWidth = 0
        screenHeight = 0
        state = .idle
        Log.mirror.info("Mirroring stopped")
    }
}
