import Foundation
import Network

struct NetworkDiagnosticSummary: Equatable {
    var localIPs: [String]
    var defaultGateway: String?
    var target: String?
    var tcpReachable: Bool?
    var advice: String

    var displayText: String {
        var parts: [String] = []
        parts.append("Mac IP: \(localIPs.isEmpty ? "未检测到" : localIPs.joined(separator: ", "))")
        if let defaultGateway, !defaultGateway.isEmpty {
            parts.append("网关: \(defaultGateway)")
        }
        if let target {
            if let tcpReachable {
                parts.append("\(target): \(tcpReachable ? "端口可达" : "端口不可达")")
            } else {
                parts.append("\(target): 未探测")
            }
        }
        parts.append(advice)
        return parts.joined(separator: "；")
    }
}

enum NetworkDiagnostics {
    static func run(targetInput: String) async -> NetworkDiagnosticSummary {
        async let ips = localIPv4Addresses()
        async let gateway = defaultGateway()
        let target = HDCCommand.wifiTarget(from: targetInput)
        let endpoint = parseEndpoint(target)
        let reachable: Bool?
        if let endpoint {
            reachable = await tcpProbe(host: endpoint.host, port: endpoint.port)
        } else {
            reachable = nil
        }

        let localIPs = await ips
        let defaultGateway = await gateway
        return NetworkDiagnosticSummary(
            localIPs: localIPs,
            defaultGateway: defaultGateway,
            target: targetInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : target,
            tcpReachable: reachable,
            advice: advice(localIPs: localIPs, target: endpoint, reachable: reachable)
        )
    }

    private static func parseEndpoint(_ target: String) -> (host: String, port: Int)? {
        let pieces = target.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2,
              let port = Int(pieces[1]),
              (0...65_535).contains(port),
              !pieces[0].isEmpty else { return nil }
        return (pieces[0], port)
    }

    private static func advice(localIPs: [String], target: (host: String, port: Int)?, reachable: Bool?) -> String {
        guard let target else {
            return "请输入设备 IP 后可探测无线调试端口"
        }
        if reachable == true {
            return "网络可达，若连接仍失败请刷新设备列表或重启 hdc"
        }
        let sameSubnet = localIPs.contains { sameClassCSubnet($0, target.host) }
        if sameSubnet {
            return "同网段但端口不可达，请确认设备无线调试已开启且端口正确"
        }
        return "Mac 与设备可能不在同一网段，可尝试手机热点或关闭路由器客户端隔离"
    }

    private static func sameClassCSubnet(_ left: String, _ right: String) -> Bool {
        let l = left.split(separator: ".")
        let r = right.split(separator: ".")
        guard l.count == 4, r.count == 4 else { return false }
        return l.prefix(3).elementsEqual(r.prefix(3))
    }

    private static func tcpProbe(host: String, port: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                continuation.resume(returning: false)
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let queue = DispatchQueue(label: "com.harmonymirror.network-diagnostics")
            let probeState = NetworkProbeState()

            let finish: @Sendable (Bool) -> Void = { result in
                probeState.finish(result, connection: connection, continuation: continuation)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) {
                finish(false)
            }
        }
    }

    private static func localIPv4Addresses() async -> [String] {
        let output = (try? await runProcess("/sbin/ifconfig", arguments: [])) ?? ""
        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("inet ") && !$0.contains("127.0.0.1") }
            .compactMap { line in
                line.split(separator: " ").dropFirst().first.map(String.init)
            }
    }

    private static func defaultGateway() async -> String? {
        let output = (try? await runProcess("/sbin/route", arguments: ["-n", "get", "default"])) ?? ""
        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("gateway:") }?
            .replacingOccurrences(of: "gateway:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runProcess(_ path: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private final class NetworkProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func finish(_ result: Bool, connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        connection.cancel()
        continuation.resume(returning: result)
    }
}
