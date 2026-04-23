import SwiftUI

@main
struct HarmonyMirrorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 400, height: 700)
    }
}
