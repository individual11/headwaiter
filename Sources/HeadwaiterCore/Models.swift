import Foundation

/// One listening TCP socket, as seen in one process's file table.
public struct ListeningSocket: Codable, Hashable, Sendable {
    public var pid: Int32
    public var port: UInt16
    /// Local address as text: "127.0.0.1", "::1", "0.0.0.0", "::".
    public var address: String
    /// Kernel protocol control block address. Processes that share one socket
    /// (a reloader parent that hands its socket to a worker) report the same value.
    public var pcb: UInt64

    public init(pid: Int32, port: UInt16, address: String, pcb: UInt64) {
        self.pid = pid
        self.port = port
        self.address = address
        self.pcb = pcb
    }

    public var isLoopback: Bool { address == "127.0.0.1" || address == "::1" }
    public var isWildcard: Bool { address == "0.0.0.0" || address == "::" }
}

/// Everything the pipeline needs to know about one process.
public struct ProcessSnapshot: Codable, Hashable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var pgid: Int32
    public var uid: UInt32
    /// Seconds since 1970.
    public var startTime: Double
    /// Resolved executable path (proc_pidpath). Not affected by process.title changes.
    public var executablePath: String
    /// argv as the process currently reports it (process.title rewrites show up here).
    public var arguments: [String]
    /// Working directory; nil when it can't be read.
    public var cwd: String?

    public init(pid: Int32, ppid: Int32, pgid: Int32, uid: UInt32, startTime: Double,
                executablePath: String, arguments: [String], cwd: String?) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.uid = uid
        self.startTime = startTime
        self.executablePath = executablePath
        self.arguments = arguments
        self.cwd = cwd
    }

    /// Basename of the executable file, e.g. "node", "Python", "pnpm".
    public var executableName: String { (executablePath as NSString).lastPathComponent }
    /// Basename of argv[0], e.g. "python3", "-zsh".
    public var argv0Name: String { ((arguments.first ?? "") as NSString).lastPathComponent }
    public var commandLine: String { arguments.joined(separator: " ") }
}

/// How an ancestor of a listening process relates to it, used to collapse wrapper chains.
public enum ProcessRole: String, Codable, Sendable {
    /// Transparent launcher that belongs to the server: npm, pnpm, tsx, uv, a reloader parent.
    case wrapper
    /// Runs several tasks; never part of one server: concurrently, turbo, nx.
    case orchestrator
    /// `sh -c "..."`: part of the server only when a wrapper spawned it (npm runs scripts this way).
    case shellCommand
    /// Anything else (interactive shell, terminal, editor, agent): the climb stops here.
    case other
}

public struct Framework: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var defaultPorts: [UInt16]

    public init(id: String, name: String, defaultPorts: [UInt16] = []) {
        self.id = id
        self.name = name
        self.defaultPorts = defaultPorts
    }
}

/// A repo or workspace that groups servers.
public struct Project: Codable, Hashable, Sendable {
    /// Repo root: nearest workspace root, else git root, else the package directory.
    public var rootPath: String
    public var name: String
    /// Set when the root is a git worktree (`.git` is a file): the worktree's folder name,
    /// so two checkouts of one repo can be told apart.
    public var worktree: String?

    public init(rootPath: String, name: String, worktree: String? = nil) {
        self.rootPath = rootPath
        self.name = name
        self.worktree = worktree
    }

    /// "acme" or "acme › checkout-fix-02e7be".
    public var displayName: String { worktree.map { "\(name) › \($0)" } ?? name }
}

/// The package a server runs from, inside a project.
public struct Package: Codable, Hashable, Sendable {
    public var path: String
    public var name: String
    /// Dependency names found in the manifest; used for framework detection.
    public var dependencies: Set<String>
    /// Which manifest identified the package, e.g. "package.json", "pyproject.toml".
    public var manifest: String
    /// macOS denied access to the folder, so this is a placeholder named after the working
    /// directory; no manifest, dependencies or repo root could be read.
    public var accessDenied: Bool

    public init(path: String, name: String, dependencies: Set<String>, manifest: String, accessDenied: Bool = false) {
        self.path = path
        self.name = name
        self.dependencies = dependencies
        self.manifest = manifest
        self.accessDenied = accessDenied
    }
}

/// One row in the UI: a dev server, identified by its server root.
public struct Server: Codable, Hashable, Sendable, Identifiable {
    /// PID plus start time of the server root, stable for the life of the server.
    public var id: String { "\(rootPID)@\(Int(startTime))" }

    public var runtime: String
    public var project: Project
    public var package: Package
    public var framework: Framework?
    /// Top of the server's own wrapper chain; what Stop signals (with its descendants).
    public var rootPID: Int32
    /// Processes from root down to the listener, root first.
    public var chain: [ProcessSnapshot]
    /// All processes holding this server's listening sockets.
    public var listenerPIDs: [Int32]
    public var primaryPort: UInt16
    public var secondaryPorts: [UInt16]
    public var hiddenPorts: [UInt16]
    public var url: URL
    public var startTime: Double

    public var root: ProcessSnapshot { chain[0] }
    public var listener: ProcessSnapshot { chain[chain.count - 1] }
}

/// A listening process from a supported runtime that the resolver didn't turn into a server, and why.
public struct DroppedListener: Codable, Hashable, Sendable {
    public var pid: Int32
    public var command: String
    public var ports: [UInt16]
    public var reason: String
}

public struct ResolveResult: Sendable {
    public var servers: [Server]
    public var dropped: [DroppedListener]
}
