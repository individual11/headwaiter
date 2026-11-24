import AppKit
import HeadwaiterCore
import ServiceManagement
import SwiftUI

/// Native, refined: project cards on the popover's material, a framework tile per row.
enum Layout {
    static let width: CGFloat = 400
    static let cardInset: CGFloat = 10
    static let cardRadius: CGFloat = 10
    static let rowRadius: CGFloat = 7
    static let tile: CGFloat = 24
    static let trailingColumn: CGFloat = 92
    static let stopSlot: CGFloat = 20
    static let maxListHeight: CGFloat = 560
}

struct PopoverView: View {
    let store: ServerStore
    var updater = Updater.shared
    @State var keyboard = PopoverKeyboard()
    @Environment(\.dismiss) private var dismiss
    @State private var listHeight: CGFloat = 0
    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.showWelcome {
                WelcomeCard(store: store)
                    .padding(.horizontal, Layout.cardInset)
                    .padding(.bottom, 8)
            }
            if !keyboard.filter.isEmpty {
                FilterBar(keyboard: keyboard, matches: groups.reduce(0) { $0 + $1.servers.count + $1.containers.count })
                    .padding(.horizontal, Layout.cardInset)
                    .padding(.bottom, 8)
            }
            if store.lastScan != nil && store.isEmpty {
                emptyContent
            } else if groups.isEmpty && !keyboard.filter.isEmpty {
                noMatches
            } else {
                scrollingList
            }
            // While the welcome card is up, protected folders are skipped on purpose; don't warn.
            if store.hasDeniedAccess && !store.showWelcome {
                accessCard
                    .padding(.horizontal, Layout.cardInset)
                    .padding(.top, 8)
            }
            footer
        }
        .frame(width: Layout.width)
        .background {
            // ⌘Q works while the popover is focused, without a visible Quit button.
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q").hidden()
        }
        .fitWindowToContent()
        .background(WindowAccessor { keyboard.attach($0) })
        .onChange(of: keyboard.items(in: store).map(\.id)) { old, new in keyboard.itemsChanged(from: old, to: new) }
        .environment(keyboard)
        .onAppear {
            store.isPopoverOpen = true
            TerminalApps.shared.refresh()
            if Snapshots.directory == nil { keyboard.start(store: store) { dismiss() } }
        }
        .onDisappear {
            store.isPopoverOpen = false
            keyboard.stop()
        }
    }

    private var groups: [ProjectGroup] { keyboard.groups(in: store) }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            // The app icon in miniature: white bow tie on the accent blue.
            GlyphRefinedTie()
                .scaleEffect(0.78)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor.gradient))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            SettingsButton()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var title: String {
        if store.lastScan == nil { return "Scanning…" }
        let n = store.itemCount
        return n == 0 ? "No dev servers running" : "\(n) server\(n == 1 ? "" : "s") running"
    }

    private var subtitle: String {
        let n = store.groups.count
        if store.isEmpty { return "Watching for dev servers and containers" }
        return "across \(n) project\(n == 1 ? "" : "s")"
    }

    // MARK: Lists

    /// Grows with content, then scrolls; measured, so the height never jumps.
    private var scrollingList: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(groups) { group in
                        ProjectCard(group: group, store: store)
                    }
                    if !store.recentlyStopped.isEmpty && keyboard.filter.isEmpty {
                        HistoryCard(store: store, collapsible: true, expanded: $showHistory)
                    }
                }
                .padding(.horizontal, Layout.cardInset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .onChange(of: keyboard.selection) { _, id in
                if let id { scroll.scrollTo(id) }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Room for the fade below, so it never covers the last row or the keyboard selection.
        .contentMargins(.bottom, listHeight > Layout.maxListHeight ? 24 : 0, for: .scrollContent)
        .frame(height: min(max(listHeight, 1), Layout.maxListHeight))
        // When the list scrolls, fade the bottom edge so a cut-off card reads as "more below".
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .black.opacity(listHeight > Layout.maxListHeight ? 0 : 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
            }
        }
    }

    private var noMatches: some View {
        Text("No servers match")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Card())
            .padding(.horizontal, Layout.cardInset)
    }

    @ViewBuilder private var emptyContent: some View {
        if store.recentlyStopped.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
                Text("All quiet")
                    .font(.system(size: 13, weight: .semibold))
                Text("Dev servers appear here the moment they start listening.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .padding(.horizontal, 40)
            .background(Card())
            .padding(.horizontal, Layout.cardInset)
        } else {
            HistoryCard(store: store, collapsible: false, expanded: .constant(true))
                .padding(.horizontal, Layout.cardInset)
        }
    }

    private var accessCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Some projects are in folders this app can't read, so they show folder names.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings…") { Actions.openFilesAndFoldersSettings() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Card())
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let version = updater.availableVersion {
                UpdateButton(version: version, updater: updater)
            } else if store.showCopyHint {
                Image(systemName: "lightbulb").font(.system(size: 10))
                Text(store.state.popoverOpenCount.isMultiple(of: 2)
                     ? "Type to filter, ↑↓ and Return to open" : "Option-click a server to copy its URL")
            }
            Spacer(minLength: 8)
            QuitButton()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 8)
        .padding(.bottom, 9)
    }
}

