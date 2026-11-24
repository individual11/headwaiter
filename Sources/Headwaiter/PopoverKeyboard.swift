import AppKit
import HeadwaiterCore
import Observation
import SwiftUI

/// Something the keyboard can select in the list.
enum ListItem: Identifiable {
    case server(Server)
    case container(ContainerServer)
    /// One of a row's other ports. A nil URL is a non-HTTP service: opening copies its address.
    case otherPort(UInt16, URL?, row: String, folder: String?)

    var id: String {
        switch self {
        case .server(let s): s.id
        case .container(let c): c.id
        case .otherPort(let port, _, let row, _): Self.otherPortID(row, port)
        }
    }

    static func otherPortID(_ row: String, _ port: UInt16) -> String { "\(row):\(port)" }

    /// The row it belongs to.
    var rowID: String {
        if case .otherPort(_, _, let row, _) = self { row } else { id }
    }

    var folder: String? {
        switch self {
        case .server(let s): s.package.path
        case .container(let c): c.project?.rootPath
        case .otherPort(_, _, _, let folder): folder
        }
    }

    var spokenName: String {
        switch self {
        case .server(let s): "\(s.package.name), port \(s.primaryPort)"
        case .container(let c): "\(c.name), port \(c.primaryPort)"
        case .otherPort(let port, _, _, _): "Other port \(port)"
        }
    }
}

/// The list's filter and selection, and the keys that drive them:
/// typing filters, ↑↓ select, Return opens, ⌘C (or ⌥Return) copies the URL, ⌘R reveals in
/// Finder, ⌘T opens the terminal, ⌘⌫ stops, →← show and hide other ports, Esc backs out.
///
/// Keys come from an event monitor, not SwiftUI focus, so they work as soon as the list opens
/// and wherever Tab has put the focus. Keys it doesn't use pass through untouched.
@MainActor
@Observable
final class PopoverKeyboard {
    private(set) var filterText = ""
    private(set) var selection: String?
    /// The row showing "Copied".
    private(set) var copiedID: String?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored private var store: ServerStore?
    @ObservationIgnored private var dismiss: () -> Void = {}

    var filter: ListFilter { ListFilter(filterText) }

    func attach(_ window: NSWindow?) { self.window = window }

    func start(store: ServerStore, dismiss: @escaping () -> Void) {
        self.store = store
        self.dismiss = dismiss
        clear()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        clear()
    }

    func clear() {
        filterText = ""
        selection = nil
    }

    /// Snapshot rendering.
    func preview(filter: String, selection: String?) {
        filterText = filter
        self.selection = selection
    }

    // MARK: Content

    /// The store's cards with only the matching rows.
    func groups(in store: ServerStore) -> [ProjectGroup] {
        let filter = filter
        guard !filter.isEmpty else { return store.groups }
        return store.groups.compactMap { group in
            var group = group
            group.servers.removeAll { !filter.matches($0.filterTexts) }
            group.containers.removeAll { !filter.matches($0.filterTexts) }
            return group.servers.isEmpty && group.containers.isEmpty ? nil : group
        }
    }

    /// Everything selectable, top to bottom.
    func items(in store: ServerStore) -> [ListItem] {
        groups(in: store).flatMap { group -> [ListItem] in
            group.servers.flatMap { server -> [ListItem] in
                let ports = store.isExpanded(server.id) ? server.secondaryPorts : []
                return [.server(server)] + ports.map {
                    .otherPort($0, server.url(port: $0), row: server.id, folder: server.package.path)
                }
            } + group.containers.flatMap { container -> [ListItem] in
                let ports = store.isExpanded(container.id) ? container.secondaryPorts : []
                return [.container(container)] + ports.map {
                    .otherPort($0, container.url(port: $0), row: container.id, folder: container.project?.rootPath)
                }
            }
        }
    }

    /// Keeps the selection sensible as servers come and go.
    func itemsChanged(from old: [String], to new: [String]) {
        selection = ListSelection.keep(selection, from: old, to: new)
        if selection == nil && !filter.isEmpty { selection = new.first }
    }

