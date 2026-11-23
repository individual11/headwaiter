import AppKit

/// A menu bar app has no Dock icon, so a Settings window that falls behind other windows
/// is hard to get back to. While Settings is open the app becomes a regular app (Dock icon,
/// ⌘-Tab, app menu), and goes back to menu-bar-only when the window closes. This is the
/// usual pattern for well-behaved menu bar apps.
@MainActor
enum DockPresence {
    private static var closeObserver: NSObjectProtocol?

    static func settingsOpened() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        observeClose()
    }

    static func settingsClosed() {
        guard NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// SwiftUI's onDisappear isn't guaranteed when the Settings window closes, so also watch
    /// the window itself.
    private static func observeClose() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            // Delivered on the main queue; the window is only touched there.
            nonisolated(unsafe) let object = note.object
            MainActor.assumeIsolated {
                guard let window = object as? NSWindow,
                      window.identifier?.rawValue.contains("Settings") == true else { return }
                settingsClosed()
            }
        }
    }
}