/// First-run card: what Headwaiter does, why macOS is about to ask for folder access, and
/// Open at Login. Protected folders aren't read until Continue (ProtectedFolderGate).
struct WelcomeCard: View {
    let store: ServerStore
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                GlyphRefinedTie()
                    .scaleEffect(1.2)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.gradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Welcome to Headwaiter").font(.system(size: 13, weight: .semibold))
                    Text("Every dev server on your Mac, by project.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text("To show project names, Headwaiter reads files like package.json in your project folders. macOS will ask once for folders such as Desktop or Documents. What it reads never leaves your Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("Open at Login", isOn: $openAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .onChange(of: openAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Spacer()
                Button("Continue") { store.finishWelcome() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(Card())
    }
}

/// The rounded, faintly filled container used for every section.
struct Card: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06)))
    }
}

// MARK: - Project card

struct ProjectCard: View {
    let group: ProjectGroup
    let store: ServerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader {
                HStack(spacing: 6) {
                    if group.hasDeniedAccess {
                        Image(systemName: "lock.fill")
                            .imageScale(.small)
                            .help("This app can't read this folder, so names come from folder names")
                    }
                    Text(group.project.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(2)
                    if let tree = group.project.worktree {
                        WorktreeBadge(name: tree)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 8)
                    Text(Display.abbreviatingHome(group.project.rootPath))
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .help(group.project.rootPath)
            .contextMenu {
                if group.id != ServerStore.dockerGroupRoot {
                    FolderMenuItems(folder: group.project.rootPath)
                    Divider()
                }
                Button("Hide \(group.project.displayName)") { store.hideProject(group.project.rootPath) }
            }

            ForEach(group.servers) { server in
                ServerRow(server: server, store: store)
            }
            ForEach(group.containers) { container in
                ContainerRow(container: container, store: store)
            }
        }
        .padding(.bottom, 4)
        .background(Card())
    }
}

struct CardHeader<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

struct WorktreeBadge: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "arrow.triangle.branch")
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .help("Git worktree: \(name)")
    }
}

// MARK: - Server row

struct ServerRow: View {
    let server: Server
    let store: ServerStore
    @State private var hovered = false
    @State private var stopHovered = false
    @Environment(PopoverKeyboard.self) private var keyboard
    @Environment(\.dismiss) private var dismiss

