import AppKit
import HeadwaiterCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let store: ServerStore
    var updater = Updater.shared
    @AppStorage(Preferences.autoForceQuitKey) private var autoForceQuit = false
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system
    @AppStorage(Preferences.showFaviconsKey) private var showFavicons = true
    @AppStorage(Preferences.fetchFaviconsKey) private var fetchFavicons = true

    var body: some View {
        Form {
            Section("General") {
                OpenAtLoginRow()
                Picker(selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Appearance")
                    Text("Colors for the popover and this window. The menu bar icon always follows the menu bar.")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, new in AppAppearance.apply(new) }
            }

            Section("Project icons") {
                Toggle(isOn: $showFavicons) {
                    Text("Show project icons")
                    Text("Use each project's favicon instead of the framework badge. Starter icons from project templates are skipped.")
                }
                Toggle(isOn: $fetchFavicons) {
                    Text("Ask running servers for their icon")
                    Text("When the project folder has no icon, request /favicon.ico from the server once. This adds a line to the server's log.")
                }
                .disabled(!showFavicons)
            }
            .onChange(of: showFavicons) { store.refreshFavicons() }
            .onChange(of: fetchFavicons) { store.refreshFavicons() }

            Section("Stopping servers") {
                Toggle(isOn: $autoForceQuit) {
                    Text("Force quit automatically")
                    Text("When a server is still running 3 seconds after Stop, force quit it instead of showing the Force Quit button.")
                }
            }

            if updater.isAvailable {
                Section("Updates") {
                    Toggle(isOn: Binding(get: { updater.checksAutomatically }, set: { updater.setChecksAutomatically($0) })) {
                        Text("Check for updates automatically")
                        Text("Asks GitHub once a day for a newer version. Nothing is installed without asking.")
                    }
                    Button("Check for Updates…") { updater.checkForUpdates() }
                }
            }

            Section("Privacy") {
                if store.hasDeniedAccess {
                    LabeledContent {
                        Button("Open Privacy Settings…") { Actions.openFilesAndFoldersSettings() }
                    } label: {
                        Label("Some project folders can't be read", systemImage: "lock.fill")
                        Text("Those servers show folder names instead of package names. Allow access under Files and Folders.")
                    }
                } else {
                    Label {
                        Text("All running projects can be read")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }

            Section("Hidden") {
                let hidden = store.hiddenItems
                if hidden.projects.isEmpty && hidden.ports.isEmpty {
                    Text("Hide a port or project from a server's right-click menu.")
                        .foregroundStyle(.secondary)
                }
                ForEach(hidden.projects.sorted(), id: \.self) { root in
                    LabeledContent {
                        Button("Show") { store.unhideProject(root) }
                    } label: {
                        Text((root as NSString).lastPathComponent)
                        Text(Display.abbreviatingHome(root))
                    }
                }
                ForEach(hidden.ports.sorted(), id: \.self) { port in
                    LabeledContent(String("Port \(port)")) {
                        Button("Show") { store.unhidePort(port) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { DockPresence.settingsOpened() }
        .onDisappear { DockPresence.settingsClosed() }
    }
}

/// "Open at Login" backed by SMAppService, showing the live status (the user can change it
/// in System Settings too) and the approval path when macOS requires it.
struct OpenAtLoginRow: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Toggle(isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: { set($0) })) {
            Text("Open at Login")
            if status == .requiresApproval {
                Text("Waiting for approval in System Settings › Login Items.")
            } else if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        if status == .requiresApproval {
            Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
        }
        EmptyView()
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                status = SMAppService.mainApp.status
            }
    }

    private func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}
