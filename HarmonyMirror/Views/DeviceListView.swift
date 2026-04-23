import SwiftUI

struct DeviceListView: View {
    @ObservedObject var discovery: DeviceDiscovery
    let onConnect: (HarmonyDevice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("鸿蒙设备")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: { Task { await discovery.poll() } }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
            }
            .padding()

            if discovery.hdcCommand.hdcPath == nil {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("未找到 hdc")
                        .font(.headline)
                    Text("请安装 DevEco Studio 或将 hdc 添加到 PATH")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
            } else if discovery.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("未发现设备")
                        .font(.headline)
                    Text("请通过 USB 连接鸿蒙手机并开启开发者模式")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(discovery.devices) { device in
                            DeviceCard(device: device) {
                                onConnect(device)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            Spacer()
        }
        .frame(minWidth: 350, minHeight: 400)
        .onAppear { discovery.startScanning() }
        .onDisappear { discovery.stopScanning() }
    }
}
