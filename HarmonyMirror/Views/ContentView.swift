import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var service: MirrorService
    @StateObject private var discovery: DeviceDiscovery
    private let launchOptions: AppLaunchOptions
    @State private var didHandleLaunchOptions = false

    init(launchOptions: AppLaunchOptions = .current()) {
        self.launchOptions = launchOptions
        let hdc = HDCCommand()
        _service = StateObject(wrappedValue: MirrorService(hdcCommand: hdc))
        _discovery = StateObject(wrappedValue: DeviceDiscovery(hdcCommand: hdc))
    }

    var body: some View {
        Group {
            switch service.state {
            case .connected, .connecting:
                MirrorWindow(service: service)
            default:
                DeviceListView(discovery: discovery) { device in
                    Task { await service.startMirroring(device: device) }
                }
            }
        }
        .onAppear {
            discovery.startScanning()
            handleLaunchOptionsIfNeeded()
        }
        .onChange(of: discovery.devices) {
            handleLaunchOptionsIfNeeded()
        }
        .onDisappear {
            discovery.stopScanning()
        }
        .background(AppWindowVisibilityAccessor())
    }

    private func handleLaunchOptionsIfNeeded() {
        guard launchOptions.shouldAutoConnect, !didHandleLaunchOptions else { return }
        didHandleLaunchOptions = true

        Task {
            Log.ui.info("Handling launch auto-connect options")
            await discovery.poll()

            var selectedDevice: HarmonyDevice?
            if let serial = launchOptions.connectSerial {
                selectedDevice = discovery.devices.first { device in
                    device.serial == serial
                        || device.serial.hasPrefix(serial + ":")
                        || device.serial.contains(serial)
                }
            }
            if selectedDevice == nil {
                selectedDevice = discovery.devices.first { $0.connectionKind == .usb }
                    ?? discovery.devices.first { $0.formFactor == .tablet }
                    ?? discovery.devices.first
            }

            guard let device = selectedDevice else {
                Log.ui.error("Launch auto-connect found no available device")
                didHandleLaunchOptions = false
                return
            }

            Log.ui.info("Launch auto-connect selected \(device.serial)")
            await service.startMirroring(device: device)

            if let seconds = launchOptions.exitAfterSeconds {
                try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
                NSApp.terminate(nil)
            }
        }
    }
}

private struct AppWindowVisibilityAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        scheduleRecovery(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        scheduleRecovery(for: nsView)
    }

    private func scheduleRecovery(for view: NSView) {
        for delay in [0.0, 0.25, 0.75, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let window = view.window else { return }
                AppWindowVisibility.recover(window)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
