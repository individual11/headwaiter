import AppKit
import Observation
import Sparkle

/// Automatic updates with Sparkle.
///
/// Only release builds can update: `scripts/build-app.sh` leaves the feed address and public key
/// out of Info.plist otherwise, so a build of your own is never replaced by the published one.
///
/// Sparkle asks before it checks automatically. A scheduled update doesn't interrupt with a
/// window: the popover footer and the right-click menu offer it until it's opened.
@MainActor
@Observable
final class Updater: NSObject {
    static let shared = Updater()

    /// Version of an update found in the background and not opened yet.
    private(set) var availableVersion: String?
    /// False for builds that can't update; they show no update controls.
    private(set) var isAvailable: Bool
    /// Mirrors Sparkle's own setting, which its first-run question also changes.
    private(set) var checksAutomatically = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    override init() {
        isAvailable = Self.isConfigured(Bundle.main.infoDictionary ?? [:])
        super.init()
    }

    /// Snapshot rendering: show given state without starting Sparkle.
    init(previewVersion: String?) {
        isAvailable = true
        checksAutomatically = true
        availableVersion = previewVersion
        super.init()
    }

    private static func isConfigured(_ info: [String: Any]) -> Bool {
        ["SUFeedURL", "SUPublicEDKey"].allSatisfy { (info[$0] as? String)?.isEmpty == false }
    }

    func start() {
        guard isAvailable, controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        observation = controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            // Sparkle changes this on the main thread only.
            MainActor.assumeIsolated {
                guard let self, let updater = self.controller?.updater else { return }
                self.checksAutomatically = updater.automaticallyChecksForUpdates
            }
        }
    }

    func setChecksAutomatically(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    /// Checks now, or brings an update that was already found to the front.
    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }
}

/// Sparkle calls these on the main thread; the protocol just isn't annotated.
extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false   // never a window the user didn't ask for
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated { availableVersion = version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { availableVersion = nil }
    }
}
