import AppKit

/// The app's color appearance: follow macOS, or force light or dark. Applied to NSApp, so the
/// popover and Settings window switch live. The menu bar icon is a template image and always
/// follows the menu bar, which macOS controls.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil // inherit from macOS
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    @MainActor
    static func apply(_ appearance: AppAppearance = current) {
        NSApp.appearance = appearance.nsAppearance
        // Windows that set their own appearance (the menu bar popover follows the menu bar by
        // default) don't inherit from NSApp, so update open ones too.
        for window in NSApp.windows where !String(describing: type(of: window)).contains("StatusBarWindow") {
            window.appearance = appearance.nsAppearance
        }
    }
}