    private var stopState: StopState? { store.stopStates[server.id] }
    private var isStopping: Bool { stopState == .stopping }
    private var copied: Bool { keyboard.copiedID == server.id }
    private var selected: Bool { keyboard.selection == server.id }
    private var showHover: Bool { (hovered || selected) && !isStopping }
    private var url: URL { store.url(for: server) }
    private var expanded: Bool { store.isExpanded(server.id) && !server.secondaryPorts.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if expanded {
                OtherPortsList(row: server.id, ports: server.secondaryPorts.map { ($0, server.url(port: $0)) }, store: store) {
                    store.toggleExpanded(server.id)
                }
            }
        }
    }

    private var mainRow: some View {
        HStack(spacing: 6) {
            Button(action: activate) { content }
                .buttonStyle(.plain)
                .disabled(isStopping)
            // ZStack + Color.clear keeps the slot's width even when it shows nothing.
            ZStack { Color.clear; stopSlot }
                .frame(width: Layout.stopSlot, height: Layout.stopSlot)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Layout.rowRadius, style: .continuous)
            .fill(RowHighlight.color(selected: selected, hovered: hovered && !isStopping)))
        .padding(.horizontal, 3)
        .id(server.id)
        .onHover { hovered = $0 }
        .help("\(url.absoluteString)\n\(Display.command(server.root))")
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens \(url.absoluteString)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activate() }
        .accessibilityAction(named: "Copy URL") { Actions.copy(url.absoluteString) }
        .accessibilityAction(named: "Reveal in Finder") { Actions.reveal(server.package.path) }
        .accessibilityAction(named: "Open in Terminal") { TerminalApps.shared.open(server.package.path) }
        .accessibilityAction(named: "Stop") { store.stop(server) }
        .accessibilityActions {
            if !server.secondaryPorts.isEmpty {
                Button(expanded ? "Hide Other Ports" : "Show Other Ports") { store.toggleExpanded(server.id) }
            }
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            FrameworkTile(mark: FrameworkStyle.mark(server), color: FrameworkStyle.color(server),
                          textColor: FrameworkStyle.markText(server), isNew: store.isNew(server),
                          image: store.favicons.image(for: server))
                .opacity(isStopping ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(server.package.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(FrameworkStyle.name(server))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .foregroundStyle(isStopping ? .secondary : .primary)
                statusLine
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                portLine
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Display.uptime(since: server.startTime, now: context.date))
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .frame(minWidth: 60, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    private var portLine: some View {
        HStack(spacing: 4) {
            if copied {
                Label("Copied", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tint)
            } else {
                if !server.secondaryPorts.isEmpty {
                    PortChip(ports: server.secondaryPorts, expanded: expanded) { store.toggleExpanded(server.id) }
                }
                Text(verbatim: ":\(server.primaryPort)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(isStopping ? .secondary : .primary)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tint)
                    .opacity(showHover ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        Group {
            switch stopState {
            case .stopping:
                Text("Stopping…")
            case .needsForceQuit:
                Label("Still running after Stop", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .symbolRenderingMode(.multicolor)
                    .help(message)
            case nil:
                Text(server.subtitle)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private var stopSlot: some View {
        switch stopState {
        case .stopping:
            ProgressView().controlSize(.mini)
        case .needsForceQuit:
            Button { store.forceQuit(server) } label: {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.orange)
                    .frame(width: Layout.stopSlot, height: Layout.stopSlot)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Force quit: still running after Stop (sends SIGKILL)")
            .accessibilityLabel("Force quit \(server.package.name)")
        default:
            // Hidden until the row is hovered: one click stops, so don't show a column of targets.
            if hovered || selected || stopHovered {
                Button { store.stop(server) } label: {
                    Image(systemName: stopHovered ? "stop.circle.fill" : "stop.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(stopHovered ? .primary : .secondary)
                        .frame(width: Layout.stopSlot, height: Layout.stopSlot)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { stopHovered = $0 }
                .help("Stop \(server.package.name)")
                .accessibilityLabel("Stop \(server.package.name)")
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Open in Browser") { Actions.open(url) }
        Button("Copy URL") { Actions.copy(url.absoluteString) }
        Button("Copy Command") { Actions.copy(server.root.arguments.joined(separator: " ")) }
        Button("Set URL…") { Actions.promptURL(for: server, store: store) }
        if store.hasURLOverride(server) {
            Button("Reset URL") { store.resetURL(for: server) }
        }
        Button(String("Copy PID (\(server.rootPID))")) { Actions.copy(String(server.rootPID)) }
        if !server.secondaryPorts.isEmpty {
            Button(expanded ? "Hide Other Ports" : "Show Other Ports") { store.toggleExpanded(server.id) }
        }
        Divider()
        FolderMenuItems(folder: server.package.path)
        Divider()
        if case .needsForceQuit = stopState {
            Button("Force Quit") { store.forceQuit(server) }
        } else {
            Button("Stop") { store.stop(server) }.disabled(isStopping)
        }
        Divider()
        Button(String("Hide Port :\(server.primaryPort)")) { store.hidePort(server.primaryPort) }
        Button("Hide \(server.project.displayName)") { store.hideProject(server.project.rootPath) }
    }

    private var accessibilityText: String {
        var parts = [server.package.name, "in \(server.project.displayName)", FrameworkStyle.name(server)]
        parts.append("port \(server.primaryPort)")
        if store.isNew(server) { parts.append("new") }
        switch stopState {
        case .stopping: parts.append("stopping")
        case .needsForceQuit: parts.append("still running after stop")
        case .failed(let m): parts.append(m)
        case nil: parts.append("up \(Display.uptime(since: server.startTime))")
        }
        return parts.joined(separator: ", ")
    }

    private func activate() {
        if NSEvent.modifierFlags.contains(.option) {
            Actions.copy(url.absoluteString)
            keyboard.flashCopied(server.id)
            AccessibilityNotification.Announcement("Copied \(url.absoluteString)").post()
        } else {
            Actions.open(url)
            dismiss()
        }
    }
}

/// A Docker container row: same layout as a server row, stopped through the Docker API.
struct ContainerRow: View {
    let container: ContainerServer
    let store: ServerStore
    @State private var hovered = false
    @State private var stopHovered = false
    @Environment(PopoverKeyboard.self) private var keyboard
    @Environment(\.dismiss) private var dismiss

    private var stopState: StopState? { store.stopStates[container.id] }
    private var isStopping: Bool { stopState == .stopping }
    private var copied: Bool { keyboard.copiedID == container.id }
    private var selected: Bool { keyboard.selection == container.id }
    private var showHover: Bool { (hovered || selected) && !isStopping }
    static let dockerBlue = Color(red: 0.11, green: 0.39, blue: 0.93)
    private var expanded: Bool { store.isExpanded(container.id) && !container.secondaryPorts.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if expanded {
                // Databases and other non-HTTP services copy host:port instead of opening.
                OtherPortsList(row: container.id, ports: container.secondaryPorts.map { ($0, container.url(port: $0)) }, store: store) {
                    store.toggleExpanded(container.id)
                }
            }
        }
    }

    private var mainRow: some View {
        HStack(spacing: 6) {
            Button(action: activate) { content }
                .buttonStyle(.plain)
                .disabled(isStopping)
            ZStack { Color.clear; stopSlot }
                .frame(width: Layout.stopSlot, height: Layout.stopSlot)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Layout.rowRadius, style: .continuous)
            .fill(RowHighlight.color(selected: selected, hovered: hovered && !isStopping)))
        .padding(.horizontal, 3)
        .id(container.id)
        .onHover { hovered = $0 }
        .help("\(container.isHTTP ? container.url.absoluteString : container.address)\n\(container.image)")
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(container.name), Docker container, \(container.imageShortName), port \(container.primaryPort)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activate() }
        .accessibilityAction(named: "Stop") { store.stop(container) }
        .accessibilityActions {
            if !container.secondaryPorts.isEmpty {
                Button(expanded ? "Hide Other Ports" : "Show Other Ports") { store.toggleExpanded(container.id) }
            }
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = store.favicons.image(for: container) {
                    FaviconTile(image: icon)
                } else {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: Layout.tile, height: Layout.tile)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Self.dockerBlue.gradient))
                }
            }
            .opacity(isStopping ? 0.5 : 1)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(container.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(container.imageShortName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .foregroundStyle(isStopping ? .secondary : .primary)
                Group {
                    switch stopState {
                    case .stopping: Text("Stopping…")
                    case .failed(let message):
                        Label(message, systemImage: "xmark.octagon.fill").symbolRenderingMode(.multicolor)
                    default:
                        Text(container.composeProject.map { "container · \($0)" } ?? "container")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 4) {
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tint)
                    } else {
                        if !container.secondaryPorts.isEmpty {
                            PortChip(ports: container.secondaryPorts, expanded: expanded) {
                                store.toggleExpanded(container.id)
                            }
                        }
                        Text(verbatim: ":\(container.primaryPort)")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                        Image(systemName: container.isHTTP ? "arrow.up.right" : "doc.on.doc")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tint)
                            .opacity(showHover ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Display.uptime(since: container.startTime, now: context.date))
                }
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .frame(minWidth: 60, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var stopSlot: some View {
        if isStopping {
            ProgressView().controlSize(.mini)
        } else if hovered || selected || stopHovered {
            Button { store.stop(container) } label: {
                Image(systemName: stopHovered ? "stop.circle.fill" : "stop.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(stopHovered ? .primary : .secondary)
                    .frame(width: Layout.stopSlot, height: Layout.stopSlot)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { stopHovered = $0 }
            .help("Stop container \(container.name)")
        }
    }

    @ViewBuilder private var menu: some View {
        if container.isHTTP {
            Button("Open in Browser") { Actions.open(container.url) }
            Button("Copy URL") { Actions.copy(container.url.absoluteString) }
        }
        Button("Copy Address (\(container.address))") { Actions.copy(container.address) }
        Button("Copy Container ID") { Actions.copy(container.id) }
        if !container.secondaryPorts.isEmpty {
            Button(expanded ? "Hide Other Ports" : "Show Other Ports") { store.toggleExpanded(container.id) }
        }
        Divider()
        if let project = container.project {
            FolderMenuItems(folder: project.rootPath)
            Divider()
        }
        Button("Stop Container") { store.stop(container) }.disabled(isStopping)
        Divider()
        Button(String("Hide Port :\(container.primaryPort)")) { store.hidePort(container.primaryPort) }
    }

    /// Web containers open in the browser; databases and other non-HTTP services copy host:port.
    private func activate() {
        if container.isHTTP && !NSEvent.modifierFlags.contains(.option) {
            Actions.open(container.url)
            dismiss()
        } else {
            Actions.copy(container.isHTTP ? container.url.absoluteString : container.address)
            keyboard.flashCopied(container.id)
        }
    }
}

/// Colored rounded square with the framework's letters; NEW shows as an accent dot on its corner.
struct FrameworkTile: View {
    let mark: String
    let color: Color
    var textColor: Color = .white
    var isNew = false
    /// The project's own icon; replaces the mark when present.
    var image: NSImage? = nil
    /// Recently stopped rows show the icon in gray.
    var dimmed = false

    var body: some View {
        tile
            .frame(width: Layout.tile, height: Layout.tile)
            .overlay(alignment: .topLeading) {
                if isNew {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: -3, y: -3)
                        .help("Started since you last looked")
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var tile: some View {
        if let image {
            FaviconTile(image: image, dimmed: dimmed)
        } else {
            Text(mark)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(textColor)
                .frame(width: Layout.tile, height: Layout.tile)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient))
        }
    }
}

/// A favicon on a white tile, like a browser tab: most favicons are drawn for a light background.
struct FaviconTile: View {
    let image: NSImage
    var dimmed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .padding(3)
            .frame(width: Layout.tile, height: Layout.tile)
            .background(shape.fill(Color.white))
            .overlay(shape.strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
            .saturation(dimmed ? 0 : 1)
            .opacity(dimmed ? 0.6 : 1)
    }
}

// MARK: - Recently stopped

struct HistoryCard: View {
    let store: ServerStore
    let collapsible: Bool
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader {
                HStack(spacing: 5) {
                    if collapsible {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    } else {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text("Recently stopped")
                        .font(.system(size: 11, weight: .semibold))
                    if collapsible {
                        Text("\(store.recentlyStopped.count)")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    Spacer()
                    if expanded {
                        Button("Clear") { store.clearHistory() }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            }
            .padding(.bottom, collapsible && !expanded ? 5 : 0)
            .contentShape(Rectangle())
            .onTapGesture {
                guard collapsible else { return }
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            }

            if expanded {
                ForEach(store.recentlyStopped) { entry in
                    HistoryRow(entry: entry, store: store)
                }
            }
        }
        .padding(.bottom, expanded ? 4 : 0)
        .background(Card())
    }
}

struct HistoryRow: View {
    let entry: StoppedServer
    let store: ServerStore

    var body: some View {
        HStack(spacing: 10) {
            FrameworkTile(mark: FrameworkStyle.mark(id: entry.frameworkID, runtime: entry.runtime ?? "node"),
                          color: Color.secondary.opacity(0.35),
                          image: store.favicons.image(forPackage: entry.packagePath), dimmed: true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(entry.packageName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if let framework = entry.framework {
                        Text(framework).font(.system(size: 11))
                    }
                }
                Text(entry.worktree == nil && entry.projectName == entry.packageName
                     ? entry.subtitle : "\(entry.projectName) · \(entry.subtitle)")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: ":\(entry.port)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Ago.string(entry.stoppedAt, now: context.date))
                }
                .font(.system(size: 11))
            }
            Color.clear.frame(width: Layout.stopSlot)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .padding(.horizontal, 3)
        .help(entry.command.joined(separator: " "))
        .contextMenu {
            Button("Copy Command") { Actions.copy(entry.command.joined(separator: " ")) }
            FolderMenuItems(folder: entry.packagePath)
            Divider()
            Button("Forget") { store.forget(entry) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.packageName), stopped \(Ago.string(entry.stoppedAt)), port \(entry.port)")
    }
}

// MARK: - Small pieces

enum RowHighlight {
    /// The keyboard selection is stronger than hover, so the two can be told apart.
    static func color(selected: Bool, hovered: Bool) -> Color {
        selected ? Color.accentColor.opacity(0.24) : hovered ? Color.accentColor.opacity(0.12) : .clear
    }
}

/// Menu items for a project or package folder.
struct FolderMenuItems: View {
    let folder: String
    var terminals = TerminalApps.shared
    /// Read so the item's title follows the Settings choice.
    @AppStorage(Preferences.terminalKey) private var terminal = ""

    var body: some View {
        Button("Reveal in Finder") { Actions.reveal(folder) }
        if let app = terminals.current {
            Button("Open in \(app.name)") { terminals.open(folder) }
        }
    }
}

/// "+N" for a row's other ports. Click it to show them under the row (`OtherPortsList`).
struct PortChip: View {
    let ports: [UInt16]
    let expanded: Bool
    let toggle: () -> Void
    @State private var hovered = false

    private var list: String { ports.map { ":\($0)" }.joined(separator: ", ") }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { toggle() }
        } label: {
            HStack(spacing: 2) {
                Text(verbatim: "+\(ports.count)")
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(hovered ? .primary : .secondary)
            .padding(.leading, 5)
            .padding(.trailing, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(hovered || expanded ? 0.13 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(expanded ? "Hide other ports" : "Show other ports: \(list)")
        .fixedSize()
    }
}

/// A row's other ports, one line each, under the row. Click opens; Option-click copies.
/// A nil URL means a non-HTTP service: clicking copies its address instead.
struct OtherPortsList: View {
    let row: String
    let ports: [(port: UInt16, url: URL?)]
    let store: ServerStore
    /// Closes the list (the row's Show/Hide Other Ports toggle).
    let collapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(ports, id: \.port) { item in
                OtherPortRow(row: row, port: item.port, url: item.url, store: store, collapse: collapse)
            }
        }
        .padding(.bottom, 2)
        .transition(.opacity)
    }
}

struct OtherPortRow: View {
    let row: String
    let port: UInt16
    let url: URL?
    let store: ServerStore
    let collapse: () -> Void
    @State private var hovered = false
    @Environment(PopoverKeyboard.self) private var keyboard
    @Environment(\.dismiss) private var dismiss

    private var id: String { ListItem.otherPortID(row, port) }
    private var copied: Bool { keyboard.copiedID == id }
    private var selected: Bool { keyboard.selection == id }
    private var target: String { url?.absoluteString ?? "localhost:\(port)" }

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(verbatim: target)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tint)
                    } else {
                        Text(verbatim: ":\(port)")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                        Image(systemName: url != nil ? "arrow.up.right" : "doc.on.doc")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tint)
                            .opacity(hovered || selected ? 1 : 0)
                    }
                }
            }
            // Line up with the row above: text after the tile, port above the stop slot.
            .padding(.leading, Layout.tile + 10)
            .padding(.trailing, Layout.stopSlot + 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: Layout.rowRadius, style: .continuous)
            .fill(RowHighlight.color(selected: selected, hovered: hovered)))
        .padding(.horizontal, 3)
        .id(id)
        .onHover { hovered = $0 }
        .help(url != nil ? "Open \(target)\nOption-click to copy" : "Copy \(target)")
        .contextMenu {
            if let url {
                Button("Open in Browser") { Actions.open(url) }
                Button("Copy URL") { Actions.copy(url.absoluteString) }
            } else {
                Button("Copy Address (\(target))") { Actions.copy(target) }
            }
            Divider()
            Button("Hide Other Ports") { withAnimation(.snappy(duration: 0.2)) { collapse() } }
            Button(String("Hide Port :\(port)")) { withAnimation(.snappy(duration: 0.2)) { store.hidePort(port) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Other port \(port)")
        .accessibilityHint(url != nil ? "Opens \(target)" : "Copies \(target)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activate() }
    }

    private func activate() {
        if let url, !NSEvent.modifierFlags.contains(.option) {
            Actions.open(url)
            dismiss()
        } else {
            Actions.copy(target)
            keyboard.flashCopied(id)
        }
    }
}

enum Ago {
    static func string(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

extension Server {
    func url(port: UInt16) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.port = Int(port)
        return components.url!
    }
}

enum Actions {
    /// Asks for a custom URL for this package's server (e.g. a path like /admin, https, or
    /// app.localhost). Leaving the port as the server's current one makes it follow port changes.
    @MainActor
    static func promptURL(for server: Server, store: ServerStore) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "URL for \(server.package.name)"
        alert.informativeText = "Clicking the server opens this URL. Keep the port as :\(server.primaryPort) and it follows the server if its port changes."
        let field = NSTextField(string: store.url(for: server).absoluteString)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if !store.setURL(field.stringValue, for: server) {
            let error = NSAlert()
            error.messageText = "That isn't a URL Headwaiter can open"
            error.informativeText = "Try something like http://localhost:\(server.primaryPort)/admin"
            error.runModal()
        }
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Selects the folder in Finder.
    @MainActor
    static func reveal(_ folder: String) {
        guard checkFolder(folder) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder, isDirectory: true)])
    }

    /// False, after saying so, if the folder was moved or deleted (a removed worktree, say).
    @MainActor
    static func checkFolder(_ folder: String) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue { return true }
        alert("That folder no longer exists", Display.abbreviatingHome(folder))
        return false
    }

    @MainActor
    static func alert(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    static func openFilesAndFoldersSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
        NSWorkspace.shared.open(url)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Gear button: opens Settings and brings it to the front, even if it's already open behind
/// other windows. (SettingsLink alone doesn't activate a menu bar app or raise the window.)
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var hovered = false

    var body: some View {
        Button {
            dismiss()
            openSettings()
            SettingsWindow.bringToFront()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundStyle(hovered ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(",")
        .onHover { hovered = $0 }
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

enum SettingsWindow {
    /// Activates the app and raises the Settings window. Runs again on the next turn of the
    /// run loop, because a newly opened window doesn't exist yet when openSettings returns.
    @MainActor
    static func bringToFront() {
        NSApp.activate()
        raise()
        DispatchQueue.main.async { raise() }
    }

    @MainActor
    private static func raise() {
        for window in NSApp.windows where isSettings(window) {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    @MainActor
    private static func isSettings(_ window: NSWindow) -> Bool {
        // SwiftUI's Settings scene window identifier is "com_apple_SwiftUI_Settings_window".
        window.identifier?.rawValue.contains("Settings") == true
    }
}

/// Shown in the footer when a newer version was found in the background.
struct UpdateButton: View {
    let version: String
    let updater: Updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button {
            dismiss()
            updater.checkForUpdates()
        } label: {
            Label("Update to \(version)", systemImage: "arrow.down.circle.fill")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .help("See what's new and install it")
    }
}

/// Quiet text button in the footer. Quitting stops watching; servers keep running.
struct QuitButton: View {
    @State private var hovered = false

    var body: some View {
        Button("Quit") { NSApp.terminate(nil) }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hovered ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovered ? Color.primary.opacity(0.08) : .clear))
            .onHover { hovered = $0 }
            .help("Quit Headwaiter (⌘Q). Your servers keep running.")
    }
}
