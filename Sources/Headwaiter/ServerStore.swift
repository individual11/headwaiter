import AppKit
import Darwin
import Observation
import HeadwaiterCore

/// Servers that share a project, in display order.
struct ProjectGroup: Identifiable, Equatable {
    var project: Project
    var servers: [Server]
    var containers: [ContainerServer] = []
    var id: String { project.rootPath }
    var hasDeniedAccess: Bool { servers.contains(where: \.package.accessDenied) }
}

/// Where a Stop click is in its life.
enum StopState: Equatable {
    /// SIGTERM sent; waiting for the processes to exit (up to 3 s).
    case stopping
    /// Still alive after 3 s; the row offers Force Quit (SIGKILL) for these.
    case needsForceQuit(StopPlan)
    /// The kernel refused, e.g. another user's process. Cleared when the popover closes.
    case failed(String)
}

enum Preferences {
    /// Send SIGKILL automatically when a server ignores SIGTERM for 3 s. Off by default.
    static let autoForceQuitKey = "autoForceQuit"
    static var autoForceQuit: Bool { UserDefaults.standard.bool(forKey: autoForceQuitKey) }
    /// Show project icons (favicons) on rows instead of framework marks. On by default.
    static let showFaviconsKey = "showFavicons"
    static var showFavicons: Bool { UserDefaults.standard.object(forKey: showFaviconsKey) as? Bool ?? true }
    /// When the project files have no icon, ask the running server for /favicon.ico. On by default.
    static let fetchFaviconsKey = "fetchFavicons"
    static var fetchFavicons: Bool { UserDefaults.standard.object(forKey: fetchFaviconsKey) as? Bool ?? true }
    /// Notify when a server starts, or stops by itself. Off by default.
    static let notifyStartedKey = "notifyStarted"
    static var notifyStarted: Bool { UserDefaults.standard.bool(forKey: notifyStartedKey) }
    static let notifyStoppedKey = "notifyStopped"
    static var notifyStopped: Bool { UserDefaults.standard.bool(forKey: notifyStoppedKey) }
    /// Keep a log of starts and stops. Off by default.
    static let keepLogKey = "keepLog"
    static var keepLog: Bool { UserDefaults.standard.bool(forKey: keepLogKey) }
    /// Bundle identifier of the terminal to open folders in; empty for the Mac's default.
    static let terminalKey = "terminal"
    static var terminal: String { UserDefaults.standard.string(forKey: terminalKey) ?? "" }
}

/// Polls the scanner, publishes the visible servers, runs Stop, and keeps history.
///
/// Polling: every 2 s while the popover is open, 5 s otherwise, and immediately when the
/// popover opens, the Mac wakes, or a watched server process exits (kqueue, at most once
/// a second). Scans run off the main thread; results are applied only when they differ.
@MainActor
@Observable
final class ServerStore {
    /// Visible servers (hidden ports and projects removed).
    private(set) var servers: [Server] = []
    /// Visible Docker containers with published ports.
    private(set) var containers: [ContainerServer] = []
    private(set) var groups: [ProjectGroup] = []
    private(set) var lastScan: Date?
    private(set) var stopStates: [Server.ID: StopState] = [:]
    /// Rows (server or container IDs) whose other ports are shown. Kept for the session only.
    private(set) var expandedRows: Set<String> = []
    /// Project icons for rows.
    @ObservationIgnored let favicons = FaviconStore()
    /// Something started, or exited without the app stopping it, since the popover last closed.
    private(set) var hasChanges = false
    private(set) var state: PersistedState {
        didSet { if isLive && state != oldValue { StateFile.save(state) } }
    }

    var isPopoverOpen = false {
        didSet {
            guard isPopoverOpen != oldValue else { return }
            isPopoverOpen ? popoverOpened() : popoverClosed()
            if isLive { restart() }
        }
    }

