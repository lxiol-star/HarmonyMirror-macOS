import Foundation

final class InputInjector {
    private let hdcCommand: HDCCommand
    private let serial: String
    var screenWidth: Int = 1080
    var screenHeight: Int = 1920

    init(hdcCommand: HDCCommand, serial: String) {
        self.hdcCommand = hdcCommand
        self.serial = serial
    }

    func click(windowPoint: CGPoint, windowSize: CGSize) {
        guard let dp = mapToDevice(windowPoint: windowPoint, windowSize: windowSize) else { return }
        Task {
            try? await hdcCommand.inputClick(x: dp.x, y: dp.y, serial: serial)
        }
    }

    func swipe(from start: CGPoint, to end: CGPoint, windowSize: CGSize) {
        guard let sp = mapToDevice(windowPoint: start, windowSize: windowSize),
              let ep = mapToDevice(windowPoint: end, windowSize: windowSize) else { return }
        Task {
            try? await hdcCommand.inputSwipe(x1: sp.x, y1: sp.y, x2: ep.x, y2: ep.y, serial: serial)
        }
    }

    func back() {
        Task {
            try? await hdcCommand.inputKeyEvent(2, serial: serial)
        }
    }

    func home() {
        Task {
            try? await hdcCommand.inputKeyEvent(1, serial: serial)
        }
    }

    private func mapToDevice(windowPoint: CGPoint, windowSize: CGSize) -> (x: Int, y: Int)? {
        guard windowSize.width > 0, windowSize.height > 0, screenWidth > 0, screenHeight > 0 else { return nil }

        let deviceAspect = CGFloat(screenWidth) / CGFloat(screenHeight)
        let windowAspect = windowSize.width / windowSize.height

        let videoRect: CGRect
        if deviceAspect > windowAspect {
            let vw = windowSize.width
            let vh = vw / deviceAspect
            videoRect = CGRect(x: 0, y: (windowSize.height - vh) / 2, width: vw, height: vh)
        } else {
            let vh = windowSize.height
            let vw = vh * deviceAspect
            videoRect = CGRect(x: (windowSize.width - vw) / 2, y: 0, width: vw, height: vh)
        }

        let nx = max(0, min(1, (windowPoint.x - videoRect.minX) / videoRect.width))
        let ny = max(0, min(1, (windowPoint.y - videoRect.minY) / videoRect.height))

        return (x: Int(nx * CGFloat(screenWidth)), y: Int(ny * CGFloat(screenHeight)))
    }
}