    func flashCopied(_ id: String) {
        copiedID = id
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == id { copiedID = nil }
        }
    }

    // MARK: Keys

    private enum Key {
        static let returnKey: UInt16 = 36, enter: UInt16 = 76, delete: UInt16 = 51, escape: UInt16 = 53
        static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    }

    /// True if the key was used.
    private func handle(_ event: NSEvent) -> Bool {
        guard let store, let window, event.window === window else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.contains(.control) { return false }   // VoiceOver and system shortcuts
        let items = items(in: store)
        let selected = items.first { $0.id == selection }

        if modifiers == .command {
            // Holding ⌘⌫ must not go on to force quit what it just stopped.
            if event.isARepeat { return selected != nil }
            if event.keyCode == Key.delete { return perform(selected) { stopServer($0, store) } }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": return perform(selected) { copy($0, store) }
            case "r": return perform(selected?.folder) { Actions.reveal($0) }
            case "t": return perform(selected?.folder) { TerminalApps.shared.open($0) }
            default: return false
            }
        }

        switch event.keyCode {
        case Key.down where modifiers.isEmpty:
            select(ListSelection.move(selection, by: 1, in: items.map(\.id)), items)
        case Key.up where modifiers.isEmpty:
            select(ListSelection.move(selection, by: -1, in: items.map(\.id)), items)
        case Key.right where modifiers.isEmpty:
            return perform(selected) { expand($0, store, true) }
        case Key.left where modifiers.isEmpty:
            return perform(selected) { expand($0, store, false) }
        case Key.returnKey, Key.enter:
            // With nothing selected, Return still reaches Continue on the welcome card.
            guard !event.isARepeat, modifiers.isEmpty || modifiers == .option else { return false }
            return perform(selected) { modifiers == .option ? copy($0, store) : open($0, store) }
        case Key.escape where modifiers.isEmpty:
            if filterText.isEmpty && selection == nil { dismiss() } else { clear() }
        case Key.delete where modifiers.isEmpty:
            guard !filterText.isEmpty else { return false }
            setFilter(String(filterText.dropLast()), store)
        default:
            guard modifiers.isSubset(of: .shift), let typed = event.characters, isText(typed) else { return false }
            // A space can't start a filter: it presses the focused button.
            if filterText.isEmpty && typed.allSatisfy(\.isWhitespace) { return false }
            setFilter(filterText + typed, store)
        }
        return true
    }

    private func perform<T>(_ value: T?, _ action: (T) -> Void) -> Bool {
        guard let value else { return false }
        action(value)
        return true
    }

    /// Not a control character or one of AppKit's function-key codes (Tab, F1, Page Up…).
    private func isText(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }
    }

    private func setFilter(_ text: String, _ store: ServerStore) {
        filterText = text
        let items = items(in: store)
        // The best guess is ready for Return; back to nothing once the filter is gone.
        selection = filter.isEmpty ? nil : items.first?.id
        if !filter.isEmpty {
            let count = items.filter { $0.id == $0.rowID }.count
            announce(items.isEmpty ? "No matches" : "\(count) matching, \(items[0].spokenName)")
        }
    }

    private func select(_ id: String?, _ items: [ListItem]) {
        selection = id
        if let item = items.first(where: { $0.id == id }) { announce(item.spokenName) }
    }

    private func announce(_ text: String) { AccessibilityNotification.Announcement(text).post() }

    // MARK: Actions

    private func open(_ item: ListItem, _ store: ServerStore) {
        switch item {
        case .server(let s) where store.stopStates[s.id] != .stopping: Actions.open(store.url(for: s))
        case .container(let c) where c.isHTTP && store.stopStates[c.id] != .stopping: Actions.open(c.url)
        case .container(let c) where !c.isHTTP: return copy(item, store)
        case .otherPort(_, let url?, _, _): Actions.open(url)
        case .otherPort(_, nil, _, _): return copy(item, store)
        default: return
        }
        dismiss()
    }

    private func copy(_ item: ListItem, _ store: ServerStore) {
        let text = switch item {
        case .server(let s): store.url(for: s).absoluteString
        case .container(let c): c.isHTTP ? c.url.absoluteString : c.address
        case .otherPort(let port, let url, _, _): url?.absoluteString ?? "localhost:\(port)"
        }
        Actions.copy(text)
        flashCopied(item.id)
        announce("Copied \(text)")
    }

    private func stopServer(_ item: ListItem, _ store: ServerStore) {
        switch item {
        case .server(let s):
            // As with the mouse: Stop first, then Force Quit if it's still running.
            if case .needsForceQuit = store.stopStates[s.id] { store.forceQuit(s) } else { store.stop(s) }
        case .container(let c): store.stop(c)
        case .otherPort: break
        }
    }

    private func expand(_ item: ListItem, _ store: ServerStore, _ show: Bool) {
        let row = item.rowID
        guard store.isExpanded(row) != show, show == false || hasOtherPorts(item) else { return }
        if !show { selection = row }
        withAnimation(.snappy(duration: 0.2)) { store.toggleExpanded(row) }
    }

    private func hasOtherPorts(_ item: ListItem) -> Bool {
        switch item {
        case .server(let s): !s.secondaryPorts.isEmpty
        case .container(let c): !c.secondaryPorts.isEmpty
        case .otherPort: false
        }
    }
}

extension ContainerServer {
    /// nil for databases and other non-HTTP services.
    func url(port: UInt16) -> URL? { isHTTP ? URL(string: "http://localhost:\(port)") : nil }
}

/// What has been typed, under the header.
struct FilterBar: View {
    let keyboard: PopoverKeyboard
    let matches: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text(keyboard.filterText).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            Text(matches == 1 ? "1 match" : "\(matches) matches").foregroundStyle(.secondary).monospacedDigit()
            Button { keyboard.clear() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear (Esc)")
            .accessibilityLabel("Clear filter")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Layout.rowRadius, style: .continuous).fill(Color.primary.opacity(0.07)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter: \(keyboard.filterText)")
    }
}
