import SwiftUI

struct DeviceListView: View {
    @ObservedObject var discovery: DeviceDiscovery
    let onConnect: (HarmonyDevice) -> Void
    @State private var wifiHost = ""
    @State private var wifiStatus = ""
    @State private var isWiFiBusy = false
    @State private var didAutoRecoverWiFi = false

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

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("手机 IP 或 IP:端口", text: $wifiHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160)
                        .onSubmit {
                            Task { await connectWiFi() }
                        }

                    Button {
                        Task { await connectWiFi() }
                    } label: {
                        Label(isWiFiBusy ? "连接中..." : "连接 Wi-Fi", systemImage: "wifi")
                    }
                    .disabled(isWiFiBusy || wifiHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        Task { await enableWiFiDebug() }
                    } label: {
                        Label(isWiFiBusy ? "处理中..." : "开启无线调试", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(isWiFiBusy || usbDevice == nil)
                }

                if !wifiStatus.isEmpty {
                    Text(wifiStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

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
        .onChange(of: discovery.devices) { _, devices in
            guard devices.isEmpty, !wifiHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                didAutoRecoverWiFi = false
                return
            }
            guard !didAutoRecoverWiFi, !isWiFiBusy else { return }
            didAutoRecoverWiFi = true
            Task { await connectWiFi(reason: "正在恢复 Wi-Fi 连接") }
        }
    }

    private func connectWiFi(reason: String? = nil) async {
        let host = wifiHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !isWiFiBusy else { return }
        isWiFiBusy = true
        wifiStatus = "\(reason ?? "正在连接") \(HDCCommand.wifiTarget(from: host)) ..."
        defer { isWiFiBusy = false }
        do {
            let result = try await discovery.hdcCommand.connectWiFi(host: host)
            wifiStatus = result.isEmpty ? "Wi-Fi 连接命令已发送" : result
            await discovery.poll()
        } catch {
            wifiStatus = "Wi-Fi 连接失败：\(error.localizedDescription)"
        }
    }

    private func enableWiFiDebug() async {
        guard let device = usbDevice, !isWiFiBusy else { return }
        isWiFiBusy = true
        wifiStatus = "正在为 \(device.serial) 开启无线调试端口 \(AppConstants.wifiDebugPort) ..."
        defer { isWiFiBusy = false }
        do {
            let result = try await discovery.hdcCommand.enableWiFiDebug(serial: device.serial)
            if let ip = await readDeviceWiFiAddress(serial: device.serial), !ip.isEmpty {
                wifiHost = ip
                wifiStatus = "已开启无线调试端口 \(AppConstants.wifiDebugPort)，手机 IP：\(ip)"
            } else {
                wifiStatus = result.isEmpty ? "已开启无线调试端口 \(AppConstants.wifiDebugPort)" : result
            }
        } catch {
            wifiStatus = "开启无线调试失败：\(error.localizedDescription)"
        }
    }

    private var usbDevice: HarmonyDevice? {
        discovery.devices.first { !$0.serial.contains(":") }
    }

    private func readDeviceWiFiAddress(serial: String) async -> String? {
        for _ in 0..<5 {
            if let ip = try? await discovery.hdcCommand.deviceWiFiAddress(serial: serial) {
                return ip
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }
}
