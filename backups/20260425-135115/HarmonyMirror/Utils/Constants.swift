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
    static let wifiDebugPort = 10178
}
