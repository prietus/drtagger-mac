import SwiftData
import SwiftUI

@main
struct DrtaggerApp: App {
    private let container: ModelContainer
    @State private var settings = AppSettings()
    @State private var library: LibraryController

    init() {
        let container = Self.makeContainer()
        self.container = container
        _library = State(initialValue: LibraryController(container: container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(library)
        }
        .modelContainer(container)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folders…") {
                    library.presentAddPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
        }
    }

    // The library database lives in Application Support. If it cannot be
    // opened (corrupt store, schema change during development) the app
    // still starts with an in-memory store rather than crashing.
    static func makeContainer() -> ModelContainer {
        let schema = Schema([AlbumRecord.self])
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "drtagger", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let storeURL = support.appending(path: "Library.store", directoryHint: .notDirectory)
        let onDisk = ModelConfiguration("Library", schema: schema, url: storeURL)
        if let container = try? ModelContainer(for: schema, configurations: [onDisk]) {
            return container
        }
        let inMemory = ModelConfiguration("Library", schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [inMemory])
        } catch {
            fatalError("Could not create even an in-memory model container: \(error)")
        }
    }
}
