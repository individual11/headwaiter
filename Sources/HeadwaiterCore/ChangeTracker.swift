import Foundation

/// A running server or container, as far as start and stop notifications care.
public struct RunningItem: Hashable, Sendable {
    /// Changes when the server restarts.
    public var id: String
    /// Stays the same across restarts: the same package (or container) on the same port.
    public var key: String
    public var name: String
    public var project: String
    public var port: UInt16
    /// Opened when its notification is clicked; nil for databases and the like.
    public var url: URL?
    public var startTime: Double
    /// Hidden items are tracked, so hiding one doesn't look like a stop, but never reported.
    public var isHidden: Bool

    public init(id: String, key: String, name: String, project: String, port: UInt16, url: URL?,
                startTime: Double, isHidden: Bool = false) {
        self.id = id
        self.key = key
        self.name = name
        self.project = project
        self.port = port
        self.url = url
        self.startTime = startTime
        self.isHidden = isHidden
    }
}

/// Turns successive scans into the starts and stops worth telling someone about:
/// - what's already running on the first scan isn't news,
/// - a server counts as started once it has run for `settleTime`, so short test runs stay quiet,
/// - one that comes back within `restartGrace` restarted, which is neither a stop nor a start,
/// - stopping a server from the app isn't reported back.
public struct ChangeTracker: Sendable {
    public static let settleTime: TimeInterval = 10
    public static let restartGrace: TimeInterval = 10

    public struct Changes: Equatable, Sendable {
        public var started: [RunningItem] = []
        public var stopped: [RunningItem] = []
        public var isEmpty: Bool { started.isEmpty && stopped.isEmpty }
        public init(started: [RunningItem] = [], stopped: [RunningItem] = []) {
            self.started = started
            self.stopped = stopped
        }
    }

    /// Running and settled (or there from the first scan), by key.
    private var known: [String: RunningItem] = [:]
    /// Known, then gone, and not back yet, by key.
    private var missing: [String: (item: RunningItem, since: Double)] = [:]
    private var stoppedHere: Set<String> = []
    private var hasBaseline = false

    public init() {}

    /// The user is stopping this item from the app; its exit isn't news.
    public mutating func willStop(id: String) { stoppedHere.insert(id) }
    /// Stopping it failed; a later exit is news again.
    public mutating func stopFailed(id: String) { stoppedHere.remove(id) }

    public mutating func update(_ items: [RunningItem], now: Double) -> Changes {
        let current = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        guard hasBaseline else {
            hasBaseline = true
            known = current
            return Changes()
        }
        var changes = Changes()

        for (key, item) in known where current[key] == nil {
            known[key] = nil
            if stoppedHere.remove(item.id) == nil { missing[key] = (item, now) }
        }
        for (key, item) in current {
            if missing.removeValue(forKey: key) != nil || known[key] != nil {
                // Still running, or back after a restart.
                if let old = known[key], old.id != item.id { stoppedHere.remove(old.id) }
                known[key] = item
            } else if now - item.startTime >= Self.settleTime {
                known[key] = item
                if !item.isHidden { changes.started.append(item) }
            }
        }
        for (key, gone) in missing where now - gone.since >= Self.restartGrace {
            missing[key] = nil
            if !gone.item.isHidden { changes.stopped.append(gone.item) }
        }
        let ids = Set(current.values.map(\.id))
        stoppedHere.formIntersection(ids)

        changes.started.sort { $0.key < $1.key }
        changes.stopped.sort { $0.key < $1.key }
        return changes
    }
}

/// What a notification says. Several changes from one scan share a notification.
public struct ChangeMessage: Equatable, Sendable {
    public var title: String
    public var body: String

    public init?(_ items: [RunningItem], verb: String) {
        guard let first = items.first else { return nil }
        if items.count == 1 {
            title = "\(first.name) \(verb)"
            let address = "localhost:\(first.port)"
            body = first.project.isEmpty || first.project == first.name ? address : "\(first.project) · \(address)"
        } else {
            title = "\(items.count) servers \(verb)"
            let names = items.prefix(3).map(\.name)
            let more = items.count - names.count
            body = names.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
        }
    }
}
