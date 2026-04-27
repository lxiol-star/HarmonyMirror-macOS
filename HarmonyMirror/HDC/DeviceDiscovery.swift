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
    private var profileFetchFailedAt: [String: Date] = [:]
    private var displaySizeCache: [String: CGSize] = [:]
    private var failedLANTargets: [String: Date] = [:]
    private var deviceMissCount: [String: Int] = [:]
    private let maxMissBeforeRemoval = 3
    private var knownWiFiTargets: [String] {
        get { UserDefaults.standard.stringArray(forKey: "HarmonyMirror_knownWiFiTargets") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "HarmonyMirror_knownWiFiTargets") }
    }

    /// Devices merged by physical identity — one card per physical device with USB/WiFi buttons
    var deviceGroups: [DeviceGroup] {
        var groups: [DeviceGroup] = []
        var matchedWiFi = Set<String>()

        let usbCount = devices.filter { !$0.serial.contains(":") }.count
        let wifiCount = devices.filter { $0.serial.contains(":") }.count

        for device in devices {
            let isWiFi = device.serial.contains(":")
            if isWiFi { continue }  // process WiFi after USB
            // USB device — try to find matching WiFi entry
            let wifiMatch = devices.first { candidate in
                guard candidate.serial.contains(":"), !matchedWiFi.contains(candidate.serial) else {
                    return false
                }
                // Only one USB and one WiFi — assume same device UNLESS
                // both have known but different hardware models
                if usbCount == 1, wifiCount == 1 {
                    if !candidate.hardwareModel.isEmpty, !device.hardwareModel.isEmpty,
                       candidate.hardwareModel != device.hardwareModel {
                        return false
                    }
                    return true
                }
                // Hardware model code match (most reliable, consistent across connection types)
                if !candidate.hardwareModel.isEmpty, !device.hardwareModel.isEmpty,
                   candidate.hardwareModel == device.hardwareModel {
                    return true
                }
                // Display model match
                if !candidate.model.isEmpty, !device.model.isEmpty, candidate.model == device.model {
                    return true
                }
                // Same display name
                if candidate.displayName == device.displayName {
                    return true
                }
                // Same form factor (both known)
                if candidate.formFactor != .unknown, device.formFactor != .unknown,
                   candidate.formFactor == device.formFactor {
                    return true
                }
                // Same screen resolution (if known)
                if candidate.screenWidth > 0, device.screenWidth > 0,
                   candidate.screenWidth == device.screenWidth,
                   candidate.screenHeight == device.screenHeight {
                    return true
                }
                return false
            }
            if let wifi = wifiMatch {
                matchedWiFi.insert(wifi.serial)
            }
            groups.append(DeviceGroup(
                id: device.id,
                displayName: device.displayName,
                formFactor: device.formFactor,
                model: device.model,
                screenWidth: max(device.screenWidth, wifiMatch?.screenWidth ?? 0),
                screenHeight: max(device.screenHeight, wifiMatch?.screenHeight ?? 0),
                usbDevice: device,
                wifiDevice: wifiMatch
            ))
        }
        // Fallback: if exactly one unmatched WiFi device remains, merge with an unmatched USB group
        let unmatchedWiFi = devices.filter { $0.serial.contains(":") && !matchedWiFi.contains($0.serial) }
        if unmatchedWiFi.count == 1 {
            let wifi = unmatchedWiFi[0]
            if let usbIdx = groups.firstIndex(where: { $0.wifiDevice == nil }) {
                var merged = groups[usbIdx]
                groups[usbIdx] = DeviceGroup(
                    id: merged.id,
                    displayName: merged.displayName.isEmpty || merged.displayName == "HarmonyOS Device" ? wifi.displayName : merged.displayName,
                    formFactor: merged.formFactor == .unknown ? wifi.formFactor : merged.formFactor,
                    model: merged.model.isEmpty ? wifi.model : merged.model,
                    screenWidth: max(merged.screenWidth, wifi.screenWidth),
                    screenHeight: max(merged.screenHeight, wifi.screenHeight),
                    usbDevice: merged.usbDevice,
                    wifiDevice: wifi
                )
                matchedWiFi.insert(wifi.serial)
            }
        }

        // Remaining WiFi-only devices (no USB match).
        // Merge WiFi entries that share the same hardwareModel — a device with
        // multiple IPs (e.g. 10.x and 192.168.x) is still one physical device.
        for device in devices where device.serial.contains(":") && !matchedWiFi.contains(device.serial) {
            if let existingIdx = groups.firstIndex(where: { group in
                if !device.hardwareModel.isEmpty, !group.hardwareModel.isEmpty,
                   device.hardwareModel == group.hardwareModel {
                    return true
                }
                if !device.model.isEmpty, !group.model.isEmpty, device.model == group.model {
                    return true
                }
                return false
            }) {
                // Merge into existing group — keep the WiFi with the shorter serial
                // (usually the primary IP) as the preferred WiFi device
                var existing = groups[existingIdx]
                if existing.wifiDevice == nil {
                    existing = DeviceGroup(
                        id: existing.id,
                        displayName: existing.displayName,
                        formFactor: existing.formFactor,
                        model: existing.model,
                        screenWidth: max(existing.screenWidth, device.screenWidth),
                        screenHeight: max(existing.screenHeight, device.screenHeight),
                        usbDevice: existing.usbDevice,
                        wifiDevice: device
                    )
                }
                groups[existingIdx] = existing
                matchedWiFi.insert(device.serial)
            } else {
                groups.append(DeviceGroup(
                    id: device.id,
                    displayName: device.displayName,
                    formFactor: device.formFactor,
                    model: device.model,
                    screenWidth: device.screenWidth,
                    screenHeight: device.screenHeight,
                    usbDevice: nil,
                    wifiDevice: device
                ))
            }
        }
        return groups
    }

    init(hdcCommand: HDCCommand) {
        self.hdcCommand = hdcCommand
    }

    func rememberWiFiTarget(_ target: String) {
        let normalized = HDCCommand.wifiTarget(from: target)
        if !knownWiFiTargets.contains(normalized) {
            knownWiFiTargets.append(normalized)
        }
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
            await updateDevices(from: targets.filter(\.isConnected), merge: false)

            // Auto-reconnect known WiFi devices if they disappeared
            let currentSerials = Set(devices.map(\.serial))
            let missingKnownTargets = knownWiFiTargets.filter { !currentSerials.contains($0) }
            if !missingKnownTargets.isEmpty {
                await reconnectKnownDevices(missingKnownTargets)
                let refreshedTargets = try await hdcCommand.listTargetDetails()
                await updateDevices(from: refreshedTargets.filter(\.isConnected), merge: true)
            }

            if shouldScanLAN {
                await discoverLANDevices()
                let refreshedTargets = try await hdcCommand.listTargetDetails()
                // Merge new WiFi targets with existing USB devices — don't overwrite
                await updateDevices(from: refreshedTargets.filter(\.isConnected), merge: true)
            }
        } catch {
            Log.hdc.error("Device poll failed: \(error.localizedDescription)")
        }
    }

    private func reconnectKnownDevices(_ targets: [String]) async {
        for target in targets {
            // Skip if recently failed
            if let failedAt = failedLANTargets[target],
               Date().timeIntervalSince(failedAt) < 30 {
                continue
            }

            do {
                _ = try await hdcCommand.connectWiFi(host: target)
                failedLANTargets[target] = nil
                Log.hdc.info("Auto-reconnected known device: \(target)")
            } catch {
                failedLANTargets[target] = Date()
                Log.hdc.error("Failed to reconnect \(target): \(error.localizedDescription)")
            }
        }
    }

    private func updateDevices(from connectedTargets: [HDCTarget], merge: Bool) async {
        // Profiles are cached, sequential lookup is fast
        var profiles: [(HDCTarget, DeviceProfile)] = []
        for target in connectedTargets {
            let profile = await self.profile(for: target.serial)
            profiles.append((target, profile))
        }

        // Fetch display sizes concurrently (each is an hdc shell call)
        let serials = connectedTargets.map(\.serial)
        let displaySizes = await fetchDisplaySizesConcurrently(serials: serials)

        var newDevices: [HarmonyDevice] = []
        for (target, profile) in profiles {
            var device = HarmonyDevice(
                id: target.serial,
                serial: target.serial,
                name: "HarmonyOS Device",
                connectionKind: target.connectionKind,
                formFactor: profile.formFactor,
                model: profile.displayModel,
                hardwareModel: profile.productModel,
                endpoint: target.endpoint
            )
            if let displaySize = displaySizes[target.serial] {
                let width = Int(displaySize.width)
                let height = Int(displaySize.height)
                if width > 0, height > 0 {
                    device.screenWidth = width
                    device.screenHeight = height
                }
            }
            if device.formFactor == .unknown {
                device.formFactor = HarmonyDevice.inferFormFactor(
                    model: profile.displayModel,
                    serial: target.serial,
                    width: device.screenWidth,
                    height: device.screenHeight
                )
            }
            newDevices.append(device)
        }

        // Cross-reference: unify profiles between USB and WiFi for the same device
        let usbDevices = newDevices.filter { !$0.serial.contains(":") }
        var wifiDevices = newDevices.filter { $0.serial.contains(":") }
        // Build profile data lookup: serial → DeviceProfile
        var profileBySerial: [String: DeviceProfile] = [:]
        for (target, profileData) in profiles {
            profileBySerial[target.serial] = profileData
        }

        for i in 0..<wifiDevices.count {
            let wifi = wifiDevices[i]
            let wifiProfile = profileBySerial[wifi.serial]
            // Find USB device with matching profile data (same productName, deviceType, or btName)
            let usbMatch = usbDevices.first { usb in
                let up = profileBySerial[usb.serial]
                // Same hardware model code (most reliable, consistent across connection types)
                if !wifi.hardwareModel.isEmpty, !usb.hardwareModel.isEmpty,
                   wifi.hardwareModel == usb.hardwareModel { return true }
                // Same product model from param get
                if let wp = wifiProfile, let u = up,
                   !wp.productModel.isEmpty, !u.productModel.isEmpty,
                   wp.productModel == u.productModel { return true }
                // Same device type
                if let wp = wifiProfile, let u = up,
                   !wp.deviceType.isEmpty, !u.deviceType.isEmpty,
                   wp.deviceType == u.deviceType { return true }
                // Same screen size (known for both)
                if usb.screenWidth > 0, wifi.screenWidth > 0,
                   usb.screenWidth == wifi.screenWidth,
                   usb.screenHeight == wifi.screenHeight { return true }
                // Same form factor (both known)
                if usb.formFactor != .unknown, wifi.formFactor != .unknown,
                   usb.formFactor == wifi.formFactor { return true }
                // Only one USB and one WiFi — assume same device UNLESS
                // both have known but different hardware models
                if usbDevices.count == 1 && wifiDevices.count == 1 {
                    if !wifi.hardwareModel.isEmpty, !usb.hardwareModel.isEmpty,
                       wifi.hardwareModel != usb.hardwareModel {
                        return false
                    }
                    return true
                }
                return false
            }
            guard let usb = usbMatch else { continue }

            // Pick the best display name across both connections.
            // Priority: userName (3) > productName (2) > productModel (1) > deviceType (0).
            // This ensures USB and WiFi show the same name for the same physical device.
            let usbProfile = profileBySerial[usb.serial]
            let wifiProf = profileBySerial[wifi.serial]
            let usbNamePrio = Self.displayNamePriority(model: usb.model, profile: usbProfile)
            let wifiNamePrio = Self.displayNamePriority(model: wifiDevices[i].model, profile: wifiProf)
            if usbNamePrio > wifiNamePrio {
                wifiDevices[i].model = usb.model
            } else if wifiNamePrio > usbNamePrio,
                      let usbIdx = newDevices.firstIndex(where: { $0.serial == usb.serial }) {
                newDevices[usbIdx].model = wifiDevices[i].model
            } else if usbNamePrio == wifiNamePrio, !usb.model.isEmpty, wifiDevices[i].model.isEmpty {
                wifiDevices[i].model = usb.model
            } else if usbNamePrio == wifiNamePrio, usb.model.isEmpty, !wifiDevices[i].model.isEmpty,
                      let usbIdx = newDevices.firstIndex(where: { $0.serial == usb.serial }) {
                newDevices[usbIdx].model = wifiDevices[i].model
            }
            if wifiDevices[i].hardwareModel.isEmpty, !usb.hardwareModel.isEmpty {
                wifiDevices[i].hardwareModel = usb.hardwareModel
            }
            if usb.hardwareModel.isEmpty, wifi.hardwareModel.isEmpty == false,
               let usbIdx = newDevices.firstIndex(where: { $0.serial == usb.serial }) {
                newDevices[usbIdx].hardwareModel = wifi.hardwareModel
            }
            if wifi.screenWidth == 0, usb.screenWidth > 0 {
                wifiDevices[i].screenWidth = usb.screenWidth
                wifiDevices[i].screenHeight = usb.screenHeight
            }
            if usb.screenWidth == 0, wifi.screenWidth > 0,
               let usbIdx = newDevices.firstIndex(where: { $0.serial == usb.serial }) {
                newDevices[usbIdx].screenWidth = wifi.screenWidth
                newDevices[usbIdx].screenHeight = wifi.screenHeight
            }
            if wifiDevices[i].formFactor == .unknown, usb.formFactor != .unknown {
                wifiDevices[i].formFactor = usb.formFactor
            }
            if usb.formFactor == .unknown, wifi.formFactor != .unknown,
               let usbIdx = newDevices.firstIndex(where: { $0.serial == usb.serial }) {
                newDevices[usbIdx].formFactor = wifi.formFactor
            }
        }
        // Write back updated WiFi devices
        for updated in wifiDevices {
            if let idx = newDevices.firstIndex(where: { $0.serial == updated.serial }) {
                newDevices[idx] = updated
            }
        }

        if merge {
            // Preserve existing USB devices that the refreshed scan missed (e.g. during WiFi discovery)
            let newSerials = Set(newDevices.map(\.serial))
            for existing in devices where !existing.serial.contains(":") && !newSerials.contains(existing.serial) {
                newDevices.append(existing)
            }
        }

        // Debounce: retain devices that disappeared in this poll but were recently seen.
        // This prevents USB devices from flickering when hdc list targets is intermittently slow.
        let newSerials = Set(newDevices.map(\.serial))
        for serial in newSerials {
            deviceMissCount[serial] = 0
        }
        var retained: [HarmonyDevice] = []
        for existing in devices where !newSerials.contains(existing.serial) {
            let misses = (deviceMissCount[existing.serial] ?? 0) + 1
            deviceMissCount[existing.serial] = misses
            if misses < maxMissBeforeRemoval {
                retained.append(existing)
            }
        }
        for serial in deviceMissCount.keys where (deviceMissCount[serial] ?? 0) >= maxMissBeforeRemoval {
            deviceMissCount.removeValue(forKey: serial)
        }
        newDevices.append(contentsOf: retained)

        if newDevices != devices {
            devices = newDevices
        }
    }

    private func fetchDisplaySizesConcurrently(serials: [String]) async -> [String: CGSize] {
        var results: [String: CGSize] = [:]
        var uncached: [String] = []
        for serial in serials {
            if let cached = displaySizeCache[serial] {
                results[serial] = cached
            } else {
                uncached.append(serial)
            }
        }
        guard !uncached.isEmpty else { return results }

        return await withTaskGroup(of: (String, CGSize?).self) { group in
            for serial in uncached {
                group.addTask {
                    let size = try? await self.hdcCommand.displaySize(serial: serial)
                    return (serial, size)
                }
            }
            for await (serial, size) in group {
                if let size {
                    results[serial] = size
                    displaySizeCache[serial] = size
                }
            }
            return results
        }
    }

    private var shouldScanLAN: Bool {
        // Disable LAN scanning - it's too resource intensive and causes UI lag
        // Users should manually connect via IP input instead
        return false
        // Original: Date().timeIntervalSince(lastLANScan) >= AppConstants.lanDiscoveryInterval
    }

    private func profile(for serial: String) async -> DeviceProfile {
        if let cached = deviceProfiles[serial] {
            return cached
        }
        // Cooldown: if a previous fetch failed, don't retry for 30 s.
        // Retrying on every poll overwhelms the USB shell channel.
        if let failedAt = profileFetchFailedAt[serial],
           Date().timeIntervalSince(failedAt) < 30 {
            return DeviceProfile()
        }
        let profile = await hdcCommand.deviceProfile(serial: serial)
        let gotData = !profile.productModel.isEmpty
            || !profile.productName.isEmpty
            || !profile.userName.isEmpty
        if gotData {
            deviceProfiles[serial] = profile
            profileFetchFailedAt.removeValue(forKey: serial)
        } else {
            profileFetchFailedAt[serial] = Date()
        }
        return profile
    }

    /// Returns the source priority of a display name for cross-connection comparison.
    /// Higher = better: userName (3) > productName (2) > productModel (1) > deviceType/other (0).
    private static func displayNamePriority(model: String, profile: DeviceProfile?) -> Int {
        guard !model.isEmpty, let profile else { return 0 }
        if !profile.userName.isEmpty, model == profile.userName { return 3 }
        if !profile.productName.isEmpty, model == profile.productName { return 2 }
        if !profile.productModel.isEmpty, model == profile.productModel { return 1 }
        return model.isEmpty ? 0 : 1
    }

    private func discoverLANDevices() async {
        guard !isScanningLAN else { return }
        lastLANScan = Date()
        isScanningLAN = true
        discoveryStatus = "正在扫描局域网设备..."
        defer { isScanningLAN = false }

        let connected = (try? await hdcCommand.listTargetDetails())
            .map { Set($0.filter(\.isConnected).map(\.serial)) } ?? []

        // 1. Try reconnecting to known Wi-Fi targets first
        var knownConnectedCount = 0
        let knownTargets = knownWiFiTargets
        for target in knownTargets {
            if connected.contains(target) { continue }
            if let failedAt = failedLANTargets[target],
               Date().timeIntervalSince(failedAt) < 60 {
                continue
            }
            do {
                _ = try await hdcCommand.connectWiFi(host: target)
                failedLANTargets[target] = nil
                knownConnectedCount += 1
            } catch {
                failedLANTargets[target] = Date()
            }
        }

        // 2. Scan local subnets on all known ports
        let candidates = Self.lanCandidates()
        guard !candidates.isEmpty else {
            discoveryStatus = knownConnectedCount > 0
                ? "已自动连接 \(knownConnectedCount) 个已知设备"
                : (connected.contains { $0.contains(":") } ? "已连接无线设备" : "未找到可扫描的局域网网卡")
            return
        }

        let hosts = await Self.scanHosts(candidates)
        guard !hosts.isEmpty else {
            discoveryStatus = knownConnectedCount > 0
                ? "已自动连接 \(knownConnectedCount) 个已知设备"
                : (connected.contains { $0.contains(":") } ? "已连接无线设备，局域网扫描完成" : "局域网未发现无线调试端口")
            return
        }

        var connectedCount = 0
        var alreadyConnectedCount = 0
        for host in hosts {
            for port in AppConstants.wifiDebugPorts {
                let target = HDCCommand.wifiTarget(from: host, defaultPort: port)
                if connected.contains(target) || alreadyConnectedCount > 0 {
                    alreadyConnectedCount += 1
                    break
                }
                if let failedAt = failedLANTargets[target],
                   Date().timeIntervalSince(failedAt) < 60 {
                    continue
                }
                do {
                    _ = try await hdcCommand.connectWiFi(host: target)
                    failedLANTargets[target] = nil
                    connectedCount += 1
                    // Remember successfully connected target
                    if !knownWiFiTargets.contains(target) {
                        knownWiFiTargets.append(target)
                    }
                    break
                } catch {
                    failedLANTargets[target] = Date()
                    Log.hdc.error("LAN target connect failed \(target): \(error.localizedDescription)")
                }
            }
        }

        let totalFound = connectedCount + knownConnectedCount
        if totalFound > 0 {
            discoveryStatus = "已自动连接 \(totalFound) 个局域网设备"
        } else if alreadyConnectedCount > 0 {
            discoveryStatus = "已发现 \(hosts.count) 个局域网设备"
        } else {
            discoveryStatus = "发现 \(hosts.count) 个无线调试端口，等待 hdc 连接"
        }
    }

    private nonisolated static func scanHosts(_ hosts: [String]) async -> [String] {
        let hostPortPairs = hosts.flatMap { host in
            AppConstants.wifiDebugPorts.map { port in (host, port) }
        }
        return await withTaskGroup(of: String?.self) { group in
            var iterator = hostPortPairs.makeIterator()
            var active = 0
            var found: Set<String> = []

            func enqueueNext() {
                guard let (host, port) = iterator.next() else { return }
                active += 1
                group.addTask {
                    isPortOpen(host: host, port: port, timeout: AppConstants.lanDiscoveryTimeout) ? host : nil
                }
            }

            for _ in 0..<AppConstants.lanDiscoveryConcurrency {
                enqueueNext()
            }

            while active > 0, let result = await group.next() {
                active -= 1
                if let host = result {
                    found.insert(host)
                }
                enqueueNext()
            }
            return Array(found).sorted()
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
