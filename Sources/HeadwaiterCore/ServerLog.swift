import Foundation

/// A running server or container, as the log describes it. No arguments or environment: those
/// can hold secrets, and the log is a file people may share.
public struct LogItem: Hashable, Sendable {
    /// PID plus start time, or the container ID.
    public var id: String
    /// Stays the same across restarts: the same package (or container) on the same port.
    public var key: String
    public var name: String
    public var project: String
    /// Framework, runtime or image: "Next.js", "node", "postgres:16".
    public var kind: String
    public var port: UInt16
    /// nil for containers.
    public var process: ProcessIdentity?
    /// Package folder; nil for containers.
    public var path: String?
    public var startTime: Double
    /// Hidden items are tracked, so hiding one doesn't look like a stop, but never logged.
    public var isHidden: Bool

    public init(id: String, key: String, name: String, project: String, kind: String, port: UInt16,
                process: ProcessIdentity? = nil, path: String? = nil, startTime: Double, isHidden: Bool = false) {
        self.id = id
        self.key = key
        self.name = name
        self.project = project
        self.kind = kind
        self.port = port
        self.process = process
        self.path = path
        self.startTime = startTime
        self.isHidden = isHidden
    }
}

/// One line of the log.
public struct LogEvent: Equatable, Sendable {
    public enum StopSource: Sendable {
        case headwaiter, forceQuit
    }

    public enum Change: Equatable, Sendable {
        case started
        /// nil: something other than Headwaiter stopped it, or it exited by itself.
        case stopped(StopSource?)
    }

    public var change: Change
    public var item: LogItem
    public var time: Double

    public init(_ change: Change, _ item: LogItem, time: Double) {
        self.change = change
        self.item = item
        self.time = time
    }

    /// `2026-11-23 17:45:02  Started  web (shop)  Next.js  localhost:3000  PID 812  ~/code/shop/web`
    public func line(timeZone: TimeZone = .current, home: String = NSHomeDirectory()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let hasProject = !item.project.isEmpty && item.project != item.name
        var fields = [
            formatter.string(from: Date(timeIntervalSince1970: time)),
            change == .started ? "Started" : "Stopped",
            hasProject ? "\(item.name) (\(item.project))" : item.name,
            item.kind,
            "localhost:\(item.port)",
        ]
        if let process = item.process { fields.append("PID \(process.pid)") }
        switch change {
        case .started:
            if let path = item.path { fields.append(Display.abbreviatingHome(path, home: home)) }
        case .stopped(let source):
            fields.append("ran \(Display.uptime(since: item.startTime, now: Date(timeIntervalSince1970: time)))")
            switch source {
            case .headwaiter: fields.append("stopped from Headwaiter")
            case .forceQuit: fields.append("force quit from Headwaiter")
            case nil: break
            }
        }
        // Names come from files in projects; a line break in one must not start a new line.
        return fields.filter { !$0.isEmpty }.map(Self.singleLine).joined(separator: "  ")
    }

    private static func singleLine(_ text: String) -> String {
        let breaks = CharacterSet.controlCharacters.union(.newlines)
        return String(String.UnicodeScalarView(text.unicodeScalars.map { breaks.contains($0) ? " " : $0 }))
    }
}

/// Turns successive scans into log events. Unlike `ChangeTracker`, it reports every start and
/// stop it sees, right away, including short runs and restarts. Not reported:
/// - what's already running on the first scan,
/// - a server that briefly stops listening while its process lives on (or Docker not answering),
///   if it's back within `gapGrace`,
/// - a server whose wrapper exited and that now shows under a different process.
public struct LogTracker: Sendable {
    public static let gapGrace: TimeInterval = 10

    private var known: [String: LogItem] = [:]
    /// Not listed, but still alive, by ID.
    private var waiting: [String: (item: LogItem, since: Double)] = [:]
    private var sources: [String: LogEvent.StopSource] = [:]
    private var lastUpdate: Double?

    public init() {}

    /// The user is stopping this item from the app.
    public mutating func willStop(id: String, _ source: LogEvent.StopSource) { sources[id] = source }
    public mutating func stopFailed(id: String) { sources[id] = nil }

    /// `isAlive` is asked only about items that are no longer listed.
    public mutating func update(_ items: [LogItem], now: Double, isAlive: (LogItem) -> Bool) -> [LogEvent] {
        let current = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let previous = lastUpdate else {
            lastUpdate = now
            known = current
            return []
        }
        lastUpdate = now

        for (id, item) in known where current[id] == nil { waiting[id] = (item, now) }
        var added = current.values.filter { known[$0.id] == nil && waiting[$0.id] == nil }
        for id in current.keys { waiting[id] = nil }
        known = current

        // The same server under another of its processes: the new one was running all along.
        for (id, gone) in waiting {
            guard let i = added.firstIndex(where: { $0.key == gone.item.key && $0.startTime < previous }) else { continue }
            added.remove(at: i)
            waiting[id] = nil
            sources[id] = nil
        }

        var stopped: [LogEvent] = []
        for (id, gone) in waiting where !isAlive(gone.item) || now - gone.since >= Self.gapGrace {
            waiting[id] = nil
            let source = sources.removeValue(forKey: id)
            if !gone.item.isHidden { stopped.append(LogEvent(.stopped(source), gone.item, time: now)) }
        }
        let started = added.filter { !$0.isHidden }.map { LogEvent(.started, $0, time: now) }
        return stopped.sorted { $0.item.key < $1.item.key } + started.sorted { $0.item.key < $1.item.key }
    }
}

/// The log on disk: plain text, one line per event, readable only by the user. Once it passes
/// `maxBytes`, the oldest half goes.
public struct LogFile: Sendable {
    public var url: URL
    public var maxBytes: Int

    public init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    public func lines() -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// Returns true if older lines were dropped to make room.
    @discardableResult
    public func append(_ lines: [String]) throws -> Bool {
        guard !lines.isEmpty else { return false }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        var size = try handle.seekToEnd()
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        try handle.write(contentsOf: data)
        size += UInt64(data.count)
        guard size > UInt64(maxBytes) else { return false }

        // Keep the newest half, from the start of a line.
        try handle.seek(toOffset: size - UInt64(maxBytes / 2))
        let tail = try handle.readToEnd() ?? Data()
        let kept = tail.firstIndex(of: UInt8(ascii: "\n")).map { tail[tail.index(after: $0)...] } ?? tail[...]
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: kept)
        try handle.truncate(atOffset: UInt64(kept.count))
        return true
    }

    /// Deletes the file; the next append starts a new one.
    public func clear() throws {
        do { try FileManager.default.removeItem(at: url) } catch CocoaError.fileNoSuchFile {}
    }
}
