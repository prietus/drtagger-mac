import SwiftUI

@main
struct DrtaggerApp: App {
    @State private var settings = AppSettings()
    @State private var queue = AlbumQueue()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(queue)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folders…") {
                    queue.presentAddPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
        }
    }
}
