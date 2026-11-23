import AppKit
import SwiftUI

/// The log window. There is one, opened from Settings.
@MainActor
enum LogWindow {
    static let identifier = NSUserInterfaceItemIdentifier("headwaiter-log")
    private static var window: NSWindow?

    static func show() {
        LogStore.shared.reload()
        let window = self.window ?? make()
        self.window = window
        DockPresence.opened(.log)
        window.makeKeyAndOrderFront(nil)
    }

    private static func make() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 420),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Server Log"
        window.identifier = identifier
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LogView())
        window.contentMinSize = NSSize(width: 480, height: 200)
        window.center()
        window.setFrameAutosaveName("ServerLog")
        return window
    }
}

struct LogView: View {
    var log = LogStore.shared
    @AppStorage(Preferences.keepLogKey) private var keepLog = false
    @State private var filter = ""

    private var shown: [String] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? log.lines : log.lines.filter { $0.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        let shown = shown
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Text(count(shown.count))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Show in Finder") { log.revealInFinder() }
                Button("Clear…") { log.confirmClear() }
            }
            .disabled(log.lines.isEmpty)
            .padding(10)
            Divider()
            if shown.isEmpty {
                empty.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LogText(lines: shown)
            }
        }
    }

    @ViewBuilder private var empty: some View {
        if !log.lines.isEmpty {
            ContentUnavailableView("No matching entries", systemImage: "magnifyingglass")
        } else if keepLog {
            ContentUnavailableView("Nothing logged yet", systemImage: "list.bullet.rectangle",
                                   description: Text("Servers appear here as they start and stop."))
        } else {
            ContentUnavailableView("The log is off", systemImage: "list.bullet.rectangle",
                                   description: Text("Turn it on in Settings, under Log."))
        }
    }

    private func count(_ shown: Int) -> String {
        shown == log.lines.count ? Self.entries(shown) : "\(shown.formatted()) of \(Self.entries(log.lines.count))"
    }

    static func entries(_ n: Int) -> String { n == 1 ? "1 entry" : "\(n.formatted()) entries" }
}

/// Read-only, selectable text with one unwrapped line per entry. Stays at the newest entry
/// unless the user scrolled up.
private struct LogText: NSViewRepresentable {
    let lines: [String]

    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.textColor,
    ]

    final class Coordinator { var lines: [String] = [] }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isRichText = false
        text.textContainerInset = NSSize(width: 6, height: 8)
        let unlimited = CGFloat.greatestFiniteMagnitude
        text.isHorizontallyResizable = true
        text.maxSize = NSSize(width: unlimited, height: unlimited)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.size = NSSize(width: unlimited, height: unlimited)
        text.setAccessibilityLabel("Server log")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let old = context.coordinator.lines
        guard lines != old, let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
        context.coordinator.lines = lines
        let atEnd = old.isEmpty || scroll.contentView.bounds.maxY >= text.frame.maxY - 20
        if !old.isEmpty, lines.starts(with: old) {
            // Appending keeps the selection.
            let new = "\n" + lines[old.count...].joined(separator: "\n")
            storage.append(NSAttributedString(string: new, attributes: Self.attributes))
        } else {
            storage.setAttributedString(NSAttributedString(string: lines.joined(separator: "\n"), attributes: Self.attributes))
        }
        guard atEnd else { return }
        // After layout; keeps the horizontal position.
        DispatchQueue.main.async {
            text.layoutSubtreeIfNeeded()
            let clip = scroll.contentView
            let y = max(-clip.contentInsets.top, text.frame.maxY - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            scroll.reflectScrolledClipView(clip)
        }
    }
}
