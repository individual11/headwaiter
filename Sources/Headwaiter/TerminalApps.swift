import AppKit
import HeadwaiterCore
import Observation
import UniformTypeIdentifiers

/// Which terminal "Open in …" uses: the one chosen in Settings, else the Mac's default.
///
/// macOS has no default terminal setting as such. The app that opens Unix executables is the
/// closest thing, and it's what terminals change with "Make Default Terminal".
@MainActor
@Observable
final class TerminalApps {
    static let shared = TerminalApps()

    struct App: Identifiable, Hashable {
        /// Bundle identifier.
        var id: String
        var name: String
        var url: URL
    }

    private(set) var installed: [App] = []
    private(set) var systemDefault: App?

    /// What "Open in …" opens. A chosen app that's been removed falls back to the default.
    var current: App? {
        let chosen = Preferences.terminal
        return installed.first { $0.id == chosen } ?? systemDefault
    }

    /// Found even if they don't claim Unix executables.
    private static let known = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                                "dev.warp.Warp-Stable", "net.kovidgoyal.kitty"]

    private init() { refresh() }

    /// Looks again, for apps installed or defaults changed since. Called when the list or
    /// Settings opens.
    func refresh() {
        let workspace = NSWorkspace.shared
        let urls = workspace.urlsForApplications(toOpen: UTType.unixExecutable)
            + Self.known.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        var found: [String: App] = [:]
        for app in urls.compactMap(Self.app) where found[app.id] == nil { found[app.id] = app }
        let sorted = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let fallback = workspace.urlForApplication(toOpen: UTType.unixExecutable).flatMap(Self.app)
            ?? found["com.apple.Terminal"]
        if sorted != installed { installed = sorted }
        if fallback != systemDefault { systemDefault = fallback }
    }

    private static func app(_ url: URL) -> App? {
        guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return App(id: id, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name, url: url)
    }

    /// Opens a new terminal window or tab (the terminal decides) in `folder`.
    func open(_ folder: String) {
        guard let app = current, Actions.checkFolder(folder) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: folder, isDirectory: true)], withApplicationAt: app.url,
                                configuration: NSWorkspace.OpenConfiguration()) { @Sendable _, error in
            guard let message = error?.localizedDescription else { return }
            Task { @MainActor in Actions.alert("Couldn't open \(app.name)", message) }
        }
    }
}