    /// Set HW_DEBUG=1 to log scans, exits and stops to stderr.
    static let debug = ProcessInfo.processInfo.environment["HW_DEBUG"] != nil
    static let openInterval: Duration = .seconds(2)
    static let closedInterval: Duration = .seconds(5)
    static let forceQuitDelay: Duration = .seconds(3)
    /// Servers younger than this don't light the menu bar dot (agent test runs, crash loops).
    static let changeThreshold: TimeInterval = 10
    /// Servers must run this long to be remembered as "recently stopped".
    static let historyThreshold: TimeInterval = 30
    static let copyHintOpens = 10

    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var allServers: [Server] = []
    @ObservationIgnored private var allContainers: [ContainerServer] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var exitWatcher: ExitWatcher?
    @ObservationIgnored private var exitRefresh: Task<Void, Never>?
    @ObservationIgnored private var scansStarted = 0
    @ObservationIgnored private var lastAppliedScan = 0
    /// Popover-close time; servers that started after it are NEW. nil until the first close.
    @ObservationIgnored private(set) var lastClosedAt: Date?
    /// Server IDs at the last popover close (or first scan): the baseline for the dot.
    @ObservationIgnored private var baselineIDs: Set<Server.ID> = []
    @ObservationIgnored private var appStoppedIDs: Set<Server.ID> = []
    /// Runs even with notifications off, so turning them on doesn't report old news.
    @ObservationIgnored private var changeTracker = ChangeTracker()
    /// Also runs with the log off, for the same reason.
    @ObservationIgnored private var logTracker = LogTracker()

