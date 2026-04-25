import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        let keysToRemove = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("NSWindow Frame") }
        for key in keysToRemove {
            defaults.removeObject(forKey: key)
        }
    }
}

@main
struct HarmonyMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("HarmonyMirror", id: "main") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 380, height: 820)
        .defaultPosition(.center)
    }
}
