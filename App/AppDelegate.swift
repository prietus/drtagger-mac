import AppKit

// Receives folders opened from other apps (Finder "Open With", `open -a`,
// DrPlayer's "Open in drtagger"). Events that arrive before the window is
// ready are buffered until ContentView installs the handler.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pending: [URL] = []

    var openHandler: (([URL]) -> Void)? {
        didSet {
            guard let openHandler, !pending.isEmpty else { return }
            let urls = pending
            pending.removeAll()
            openHandler(urls)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if let openHandler {
            openHandler(files)
        } else {
            pending.append(contentsOf: files)
        }
    }
}
