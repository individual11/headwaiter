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
/// typing (or ⌘F) filters, ↑↓ select, Return opens, ⌘C (or ⌥Return) copies the URL, ⌘R reveals in
/// Finder, ⌘T opens the terminal, ⌘⌫ stops, →← show and hide other ports, Esc backs out.
///
/// The filter is a real text field. While it has the cursor, the keys that mean something to
/// text (⌘⌫, ←→, ⌘C with text selected) go to it; ↑ or ↓ moves on into the list, and typing
/// comes back.
///
/// Keys come from an event monitor, not SwiftUI focus, so they work as soon as the list opens
/// and wherever Tab has put the focus. Keys it doesn't use pass through untouched.
@MainActor
@Observable
final class PopoverKeyboard {
    private(set) var filterText = ""
    private(set) var selection: String?
    /// The filter was opened with ⌘F or typing, and hasn't been closed or left empty.
    private(set) var searching = false
    /// The row showing "Copied".
    private(set) var copiedID: String?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private weak var window: NSWindow?
    @ObservationIgnored weak var field: FilterField?
    /// ↑ or ↓ chose the row, as opposed to typing having picked the first match. Only then does
    /// ⌘⌫ stop it: while editing text, people use ⌘⌫ to clear the line.
    @ObservationIgnored private var inList = false
    @ObservationIgnored private var store: ServerStore?
    @ObservationIgnored private var dismiss: () -> Void = {}

    var filter: ListFilter { ListFilter(filterText) }
    var showsFilter: Bool { searching || !filterText.isEmpty }

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
        searching = false
        inList = false
        field?.stringValue = ""
        leaveField()
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

    // MARK: Text field

    /// The text being edited, if the filter field has the cursor.
    private var editor: NSTextView? { field?.currentEditor() as? NSTextView }

    /// Puts the cursor in the filter field, after the text. (Focusing a field selects its text,
    /// so the next key would replace it.)
    private func enterField() {
        searching = true
        guard let field, let window, editor == nil, window.makeFirstResponder(field) else { return }
        editor?.setSelectedRange(NSRange(location: (field.stringValue as NSString).length, length: 0))
    }

    private func leaveField() {
        if editor != nil { window?.makeFirstResponder(nil) }
    }

    func fieldFocused() {
        searching = true
        inList = false
    }

    func fieldLeft() {
        if filterText.isEmpty { searching = false }
    }

    func textChanged(_ text: String) {
        guard let store, text != filterText else { return }
        filterText = text
        inList = false
        let items = items(in: store)
        // The best guess is ready for Return; back to nothing once the filter is gone.
        selection = filter.isEmpty ? nil : items.first?.id
        if !filter.isEmpty {
            let count = items.filter { $0.id == $0.rowID }.count
            announce(items.isEmpty ? "No matches" : "\(count) matching, \(items[0].spokenName)")
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
        // An input method is composing text: every key is its own.
        if let editor, editor.hasMarkedText() { return false }

        if modifiers.contains(.command) {
            return handleText(event, modifiers) || (modifiers == .command && handleCommand(event, store))
        }

        let typing = editor != nil
        let items = items(in: store)
        let selected = items.first { $0.id == selection }
        switch event.keyCode {
        case Key.down where modifiers.isEmpty: move(by: 1, items)
        case Key.up where modifiers.isEmpty: move(by: -1, items)
        case Key.right where modifiers.isEmpty && !typing:
            return perform(selected) { expand($0, store, true) }
        case Key.left where modifiers.isEmpty && !typing:
            return perform(selected) { expand($0, store, false) }
        case Key.returnKey, Key.enter:
            // With nothing selected, Return still reaches Continue on the welcome card.
            guard !event.isARepeat, modifiers.isEmpty || modifiers == .option else { return false }
            return perform(selected) { modifiers == .option ? copy($0, store) : open($0, store) }
        case Key.escape where modifiers.isEmpty:
            if showsFilter || selection != nil { clear() } else { dismiss() }
        case Key.delete where modifiers.isEmpty:
            if !typing && !filterText.isEmpty { enterField() }
            return false
        default:
            // Typing starts or goes on in the field, which gets the key itself, so accents and
            // input methods work from the first one.
            if !typing && startsText(event, modifiers) { enterField() }
            return false
        }
        return true
    }

    /// Editing shortcuts. A menu bar app has no Edit menu to provide them.
    private func handleText(_ event: NSEvent, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("f", .command):
            enterField()
            editor?.selectAll(nil)
        case ("a", .command):
            guard showsFilter else { return false }
            enterField()
            editor?.selectAll(nil)
        case ("v", .command):
            enterField()
            editor?.pasteAsPlainText(nil)
        case ("x", .command):
            guard let editor else { return false }
            editor.cut(nil)
        case ("c", .command):
            guard let editor, editor.selectedRange().length > 0 else { return false }
            editor.copy(nil)
        case ("z", .command):
            guard let editor else { return false }
            editor.undoManager?.undo()
            textChanged(editor.string)   // the delegate only hears about typing
        case ("z", [.command, .shift]):
            guard let editor else { return false }
            editor.undoManager?.redo()
            textChanged(editor.string)   // the delegate only hears about typing
        default: return false
        }
        return true
    }

