import Foundation
import HeadwaiterCore

/// A server that was running and stopped. Holds what a future Restart needs
/// (command, cwd) so the schema doesn't change when that lands.
struct StoppedServer: Codable, Identifiable, Equatable {
    var id: String
    var projectName: String
    var projectRoot: String
    var worktree: String?
    var packageName: String
    var packagePath: String
    var framework: String?
    /// Optional so state files from before these fields existed still decode.
    var frameworkID: String?
    var runtime: String?
    var port: UInt16
    var subtitle: String
    var command: [String]
    var cwd: String?
    var startedAt: Double
    var stoppedAt: Date

    init(_ s: Server, stoppedAt: Date = Date()) {
        id = s.id
        projectName = s.project.displayName
        projectRoot = s.project.rootPath
        worktree = s.project.worktree
        packageName = s.package.name
        packagePath = s.package.path
        framework = s.framework?.name
        frameworkID = s.framework?.id
        runtime = s.runtime
        port = s.primaryPort
        subtitle = s.subtitle
        command = s.root.arguments
        cwd = s.root.cwd
        startedAt = s.startTime
        self.stoppedAt = stoppedAt
    }

    /// Same package on the same port: a restart of this entry.
    func matches(_ s: Server) -> Bool { packagePath == s.package.path && port == s.primaryPort }
}

struct HiddenItems: Codable, Equatable {
    var ports: Set<UInt16> = []
    /// Project root paths.
    var projects: Set<String> = []

    func hides(_ s: Server) -> Bool {
        projects.contains(s.project.rootPath) || ports.contains(s.primaryPort)
    }

    func hides(_ c: ContainerServer) -> Bool {
        projects.contains(c.project?.rootPath ?? ServerStore.dockerGroupRoot) || ports.contains(c.primaryPort)
    }

    /// The server with hidden ports removed from its other ports. Hiding the main port hides
    /// the whole row instead (`hides`).
    func trimmed(_ s: Server) -> Server {
        var s = s
        s.secondaryPorts.removeAll { ports.contains($0) }
        return s
    }

    func trimmed(_ c: ContainerServer) -> ContainerServer {
        var c = c
        c.secondaryPorts.removeAll { ports.contains($0) }
        return c
    }
}

struct PersistedState: Codable, Equatable {
    var version = 1
    var recentlyStopped: [StoppedServer] = []
    var hidden = HiddenItems()
    var popoverOpenCount = 0
    /// Keyed by package path.
    var urlOverrides: [String: URLOverride] = [:]
    var hasSeenWelcome = false

    init() {}

    init(recentlyStopped: [StoppedServer], hidden: HiddenItems, popoverOpenCount: Int) {
        self.recentlyStopped = recentlyStopped
        self.hidden = hidden
        self.popoverOpenCount = popoverOpenCount
    }

    /// Missing keys fall back to defaults, so adding a field never discards an older state file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        recentlyStopped = try c.decodeIfPresent([StoppedServer].self, forKey: .recentlyStopped) ?? []
        hidden = try c.decodeIfPresent(HiddenItems.self, forKey: .hidden) ?? HiddenItems()
        popoverOpenCount = try c.decodeIfPresent(Int.self, forKey: .popoverOpenCount) ?? 0
        urlOverrides = try c.decodeIfPresent([String: URLOverride].self, forKey: .urlOverrides) ?? [:]
        hasSeenWelcome = try c.decodeIfPresent(Bool.self, forKey: .hasSeenWelcome) ?? false
    }
}

/// ~/Library/Application Support/Headwaiter/state.json. Small, so it's rewritten whole on change.
enum StateFile {
    static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    static var url: URL {
        support.appendingPathComponent("Headwaiter", isDirectory: true).appendingPathComponent("state.json")
    }

    static func load() -> PersistedState {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let state = try? dec.decode(PersistedState.self, from: data) else { return PersistedState() }
        return state
    }

    static func save(_ state: PersistedState) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(state).write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("state save failed: \(error)\n".utf8))
        }
    }
}

/// One-time move from the working name "What's Running" (bundle ID local.whatsrunning.app):
/// carries over history, hidden items, captures and settings so the rename loses nothing.
enum RenameMigration {
    static let oldDefaultsDomain = "local.whatsrunning.app"
    static let doneKey = "migratedFromWhatsRunning"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }

        // Settings live in the old app's defaults domain; copy the ones that exist.
        if let old = UserDefaults(suiteName: oldDefaultsDomain) {
            for key in [Preferences.autoForceQuitKey, AppAppearance.key] {
                if defaults.object(forKey: key) == nil, let value = old.object(forKey: key) {
                    defaults.set(value, forKey: key)
                }
            }
        }

        // Files: copy the whole old folder (state.json, Captures) if the new one doesn't exist yet.
        let fm = FileManager.default
        let oldDir = StateFile.support.appendingPathComponent("WhatsRunning", isDirectory: true)
        let newDir = StateFile.url.deletingLastPathComponent()
        if fm.fileExists(atPath: oldDir.path) && !fm.fileExists(atPath: newDir.path) {
            try? fm.copyItem(at: oldDir, to: newDir)
        }
    }
}