    init(live: Bool = true) {
        isLive = live
        state = live ? StateFile.load() : PersistedState()
        guard live else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        }
        exitWatcher = ExitWatcher { [weak self] pid in self?.processExited(pid) }
        restart()
    }

    // MARK: - Derived

    func isNew(_ server: Server) -> Bool {
        guard let closed = lastClosedAt else { return false }
        return server.startTime > closed.timeIntervalSince1970
    }

    /// Up to 5 servers stopped in the last 24 h that aren't running again.
    var recentlyStopped: [StoppedServer] {
        let cutoff = Date().addingTimeInterval(-86_400)
        return state.recentlyStopped
            .filter { entry in entry.stoppedAt > cutoff && !allServers.contains(where: entry.matches) }
            .prefix(5)
            .map { $0 }
    }

    /// Everything shown in the list: processes plus containers.
    var itemCount: Int { servers.count + containers.count }
    var isEmpty: Bool { servers.isEmpty && containers.isEmpty }

    /// IDs of everything running, for the change dot and its baseline.
    private var allIDs: Set<String> { Set(allServers.map(\.id)).union(allContainers.map(\.id)) }

    var showCopyHint: Bool { state.popoverOpenCount <= Self.copyHintOpens }
    var hiddenItems: HiddenItems { state.hidden }
    var hasDeniedAccess: Bool { servers.contains(where: \.package.accessDenied) }

    // MARK: - Polling

    /// Scans now, then resumes polling at the interval that fits the popover state.
    func restart() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: self.isPopoverOpen ? Self.openInterval : Self.closedInterval)
            }
        }
    }

    func refresh() async {
        let start = ContinuousClock.now
        scansStarted += 1
        let scan = scansStarted
        let gated = !state.hasSeenWelcome
        let (result, found) = await Task.detached(priority: .utility) {
            (Self.scan(gateProtectedFolders: gated), Self.scanContainers())
        }.value
        // A rescan can overtake a slower one; its older picture would look like stops and starts.
        guard scan > lastAppliedScan else { return }
        lastAppliedScan = scan
        let firstScan = lastScan == nil
        lastScan = Date()
        log("scan: \(result.count) servers, \(found?.count ?? 0) containers in \(ContinuousClock.now - start), open=\(isPopoverOpen)")
        apply(result, containers: found ?? [], firstScan: firstScan)
        logChanges(dockerAnswered: found != nil)
    }

    private func apply(_ result: [Server], containers found: [ContainerServer], firstScan: Bool = false) {
        var changed = false
        if result != allServers {
            recordStopped(previous: allServers, current: result)
            allServers = result
            exitWatcher?.watch(Set(result.flatMap { [$0.rootPID] + $0.listenerPIDs }))
            changed = true
        }
        if found != allContainers {
            allContainers = found
            changed = true
        }
        if firstScan { baselineIDs = allIDs }
        if changed {
            publishVisible()
            let ids = allIDs
            stopStates = stopStates.filter { ids.contains($0.key) }
        }
        if isLive { favicons.update(servers: servers, containers: containers, gated: !state.hasSeenWelcome) }
        updateChangeDot()
        if isLive { notifyChanges() }
    }

    private func notifyChanges() {
        let hidden = state.hidden
        let items = allServers.map { server in
            RunningItem(id: server.id, key: "\(server.package.path):\(server.primaryPort)",
                        name: server.package.name, project: server.project.displayName,
                        port: server.primaryPort, url: url(for: server), startTime: server.startTime,
                        isHidden: hidden.hides(server))
        } + allContainers.map { container in
            RunningItem(id: container.id, key: "container:\(container.name):\(container.primaryPort)",
                        name: container.name, project: container.project?.displayName ?? "Docker",
                        port: container.primaryPort, url: container.isHTTP ? container.url : nil,
                        startTime: container.startTime, isHidden: hidden.hides(container))
        }
        let changes = changeTracker.update(items, now: Date().timeIntervalSince1970)
        // With the popover open, the change is already on screen.
        if !changes.isEmpty && !isPopoverOpen { Notifier.shared.post(changes) }
    }

    private func logChanges(dockerAnswered: Bool) {
        let hidden = state.hidden
        let items = allServers.map { server in
            LogItem(id: server.id, key: "\(server.package.path):\(server.primaryPort)",
                    name: server.package.name, project: server.project.displayName,
                    kind: server.framework?.name ?? server.runtime, port: server.primaryPort,
                    process: ProcessIdentity(server.root), path: server.package.path,
                    startTime: server.startTime, isHidden: hidden.hides(server))
        } + allContainers.map { container in
            LogItem(id: container.id, key: "container:\(container.name):\(container.primaryPort)",
                    name: container.name, project: container.project?.displayName ?? "Docker",
                    kind: container.imageShortName, port: container.primaryPort,
                    startTime: container.startTime, isHidden: hidden.hides(container))
        }
        let processes = LiveProcessSource()
        let events = logTracker.update(items, now: Date().timeIntervalSince1970) { item in
            item.process.map { $0.isAlive(in: processes) } ?? !dockerAnswered
        }
        if Preferences.keepLog { LogStore.shared.append(events) }
    }

    /// Stopping failed: say so on the row, and let a later exit count as news.
    private func stopFailed(_ id: String, _ message: String) {
        stopStates[id] = .failed(message)
        changeTracker.stopFailed(id: id)
        logTracker.stopFailed(id: id)
    }

    private func publishVisible() {
        let hidden = state.hidden
        let visible = allServers.filter { !hidden.hides($0) }.map(hidden.trimmed)
        let visibleContainers = allContainers.filter { !hidden.hides($0) }.map(hidden.trimmed)
        if visible != servers || visibleContainers != containers {
            servers = visible
            containers = visibleContainers
            groups = Self.group(visible, containers: visibleContainers)
        }
    }

    /// Remember servers that disappeared after running long enough to matter.
    private func recordStopped(previous: [Server], current: [Server]) {
        let currentIDs = Set(current.map(\.id))
        let now = Date()
        var history = state.recentlyStopped
        for gone in previous where !currentIDs.contains(gone.id)
            && now.timeIntervalSince1970 - gone.startTime >= Self.historyThreshold {
            history.removeAll { $0.packagePath == gone.package.path && $0.port == gone.primaryPort }
            history.insert(StoppedServer(gone, stoppedAt: now), at: 0)
        }
        if history != state.recentlyStopped { state.recentlyStopped = Array(history.prefix(20)) }
    }

    var showWelcome: Bool { !state.hasSeenWelcome }

    /// Re-run icon lookups after a Settings change (or clear them when icons are turned off).
    func refreshFavicons() {
        favicons.reset()
        if isLive { favicons.update(servers: servers, containers: containers, gated: !state.hasSeenWelcome) }
    }

    /// Dismisses the first-run card and rescans with full folder access (macOS may prompt now).
    func finishWelcome() {
        state.hasSeenWelcome = true
        favicons.reset()   // icons in protected folders can be read now
        if isLive { restart() }
    }

    private func updateChangeDot() {
        guard !isPopoverOpen else { hasChanges = false; return }
        // Until the welcome card has been seen, the dot invites the first click.
        if !state.hasSeenWelcome { hasChanges = true; return }
        let now = Date().timeIntervalSince1970
        let current = allIDs
        let settled = Set(allServers.filter { now - $0.startTime >= Self.changeThreshold }.map(\.id))
            .union(allContainers.filter { now - $0.startTime >= Self.changeThreshold }.map(\.id))
        let started = settled.subtracting(baselineIDs)
        let exited = baselineIDs.subtracting(current).subtracting(appStoppedIDs)
        let changed = !started.isEmpty || !exited.isEmpty
        if changed != hasChanges { hasChanges = changed }
    }

    private func popoverOpened() {
        hasChanges = false
        state.popoverOpenCount += 1
    }

    private func popoverClosed() {
        lastClosedAt = Date()
        baselineIDs = allIDs
        appStoppedIDs = []
        stopStates = stopStates.filter { if case .failed = $0.value { return false } else { return true } }
    }

    /// Several processes of one server exit together (npm and node); rescan once. At most one
    /// exit-triggered rescan per second, so short-lived listeners can't cause a rescan loop.
    private func processExited(_ pid: Int32) {
        log("exit: \(pid)")
        guard exitRefresh == nil else { return }
        let sinceLast = lastScan.map { Date().timeIntervalSince($0) } ?? 1
        let delay = max(0.05, 1 - sinceLast)
        exitRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.exitRefresh = nil
            self?.restart()
        }
    }

    /// Until the first-run card is dismissed, protected folders are skipped so macOS doesn't
    /// prompt before the user knows why.
    nonisolated static func scan(gateProtectedFolders: Bool = false) -> [Server] {
        let fs: FileReading = gateProtectedFolders ? ProtectedFolderGate(LocalFileSystem()) : LocalFileSystem()
        return Resolver(fs: fs).resolve(LiveProcessSource()).servers
    }

    /// Docker containers with published ports; nil if Docker isn't running or didn't answer.
    nonisolated static func scanContainers() -> [ContainerServer]? {
        DockerSocketSource().runningContainers().map(ContainerResolver.servers)
    }

    /// Project root for containers that aren't part of a Compose project.
    nonisolated static let dockerGroupRoot = "docker://"

    /// Servers arrive sorted by project; keep that order and group consecutive runs. Compose
    /// containers join the card of the project in the same folder (or get their own); the rest
    /// go in a "Docker" card at the end.
    static func group(_ servers: [Server], containers: [ContainerServer] = []) -> [ProjectGroup] {
        var groups: [ProjectGroup] = []
        for s in servers {
            if groups.last?.project.rootPath == s.project.rootPath {
                groups[groups.count - 1].servers.append(s)
            } else {
                groups.append(ProjectGroup(project: s.project, servers: [s]))
            }
        }
        for c in containers {
            let project = c.project ?? Project(rootPath: dockerGroupRoot, name: "Docker")
            if let i = groups.firstIndex(where: { $0.project.rootPath == project.rootPath }) {
                groups[i].containers.append(c)
            } else {
                groups.append(ProjectGroup(project: project, servers: [], containers: [c]))
            }
        }
        // Keep the catch-all Docker card last.
        if let i = groups.firstIndex(where: { $0.project.rootPath == dockerGroupRoot }) {
            groups.append(groups.remove(at: i))
        }
        return groups
    }

    // MARK: - Containers

    /// `docker stop` semantics (SIGTERM, then SIGKILL after 10 s inside Docker); the row goes
    /// away on the next scan.
    func stop(_ container: ContainerServer) {
        let id = container.id
        if stopStates[id] == .stopping { return }
        stopStates[id] = .stopping
        appStoppedIDs.insert(id)
        changeTracker.willStop(id: id)
        logTracker.willStop(id: id, .headwaiter)
        Task {
            let ok = await Task.detached { DockerSocketSource().stop(id, kill: false) }.value
            log("stop container \(container.name): \(ok)")
            if ok { restart() } else { stopFailed(id, "Docker didn't stop the container") }
        }
    }

    // MARK: - URLs

    /// The URL a row opens: the user's override if set, else the detected one.
    func url(for server: Server) -> URL {
        state.urlOverrides[server.package.path]?.url(defaultPort: server.primaryPort) ?? server.url
    }

    func hasURLOverride(_ server: Server) -> Bool { state.urlOverrides[server.package.path] != nil }

    /// Returns false if the text isn't a usable URL.
    @discardableResult
    func setURL(_ text: String, for server: Server) -> Bool {
        guard let override = URLOverride(text: text, serverPort: server.primaryPort) else { return false }
        state.urlOverrides[server.package.path] = override
        return true
    }

    func resetURL(for server: Server) { state.urlOverrides[server.package.path] = nil }

    // MARK: - Hide and history

    func isExpanded(_ id: String) -> Bool { expandedRows.contains(id) }
    func toggleExpanded(_ id: String) {
        if expandedRows.remove(id) == nil { expandedRows.insert(id) }
    }

    func hidePort(_ port: UInt16) { state.hidden.ports.insert(port); publishVisible() }
    func hideProject(_ root: String) { state.hidden.projects.insert(root); publishVisible() }
    func unhidePort(_ port: UInt16) { state.hidden.ports.remove(port); publishVisible() }
    func unhideProject(_ root: String) { state.hidden.projects.remove(root); publishVisible() }
    func forget(_ entry: StoppedServer) { state.recentlyStopped.removeAll { $0.id == entry.id } }
    func clearHistory() { state.recentlyStopped = [] }

    // MARK: - Stop

    private enum SignalOutcome: Sendable {
        case signalled(StopPlan)
        case gone
        case failed(String)
    }

    /// SIGTERM to the server's subtree. The row disappears when the processes exit; if they're
    /// still alive after 3 s, offer Force Quit (or do it, if the setting is on).
    func stop(_ server: Server) {
        let id = server.id
        if stopStates[id] == .stopping { return }
        stopStates[id] = .stopping
        appStoppedIDs.insert(id)
        changeTracker.willStop(id: id)
        logTracker.willStop(id: id, .headwaiter)

        Task {
            let outcome = await Task.detached { () -> SignalOutcome in
                guard let plan = Stopper.plan(for: server, source: LiveProcessSource()) else { return .gone }
                switch Stopper.signal(SIGTERM, plan, source: LiveProcessSource()) {
                case .success: return .signalled(plan)
                case .failure(.alreadyExited): return .gone
                case .failure(let f): return .failed(f.description)
                }
            }.value
            log("stop \(server.package.name): \(outcome)")

            switch outcome {
            case .gone:
                restart()
            case .failed(let message):
                stopFailed(id, message)
            case .signalled(let plan):
                try? await Task.sleep(for: Self.forceQuitDelay)
                guard stopStates[id] == .stopping else { return }
                let survivors = await Task.detached { Stopper.survivors(of: plan, source: LiveProcessSource()) }.value
                guard let survivors else { restart(); return }
                if Preferences.autoForceQuit {
                    forceQuit(id: id, survivors)
                } else {
                    stopStates[id] = .needsForceQuit(survivors)
                }
            }
        }
    }

    func forceQuit(_ server: Server) {
        guard case .needsForceQuit(let plan) = stopStates[server.id] else { return }
        forceQuit(id: server.id, plan)
    }

    private func forceQuit(id: Server.ID, _ plan: StopPlan) {
        stopStates[id] = .stopping
        logTracker.willStop(id: id, .forceQuit)
        Task {
            let result = await Task.detached { Stopper.signal(SIGKILL, plan, source: LiveProcessSource()) }.value
            log("force quit: \(result)")
            if case .failure(let f) = result, f != .alreadyExited {
                stopFailed(id, f.description)
            } else {
                restart()
            }
        }
    }

    // MARK: - Preview (snapshot rendering)

    /// Puts a non-live store into a given state for rendering screenshots of the UI.
    func preview(servers: [Server], stopStates: [Server.ID: StopState] = [:], newSince: Date? = nil,
                 recentlyStopped: [StoppedServer] = [], openCount: Int = 20, hidden: HiddenItems = HiddenItems(),
                 welcome: Bool = false, containers: [ContainerServer] = [], icons: [String: NSImage] = [:],
                 expanded: Set<String> = []) {
        favicons.preview(icons)
        expandedRows = expanded
        lastScan = Date()
        lastClosedAt = newSince
        state = PersistedState(recentlyStopped: recentlyStopped, hidden: hidden, popoverOpenCount: openCount)
        state.hasSeenWelcome = !welcome
        allServers = servers
        allContainers = containers
        publishVisible()
        self.stopStates = stopStates
    }

    private func log(_ message: @autoclosure () -> String) {
        if Self.debug { FileHandle.standardError.write(Data((message() + "\n").utf8)) }
    }
}
