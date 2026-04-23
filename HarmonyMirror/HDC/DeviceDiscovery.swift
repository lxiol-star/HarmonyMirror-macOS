import Foundation
import Combine

@MainActor
final class DeviceDiscovery: ObservableObject {
    @Published private(set) var devices: [HarmonyDevice] = []
    let hdcCommand: HDCCommand
    private var pollTask: Task<Void, Never>?

    init(hdcCommand: HDCCommand) {
        self.hdcCommand = hdcCommand
    }

    func startScanning() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(AppConstants.devicePollingInterval))
            }
        }
    }

    func stopScanning() {
        pollTask?.cancel()
        pollTask = nil
    }

    func poll() async {
        do {
            let serials = try await hdcCommand.listTargets()
            let newDevices = serials.map { serial in
                HarmonyDevice(id: serial, serial: serial)
            }
            if newDevices.map(\.serial) != devices.map(\.serial) {
                devices = newDevices
            }
        } catch {
            Log.hdc.error("Device poll failed: \(error.localizedDescription)")
        }
    }
}
