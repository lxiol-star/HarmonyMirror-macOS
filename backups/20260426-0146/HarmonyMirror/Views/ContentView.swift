import SwiftUI

struct ContentView: View {
    @StateObject private var service: MirrorService
    @StateObject private var discovery: DeviceDiscovery

    init() {
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
    }
}
