import SwiftUI

struct DeviceListView: View {
    @ObservedObject var discovery: DeviceDiscovery
    let onConnect: (HarmonyDevice) -> Void
    @State private var wifiHost = ""
    @State private var wifiStatus = ""
    @State private var isWiFiBusy = false
    @State private var isDiagnosingNetwork = false
    @State private var networkDiagnosticText = ""
    @State private var didAutoRecoverWiFi = false
    @State private var cleaningAgentSerials: Set<String> = []
    @State private var agentCleanupStatus = ""

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
                    TextField("设备 IP 或 IP:端口", text: $wifiHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task { await connectWiFi() }
                        }

                    Button {
                        Task { await connectWiFi() }
                    } label: {
                        Label(isWiFiBusy ? "连接中..." : "连接 Wi-Fi", systemImage: "wifi")
                    }
                    .disabled(isWiFiBusy || wifiHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .layoutPriority(1)

                    Button {
                        Task { await diagnoseNetwork() }
                    } label: {
                        Image(systemName: "network")
                    }
                    .disabled(isDiagnosingNetwork)
                    .help("网络诊断")
                }

                HStack(spacing: 8) {
                    Spacer()
                    Button {
                        Task { await enableWiFiDebug() }
                    } label: {
                        Label(isWiFiBusy ? "处理中..." : "开启无线调试", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .controlSize(.small)
                    .disabled(isWiFiBusy || usbDevice == nil)
                }

                if !wifiStatus.isEmpty {
                    Text(wifiStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !networkDiagnosticText.isEmpty {
                    Text(networkDiagnosticText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                if !agentCleanupStatus.isEmpty {
                    Text(agentCleanupStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if !discovery.discoveryStatus.isEmpty {
                    HStack(spacing: 6) {
                        if discovery.isScanningLAN {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(discovery.discoveryStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
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
            } else if discovery.deviceGroups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "display.trianglebadge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("未发现设备")
                        .font(.headline)
                    Text("请通过 USB 连接鸿蒙手机或平板，或保持设备与 Mac 在同一局域网并开启无线调试")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(discovery.deviceGroups) { group in
                            DeviceCard(
                                group: group,
                                onConnect: { device in
                                    onConnect(device)
                                },
                                onCleanupAgent: { device in
                                    Task { await cleanupAgent(on: device) }
                                },
                                cleaningSerials: cleaningAgentSerials
                            )
                        }
                    }
                    .padding(.horizontal)
                }
            }
            Spacer()
        }
        .frame(minWidth: 390, minHeight: 430)
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

        // Validate IP format before attempting connection
        let normalizedTarget = HDCCommand.wifiTarget(from: host)
        let ipPart = normalizedTarget.components(separatedBy: ":").first ?? normalizedTarget

        // Basic IPv4 validation
        let ipComponents = ipPart.components(separatedBy: ".")
        if ipComponents.count != 4 || !ipComponents.allSatisfy({ Int($0) != nil && (0...255).contains(Int($0)!) }) {
            wifiStatus = "无效的 IP 地址格式: \(ipPart)"
            return
        }

        isWiFiBusy = true
        wifiStatus = "\(reason ?? "正在连接") \(normalizedTarget) ..."
        defer { isWiFiBusy = false }
        do {
            let result = try await discovery.hdcCommand.connectWiFi(host: host)
            wifiStatus = result.isEmpty ? "Wi-Fi 连接成功" : result
            discovery.rememberWiFiTarget(host)
            await discovery.poll()
        } catch {
            let errorMsg = error.localizedDescription
            if errorMsg.contains("IP address incorrect") {
                wifiStatus = "IP 地址格式错误，请检查输入"
            } else if errorMsg.contains("timeout") || errorMsg.contains("超时") {
                wifiStatus = "连接超时，请确保设备与 Mac 在同一网络"
            } else if errorMsg.contains("refused") || errorMsg.contains("拒绝") {
                wifiStatus = "连接被拒绝，请确保设备已开启无线调试"
            } else {
                wifiStatus = "Wi-Fi 连接失败：\(errorMsg)"
            }
        }
    }

    private func enableWiFiDebug() async {
        guard let device = usbDevice, !isWiFiBusy else { return }
        isWiFiBusy = true
        wifiStatus = "正在为 \(device.serial) 开启无线调试端口 \(AppConstants.wifiDebugPorts.first ?? 10178) ..."
        defer { isWiFiBusy = false }
        do {
            let result = try await discovery.hdcCommand.enableWiFiDebug(serial: device.serial)
            if let ip = await readDeviceWiFiAddress(serial: device.serial), !ip.isEmpty {
                wifiHost = ip
                wifiStatus = "已开启无线调试端口 \(AppConstants.wifiDebugPorts.first ?? 10178)，设备 IP：\(ip)"
            } else {
                wifiStatus = result.isEmpty ? "已开启无线调试端口 \(AppConstants.wifiDebugPorts.first ?? 10178)" : result
            }
        } catch {
            wifiStatus = "开启无线调试失败：\(error.localizedDescription)"
        }
    }

    private func diagnoseNetwork() async {
        guard !isDiagnosingNetwork else { return }
        isDiagnosingNetwork = true
        networkDiagnosticText = "正在诊断网络..."
        defer { isDiagnosingNetwork = false }
        let result = await NetworkDiagnostics.run(targetInput: wifiHost)
        networkDiagnosticText = result.displayText
    }

    private func cleanupAgent(on device: HarmonyDevice) async {
        guard !cleaningAgentSerials.contains(device.serial) else { return }
        cleaningAgentSerials.insert(device.serial)
        agentCleanupStatus = "正在清理 \(device.displayName) 的移动端 Agent..."
        defer { cleaningAgentSerials.remove(device.serial) }

        do {
            let result = try await discovery.hdcCommand.cleanupHarmonyAgent(serial: device.serial)
            agentCleanupStatus = "\(device.displayName)：\(result)"
            await discovery.poll()
        } catch {
            agentCleanupStatus = "\(device.displayName)：清理失败，\(error.localizedDescription)"
        }
    }

    private var usbDevice: HarmonyDevice? {
        discovery.devices.first { $0.connectionKind == .usb || !$0.serial.contains(":") }
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
