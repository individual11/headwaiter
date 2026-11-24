import AppKit

/// Right-click (or Control-click) on the menu bar icon shows Stop All Servers…, Settings…, updates,
/// About, Capture Diagnostics and Quit.
///
/// SwiftUI's MenuBarExtra has no right-click hook, so this watches the app's own mouse
/// events and catches right-clicks on its status bar button before MenuBarExtra sees them.
/// Left clicks pass through untouched and open the popover as usual.
@MainActor
final class StatusItemMenu: NSObject {
    private var monitor: Any?
    /// Set when the app starts, before the menu can open.
    static var store: ServerStore?

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, Self.isStatusItemClick(event) else { return event }
            let isContextClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard isContextClick else { return event }
            self.showMenu(for: event)
            return nil // swallow it so the popover doesn't open too
        }
    }

    /// The status item lives in a private NSStatusBarWindow owned by this app.
    private static func isStatusItemClick(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        return String(describing: type(of: window)).contains("StatusBarWindow")
    }

    private func showMenu(for event: NSEvent) {
        guard let view = event.window?.contentView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let stopItem = item("Stop All Servers…", #selector(stopAll))
        stopItem.isEnabled = Self.store?.stoppableGroups.isEmpty == false
        menu.addItem(stopItem)
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        if Updater.shared.isAvailable {
            let title = Updater.shared.availableVersion.map { "Update to \($0)…" } ?? "Check for Updates…"
            menu.addItem(item(title, #selector(checkForUpdates)))
        }
        menu.addItem(item("About Headwaiter", #selector(openAbout)))
        menu.addItem(.separator())
        let capture = item("Capture Diagnostics", #selector(captureDiagnostics))
        capture.toolTip = "Save what the app sees right now, to report a server it got wrong"
        menu.addItem(capture)
        menu.addItem(.separator())
        menu.addItem(item("Quit Headwaiter", #selector(quit), key: "q"))
        // Drop the menu just below the icon, like any menu bar menu.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.minY - 4), in: view)
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func stopAll() {
        if let store = Self.store { Actions.promptStopAll(store) }
    }

    @objc private func openSettings() {
        NSApp.activate()
        // The SwiftUI Settings scene responds to this action, as the app menu's Settings item does.
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        SettingsWindow.bringToFront()
    }

    @objc private func checkForUpdates() {
        Updater.shared.checkForUpdates()
    }

    @objc private func openAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Headwaiter",
            .credits: NSAttributedString(
                string: "Keeping track of servers on your machine.",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func captureDiagnostics() {
        do {
            let url = try Diagnostics.capture()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSApp.activate()
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't capture diagnostics"
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
