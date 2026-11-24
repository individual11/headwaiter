import AppKit
import HeadwaiterCore
import Observation

/// The log of server starts and stops, off until turned on in Settings. It's a plain text file
/// in ~/Library/Logs, where Console looks too. Turning the log off keeps what it holds.
@MainActor
@Observable
final class LogStore {
    static let shared = LogStore(file: LogFile(url: defaultURL))

    /// Oldest first.
    private(set) var lines: [String] = []
    /// The last write failed, e.g. a full disk.
    private(set) var error: String?

    @ObservationIgnored let file: LogFile?

    static var defaultURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Headwaiter", isDirectory: true).appendingPathComponent("servers.log")
    }

    init(file: LogFile) {
        self.file = file
        reload()
    }

    /// Snapshot rendering.
    init(previewLines: [String]) {
        file = nil
        lines = previewLines
    }

    /// Picks up changes made outside the app, such as a deleted file.
    func reload() {
        if let file { lines = file.lines() }
    }

    func append(_ events: [LogEvent]) {
        guard let file, !events.isEmpty else { return }
        let new = events.map { $0.line() }
        do {
            if try file.append(new) { reload() } else { lines += new }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func revealInFinder() {
        guard let file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    /// Asks first: cleared entries can't be brought back.
    func confirmClear() {
        guard let file else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Clear the server log?"
        alert.informativeText = "This deletes every entry and can't be undone."
        alert.addButton(withTitle: "Clear").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try file.clear()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        reload()
    }
}
