import AppKit
import SwiftUI

/// Keeps the MenuBarExtra `.window` exactly as tall as its content, top edge pinned under the
/// menu bar, and in the app's chosen appearance.
///
/// Why: the window grows when content grows but doesn't shrink when it shrinks (rows stopped, the
/// welcome card dismissed), and SwiftUI's own sizing pass can run after ours and push it back to
/// a stale height. So the fitter remembers the content height and refits whenever the window
/// resizes or becomes key, which makes it self-correcting. The window also follows the menu bar's
/// appearance by default, not the app's, so the app's appearance is set on it explicitly.
struct FitWindowToContent: ViewModifier {
    @State private var fitter = WindowFitter()

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(WindowAccessor { fitter.attach($0) })
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                fitter.contentHeight = height
                fitter.fit()
            }
    }
}

extension View {
    func fitWindowToContent() -> some View { modifier(FitWindowToContent()) }
}

/// Holds the window (weakly) and the last measured content height, without SwiftUI observing them.
@MainActor
final class WindowFitter {
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    var contentHeight: CGFloat = 0

    func attach(_ newWindow: NSWindow?) {
        guard newWindow !== window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        window = newWindow
        guard let newWindow else { return }
        // Snapshot renders set their own light/dark per image; don't override them.
        if Snapshots.directory == nil { newWindow.appearance = AppAppearance.current.nsAppearance }
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fit() }
            })
        }
        fit()
    }

    func fit() {
        guard let w = window, contentHeight > 0 else { return }
        let current = w.contentRect(forFrameRect: w.frame).height
        let delta = current - contentHeight
        guard abs(delta) > 0.5 else { return }   // also ends the didResize → fit loop
        var frame = w.frame
        frame.size.height -= delta
        frame.origin.y += delta                   // keep the top edge where it is
        w.setFrame(frame, display: true, animate: false)
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Tracker(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Tracker: NSView {
        let onWindow: @MainActor (NSWindow?) -> Void
        init(onWindow: @escaping @MainActor (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}
