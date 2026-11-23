import AppKit

/// A menu bar app has no Dock icon, so a window that falls behind other windows is hard to get
/// back to. While Settings or the log is open the app becomes a regular app (Dock icon, ⌘-Tab,
/// app menu), and goes back to menu-bar-only when the last of them closes. This is the usual
/// pattern for well-behaved menu bar apps.
@MainActor
enum DockPresence {
    enum Kind { case settings, log }

    private static var open: Set<Kind> = []
    private static var closeObserver: NSObjectProtocol?

    static func opened(_ kind: Kind) {
        open.insert(kind)
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        observeClose()
    }

    static func closed(_ kind: Kind) {
        open.remove(kind)
        guard open.isEmpty, NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// SwiftUI's onDisappear isn't guaranteed when the Settings window closes, so also watch
    /// the windows themselves.
    private static func observeClose() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            // Delivered on the main queue; the window is only touched there.
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let window = object as? NSWindow, let id = window.identifier else { return }
                if id == LogWindow.identifier {
                    closed(.log)
                } else if id.rawValue.contains("Settings") {
                    closed(.settings)
                }
            }
        }
    }
}
