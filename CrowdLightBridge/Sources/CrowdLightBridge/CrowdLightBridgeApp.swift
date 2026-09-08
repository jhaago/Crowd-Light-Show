import SwiftUI

@main
struct CrowdLightBridgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("CrowdLight") {
                Button("BLACKOUT") { model.sendManual(.blackout) }
                    .keyboardShortcut(.escape, modifiers: [])
                Divider()
                Button("Test Firebase") { model.testFirebase() }
            }
        }
    }
}
