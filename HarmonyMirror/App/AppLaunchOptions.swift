import Foundation

struct AppLaunchOptions {
    var connectSerial: String?
    var connectFirst = false
    var exitAfterSeconds: TimeInterval?

    var shouldAutoConnect: Bool {
        connectSerial != nil || connectFirst
    }

    static func current(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppLaunchOptions {
        var options = AppLaunchOptions()
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--connect":
                if index + 1 < arguments.count {
                    options.connectSerial = arguments[index + 1]
                    index += 1
                }
            case "--connect-first":
                options.connectFirst = true
            case "--exit-after":
                if index + 1 < arguments.count,
                   let seconds = TimeInterval(arguments[index + 1]) {
                    options.exitAfterSeconds = seconds
                    index += 1
                }
            default:
                break
            }
            index += 1
        }

        return options
    }
}
