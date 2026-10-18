import SwiftData
import SwiftUI

@main
struct DrtaggerApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    private let container: ModelContainer
    @State private var settings = AppSettings()
    @State private var library: LibraryController
    @State private var disc = DiscService()
    @State private var identify = IdentifyService()
    @State private var tagging = TagService()
    @State private var cddb = CDDBServer()
    @State private var releaseImages = ReleaseImagesService()
    @State private var batch = BatchRunner()
    @State private var libraryIndex = LibraryIndexService()

    init() {
        // Paths after `--add` are ours: without this AppKit also turns them
        // into "open documents" events at launch, and a SwiftUI app launched
        // to open documents skips its initial window. Finder's Open With and
        // `open -a` still arrive through AppDelegate.application(_:open:).
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
        let container = Self.makeContainer()
        self.container = container
        let library = LibraryController(container: container)
        if library.hasBatch {
            // A batch was interrupted, or its report is still open: keep
            // its albums to resume it or review them.
            library.resetInterruptedBatch()
        } else if !UserDefaults.standard.bool(forKey: "queue.keepBetweenLaunches") {
            library.removeAll()
        }
        _library = State(initialValue: library)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(settings)
                .environment(library)
                .environment(disc)
                .environment(identify)
                .environment(tagging)
                .environment(cddb)
                .environment(releaseImages)
                .environment(batch)
                .environment(libraryIndex)
                .task { cddb.update(enabled: settings.cddbServerEnabled, port: settings.cddbPort) }
                .onChange(of: settings.cddbServerEnabled) { _, on in cddb.update(enabled: on, port: settings.cddbPort) }
                .onChange(of: settings.cddbPort) { _, port in cddb.update(enabled: settings.cddbServerEnabled, port: port) }
                // Folders opened from other apps reuse this window
                // instead of spawning a new one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onAppear {
                    batch.attach(library: library, identify: identify, disc: disc, tagging: tagging, settings: settings, index: libraryIndex)
                    appDelegate.openHandler = { urls in
                        NSApp.activate()
                        Task { await library.open(urls) }
                    }
                }
        }
        .modelContainer(container)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folders…") {
                    library.presentAddPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Clear Queue") {
                    library.removeAll()
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(cddb)
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
        // Unit tests run inside the app: never on the user's queue.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return try! ModelContainer(for: schema, configurations: [ModelConfiguration("Tests", schema: schema, isStoredInMemoryOnly: true)])
        }
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
