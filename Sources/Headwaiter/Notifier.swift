import AppKit
import HeadwaiterCore
import Observation
import UserNotifications

/// Posts start and stop notifications, off until turned on in Settings.
///
/// Titles and bodies only hold the server's name, project and port. Nothing is sent anywhere:
/// these are local notifications.
@MainActor
@Observable
final class Notifier: NSObject {
    static let shared = Notifier()

    /// macOS won't show them: turned off in System Settings, or the permission request declined.
    private(set) var isBlocked = false

    /// The notification system needs an app bundle; `swift run` and snapshots don't have one.
    @ObservationIgnored private let center: UNUserNotificationCenter? =
        Bundle.main.bundleURL.pathExtension == "app" && Snapshots.directory == nil ? .current() : nil

    func start() {
        center?.delegate = self
        refreshStatus()
    }

    /// Asks macOS for permission the first time; later calls only update `isBlocked`.
    func requestPermission() {
        center?.requestAuthorization(options: [.alert]) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func refreshStatus() {
        center?.getNotificationSettings { @Sendable [weak self] settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in self?.isBlocked = denied }
        }
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func post(_ changes: ChangeTracker.Changes) {
        if Preferences.notifyStarted { post(changes.started, verb: "started", opensURL: true) }
        if Preferences.notifyStopped { post(changes.stopped, verb: "stopped", opensURL: false) }
    }

    private func post(_ items: [RunningItem], verb: String, opensURL: Bool) {
        guard let center, let message = ChangeMessage(items, verb: verb) else { return }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.threadIdentifier = "servers"
        if opensURL, items.count == 1, let url = items[0].url { content.userInfo["url"] = url.absoluteString }
        // One server's newer notification replaces its older one.
        let id = items.count == 1 ? items[0].key : UUID().uuidString
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show them while Settings is the active window too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let text = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: text), ["http", "https"].contains(url.scheme) {
            Task { @MainActor in Actions.open(url) }
        }
        completionHandler()
    }
}
