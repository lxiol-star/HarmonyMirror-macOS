import Foundation

enum AppConstants {
    static let hdcPaths = [
        "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc",
        "/usr/local/bin/hdc",
        "/opt/homebrew/bin/hdc"
    ]
    static let devicePollingInterval: TimeInterval = 2.0
    static let remoteScreenPath = "/data/local/tmp/screen.jpeg"
    static let captureTargetFPS = 12
}
