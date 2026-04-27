import AppKit
import CoreGraphics
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var windowMonitor: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        let defaults = UserDefaults.standard
        let keysToRemove = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("NSWindow Frame") }
        for key in keysToRemove {
            defaults.removeObject(forKey: key)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let existing = NSApp.windows.first(where: { $0.isVisible || $0.isMiniaturized }) {
                existing.makeKeyAndOrderFront(nil)
            } else if let existing = NSApp.windows.first {
                existing.makeKeyAndOrderFront(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

enum AppWindowVisibility {
    static func recover(_ window: NSWindow) {
        let screen = NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main
            ?? window.screen
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let looseFrame = visibleFrame.insetBy(dx: -40, dy: -40)
        let mostlyOutsideHorizontally = window.frame.minX < visibleFrame.minX - window.frame.width * 0.5
            || window.frame.maxX > visibleFrame.maxX + window.frame.width * 0.5
        let mostlyOutsideVertically = window.frame.minY < visibleFrame.minY - window.frame.height * 0.5
            || window.frame.maxY > visibleFrame.maxY + window.frame.height * 0.5

        guard !looseFrame.intersects(window.frame) || mostlyOutsideHorizontally || mostlyOutsideVertically else {
            return
        }

        var frame = window.frame
        frame.origin.x = visibleFrame.midX - frame.width / 2
        frame.origin.y = visibleFrame.midY - frame.height / 2
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - min(frame.width, visibleFrame.width))
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - min(frame.height, visibleFrame.height))
        window.setFrame(frame, display: true)
    }
}

@main
struct HarmonyMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("HarmonyMirror") {
            ContentView(launchOptions: .current())
                .frame(minWidth: 360, minHeight: 620)
        }
        .defaultSize(width: 380, height: 820)

        Settings {
            EmptyView()
        }
    }
}
