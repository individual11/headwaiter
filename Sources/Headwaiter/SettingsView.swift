import AppKit
import HeadwaiterCore
import ServiceManagement
import SwiftUI

/// The Settings window: one tab per category, each as tall as its content.
struct SettingsView: View {
    let store: ServerStore

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Notifications", systemImage: "bell") { NotificationSettings() }
            Tab("Projects", systemImage: "folder") { ProjectSettings(store: store) }
            Tab("Log", systemImage: "list.bullet.rectangle") { LogSettings() }
        }
        // On the whole window: a tab's own onDisappear fires when you switch tabs.
        .onAppear { DockPresence.opened(.settings) }
        .onDisappear { DockPresence.closed(.settings) }
    }
}

private extension View {
    func settingsTab() -> some View {
        formStyle(.grouped)
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralSettings: View {
    var updater = Updater.shared
    var terminals = TerminalApps.shared
    @AppStorage(Preferences.autoForceQuitKey) private var autoForceQuit = false
    @AppStorage(Preferences.terminalKey) private var terminal = ""
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system

    var body: some View {
        Form {
            Section {
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

            Section("Opening folders") {
                Picker(selection: $terminal) {
                    Text(terminals.systemDefault.map { "Default (\($0.name))" } ?? "Default").tag("")
                    Divider()
                    ForEach(terminals.installed) { Text($0.name).tag($0.id) }
                    // Keeps the choice showing if that app was removed.
                    if !terminal.isEmpty && !terminals.installed.contains(where: { $0.id == terminal }) {
                        Text("Not installed").tag(terminal)
                    }
                } label: {
                    Text("Terminal")
                    Text("Where a server's right-click menu opens its folder.")
                }
            }

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
        }
        .settingsTab()
        .onAppear { terminals.refresh() }
    }
}

struct NotificationSettings: View {
    var notifier = Notifier.shared
    @AppStorage(Preferences.notifyStartedKey) private var started = false
    @AppStorage(Preferences.notifyStoppedKey) private var stopped = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $started) {
                    Text("When a server starts")
                    Text("Once it has run for 10 seconds, so short test runs stay quiet. Click the notification to open the server.")
                }
                Toggle(isOn: $stopped) {
                    Text("When a server stops")
                    Text("Not when you stop it from Headwaiter, or when it restarts within 10 seconds.")
                }
            } footer: {
                Text("Hidden ports and projects never notify. Nothing is shown while the list is open.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if notifier.isBlocked && (started || stopped) {
                LabeledContent {
                    Button("Open System Settings…") { notifier.openSystemSettings() }
                } label: {
                    Label("Notifications are turned off", systemImage: "bell.slash.fill")
                    Text("Allow them for Headwaiter in System Settings.")
                }
            }
        }
        .settingsTab()
        .onChange(of: started) { _, on in if on { notifier.requestPermission() } }
        .onChange(of: stopped) { _, on in if on { notifier.requestPermission() } }
        .onAppear { notifier.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notifier.refreshStatus()
        }
    }
}

struct ProjectSettings: View {
    let store: ServerStore
    @AppStorage(Preferences.showFaviconsKey) private var showFavicons = true
    @AppStorage(Preferences.fetchFaviconsKey) private var fetchFavicons = true

    var body: some View {
        Form {
            Section("Icons") {
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

            Section("Folder access") {
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
        .settingsTab()
    }
}

struct LogSettings: View {
    var log = LogStore.shared
    @AppStorage(Preferences.keepLogKey) private var keepLog = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $keepLog) {
                    Text("Keep a log")
                    Text("Adds a line whenever a server starts or stops while Headwaiter is running. Hidden ports and projects aren't logged.")
                }
            }

            Section {
                LabeledContent {
                    Button("Clear…") { log.confirmClear() }.disabled(log.lines.isEmpty)
                    Button("Open Log") { LogWindow.show() }
                } label: {
                    Text(LogView.entries(log.lines.count))
                    Text("Kept on this Mac, up to 1 MB. The oldest entries are dropped first.")
                }
                if let error = log.error {
                    Label("Couldn't update the log: \(error)", systemImage: "exclamationmark.triangle.fill")
                }
            }
        }
        .settingsTab()
        .onAppear { log.reload() }
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
