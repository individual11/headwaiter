import AppKit
import SwiftUI

@main
struct HeadwaiterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: ServerStore

    init() {
        // Before the store loads state: bring over data saved under the old name.
        RenameMigration.runIfNeeded()
        let store = ServerStore()
        _store = State(initialValue: store)
        StatusItemMenu.store = store
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}

/// Reading the store inside a View (not the App body) is what makes the label track changes.
struct MenuBarLabel: View {
    let store: ServerStore

    var body: some View {
        let count = store.itemCount
        let changed = store.hasChanges
        // .id forces a new image view per state; MenuBarExtra otherwise keeps the first image.
        Image(nsImage: MenuBarIcon.image(count: count, changed: changed))
            .id("\(count)-\(changed)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private let statusMenu = StatusItemMenu()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The bundle sets LSUIElement; this also keeps `swift run Headwaiter` out of the Dock.
        NSApp.setActivationPolicy(.accessory)
        AppAppearance.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = Snapshots.directory {
            Snapshots.renderAll(to: dir)
            exit(0)
        }
        if let dir = Snapshots.logosDirectory {
            Snapshots.renderLogos(to: dir)
            Snapshots.renderRefinedTie(to: dir)
            exit(0)
        }
        if let dir = Snapshots.iconsetDirectory {
            Snapshots.renderIconset(to: dir)
            exit(0)
        }
        if let dir = Snapshots.studiesDirectory {
            Snapshots.renderStudies(to: dir)
            exit(0)
        }
        if ProcessInfo.processInfo.environment["HW_CAPTURE"] != nil {
            // Same as the menu's Capture Diagnostics, for scripts: prints the file and exits.
            do { print(try Diagnostics.capture().path); exit(0) } catch { print(error); exit(1) }
        }
        statusMenu.install()
        Updater.shared.start()
        Notifier.shared.start()
    }
}
