import Foundation

enum AppConstants {
    static let hdcPaths = [
        "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
        "/Applications/DevEco_Testing_for_App.app/Contents/Resources/app/resources/bin/hdc",
        "/usr/local/bin/hdc",
        "/opt/homebrew/bin/hdc"
    ]
    static let devicePollingInterval: TimeInterval = 2.0
    static let remoteScreenPath = "/data/local/tmp/screen.jpeg"
    static let captureTargetFPS = 12
    static let projectRoot: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }()
    static let castingWebSocketPort: UInt16 = 9523
    static let castingRemoteHost = "127.0.0.1"
    static let castingRemotePort = "8710"
    static let agentRemotePort = 8711
    static let wifiDebugPorts = [10178, 37669, 40115, 43101, 35101, 37101, 39101, 41101]
    static let lanDiscoveryInterval: TimeInterval = 12.0
    static let lanDiscoveryTimeout: TimeInterval = 0.45
    static let lanDiscoveryConcurrency = 48
}
