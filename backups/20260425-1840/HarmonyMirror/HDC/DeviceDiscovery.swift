import Foundation
import Combine
import Darwin

@MainActor
final class DeviceDiscovery: ObservableObject {
    @Published private(set) var devices: [HarmonyDevice] = []
    @Published private(set) var isScanningLAN = false
    @Published private(set) var discoveryStatus = ""
    let hdcCommand: HDCCommand
    private var pollTask: Task<Void, Never>?
    private var lastLANScan = Date.distantPast
    private var deviceProfiles: [String: DeviceProfile] = [:]
    private var failedLANTargets: [String: Date] = [:]

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
            let targets = try await hdcCommand.listTargetDetails()
            await updateDevices(from: targets.filter(\.isConnected))

            if shouldScanLAN {
                await discoverLANDevices()
                let refreshedTargets = try await hdcCommand.listTargetDetails()
                await updateDevices(from: refreshedTargets.filter(\.isConnected))
            }
        } catch {
            Log.hdc.error("Device poll failed: \(error.localizedDescription)")
        }
    }

    private func updateDevices(from connectedTargets: [HDCTarget]) async {
        var newDevices: [HarmonyDevice] = []

        for target in connectedTargets {
            let profile = await profile(for: target.serial)
            var device = HarmonyDevice(
                id: target.serial,
                serial: target.serial,
                name: "HarmonyOS Device",
                connectionKind: target.connectionKind,
                formFactor: profile.formFactor,
                model: profile.displayModel,
                endpoint: target.endpoint
            )
            if device.formFactor == .unknown {
                device.formFactor = HarmonyDevice.inferFormFactor(model: profile.displayModel, serial: target.serial)
            }
            newDevices.append(device)
        }

        if newDevices != devices {
            devices = newDevices
        }
    }

    private var shouldScanLAN: Bool {
        Date().timeIntervalSince(lastLANScan) >= AppConstants.lanDiscoveryInterval
    }

    private func profile(for serial: String) async -> DeviceProfile {
        if let cached = deviceProfiles[serial] {
            return cached
        }
        let profile = await hdcCommand.deviceProfile(serial: serial)
        deviceProfiles[serial] = profile
        return profile
    }

    private func discoverLANDevices() async {
        guard !isScanningLAN else { return }
        lastLANScan = Date()
        isScanningLAN = true
        discoveryStatus = "正在扫描局域网设备..."
        defer { isScanningLAN = false }

        let connected = (try? await hdcCommand.listTargetDetails())
            .map { Set($0.filter(\.isConnected).map(\.serial)) } ?? []
        let candidates = Self.lanCandidates()
        guard !candidates.isEmpty else {
            discoveryStatus = "未找到可扫描的局域网网卡"
            return
        }

        let hosts = await Self.scanHosts(candidates)
        guard !hosts.isEmpty else {
            discoveryStatus = connected.contains { $0.contains(":") } ? "已连接无线设备，局域网扫描完成" : "局域网未发现无线调试端口"
            return
        }

        var connectedCount = 0
        var alreadyConnectedCount = 0
        for host in hosts {
            let target = HDCCommand.wifiTarget(from: host)
            if connected.contains(target) {
                alreadyConnectedCount += 1
                continue
            }
            if let failedAt = failedLANTargets[target],
               Date().timeIntervalSince(failedAt) < 60 {
                continue
            }
            do {
                _ = try await hdcCommand.connectWiFi(host: host)
                failedLANTargets[target] = nil
                connectedCount += 1
            } catch {
                failedLANTargets[target] = Date()
                Log.hdc.error("LAN target connect failed \(target): \(error.localizedDescription)")
            }
        }

        if connectedCount > 0 {
            discoveryStatus = "已自动连接 \(connectedCount) 个局域网设备"
        } else if alreadyConnectedCount == hosts.count {
            discoveryStatus = "已发现 \(hosts.count) 个局域网设备"
        } else {
            discoveryStatus = "发现 \(hosts.count) 个无线调试端口，等待 hdc 连接"
        }
    }

    private nonisolated static func scanHosts(_ hosts: [String]) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            var iterator = hosts.makeIterator()
            var active = 0
            var found: [String] = []

            func enqueueNext() {
                guard let host = iterator.next() else { return }
                active += 1
                group.addTask {
                    isPortOpen(host: host, port: AppConstants.wifiDebugPort, timeout: AppConstants.lanDiscoveryTimeout) ? host : nil
                }
            }

            for _ in 0..<AppConstants.lanDiscoveryConcurrency {
                enqueueNext()
            }

            while active > 0, let result = await group.next() {
                active -= 1
                if let host = result {
                    found.append(host)
                }
                enqueueNext()
            }
            return found.sorted()
        }
    }

    private nonisolated static func lanCandidates() -> [String] {
        let localAddresses = localIPv4Addresses()
        var candidates = Set<String>()
        for address in localAddresses {
            let parts = address.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            for host in 1...254 {
                let candidate = "\(prefix).\(host)"
                if candidate != address {
                    candidates.insert(candidate)
                }
            }
        }
        return candidates.sorted()
    }

    private nonisolated static func localIPv4Addresses() -> [String] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var addresses: [String] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while ptr != nil {
            guard let interface = ptr?.pointee else { break }
            defer { ptr = interface.ifa_next }

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(cString: host)
            if !address.hasPrefix("169.254.") {
                addresses.append(address)
            }
        }
        return Array(Set(addresses))
    }

    private nonisolated static func isPortOpen(host: String, port: Int, timeout: TimeInterval) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 {
            return true
        }
        guard errno == EINPROGRESS else { return false }

        var pollInfo = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let selected = Darwin.poll(&pollInfo, 1, Int32(timeout * 1_000))
        guard selected > 0, pollInfo.revents & Int16(POLLOUT) != 0 else { return false }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let optionResult = getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
        return optionResult == 0 && socketError == 0
    }
}
