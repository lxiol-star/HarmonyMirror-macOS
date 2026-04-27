import OSLog

enum Log {
    static let hdc = Logger(subsystem: "com.harmonymirror", category: "HDC")
    static let capture = Logger(subsystem: "com.harmonymirror", category: "Capture")
    static let input = Logger(subsystem: "com.harmonymirror", category: "Input")
    static let mirror = Logger(subsystem: "com.harmonymirror", category: "Mirror")
    static let ui = Logger(subsystem: "com.harmonymirror", category: "UI")
}