    private func handleCommand(_ event: NSEvent, _ store: ServerStore) -> Bool {
        let selected = items(in: store).first { $0.id == selection }
        if event.keyCode == Key.delete {
            if editor != nil { return false }   // clears the line
            guard inList else {
                // Focus is elsewhere, but the row was only picked by typing: still not a stop.
                if !filterText.isEmpty { clear() }
                return true
            }
            // Holding ⌘⌫ must not go on to force quit what it just stopped.
            return perform(selected) { if !event.isARepeat { stopServer($0, store) } }
        }
        if event.isARepeat { return selected != nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": return perform(selected) { copy($0, store) }
        case "r": return perform(selected?.folder) { Actions.reveal($0) }
        case "t": return perform(selected?.folder) { TerminalApps.shared.open($0) }
        default: return false
        }
    }

    private func perform<T>(_ value: T?, _ action: (T) -> Void) -> Bool {
        guard let value else { return false }
        action(value)
        return true
    }

    private func startsText(_ event: NSEvent, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.isSubset(of: [.shift, .option]), let typed = event.characters else { return false }
        // A space can't start a filter: it presses the focused button.
        if filterText.isEmpty && !typed.isEmpty && typed.allSatisfy(\.isWhitespace) { return false }
        // No characters yet: a dead key, such as ⌥E for an acute accent.
        // Not a control character or one of AppKit's function-key codes (Tab, F1, Page Up…).
        return typed.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        }
    }

    private func move(by step: Int, _ items: [ListItem]) {
        leaveField()
        select(ListSelection.move(selection, by: step, in: items.map(\.id)), items)
        inList = selection != nil
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

/// The search field, under the header. Always there, so a key can be sent on to it, but has no
/// height until it's wanted.
struct FilterBar: View {
    let keyboard: PopoverKeyboard
    let matches: Int

    var body: some View {
        let shown = keyboard.showsFilter
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            FilterTextField(keyboard: keyboard, text: keyboard.filterText)
            if !keyboard.filter.isEmpty {
                Text(matches == 1 ? "1 match" : "\(matches) matches").foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize()
            }
            Button { keyboard.clear() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!shown)
            .help("Clear (Esc)")
            .accessibilityLabel("Clear filter")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Layout.rowRadius, style: .continuous).fill(Color.primary.opacity(0.07)))
        .padding(.horizontal, Layout.cardInset)
        .padding(.bottom, 8)
        .frame(height: shown ? nil : 0, alignment: .top)
        .opacity(shown ? 1 : 0)
        .clipped()
        .accessibilityHidden(!shown)
    }
}

final class FilterField: NSTextField {
    weak var keyboard: PopoverKeyboard?

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if let editor = currentEditor() as? NSTextView {
            // Project names aren't prose.
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.inlinePredictionType = .no
        }
        keyboard?.fieldFocused()
        return true
    }
}

private struct FilterTextField: NSViewRepresentable {
    let keyboard: PopoverKeyboard
    let text: String

    func makeNSView(context: Context) -> FilterField {
        let field = FilterField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "Name, project, framework or port"
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Filter servers")
        field.delegate = context.coordinator
        field.keyboard = keyboard
        keyboard.field = field
        return field
    }

    func updateNSView(_ field: FilterField, context: Context) {
        if field.stringValue != text && field.currentEditor() == nil { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(keyboard: keyboard) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let keyboard: PopoverKeyboard
        init(keyboard: PopoverKeyboard) { self.keyboard = keyboard }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            keyboard.textChanged(field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) { keyboard.fieldLeft() }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Return with no match: stay put, rather than end editing.
            selector == #selector(NSResponder.insertNewline(_:))
        }
    }
}
