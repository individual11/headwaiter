import Foundation

/// A frozen machine state: processes, sockets and the project files the resolver looked at.
/// Captured from a live Mac with `headwaiter-scan --capture`, or written by hand in tests.
public struct Fixture: Codable, Sendable {
    public var name: String
    public var notes: String
    public var homeDirectory: String
    public var processes: [ProcessSnapshot]
    public var sockets: [ListeningSocket]
    public var files: [String: String]
    public var otherPaths: [String]

    public init(name: String, notes: String = "", homeDirectory: String = "/Users/dev",
                processes: [ProcessSnapshot], sockets: [ListeningSocket],
                files: [String: String] = [:], otherPaths: [String] = []) {
        self.name = name
        self.notes = notes
        self.homeDirectory = homeDirectory
        self.processes = processes
        self.sockets = sockets
        self.files = files
        self.otherPaths = otherPaths
    }

    public var source: FixtureProcessSource { FixtureProcessSource(self) }
    public var fileSystem: InMemoryFileSystem {
        InMemoryFileSystem(files: files, otherPaths: Set(otherPaths), homeDirectory: homeDirectory)
    }

    public func resolve(profiles: [RuntimeProfile] = Resolver.defaultProfiles) -> ResolveResult {
        Resolver(profiles: profiles, fs: fileSystem).resolve(source)
    }

    /// Captures every listener of a supported runtime with its full ancestor chain and the
    /// files read while resolving it. Paths under the home directory are rewritten to
    /// /Users/dev. Command lines can still contain secrets: review before committing.
    public static func capture(name: String, notes: String = "", source: LiveProcessSource,
                               profiles: [RuntimeProfile] = Resolver.defaultProfiles) -> Fixture {
        let recorder = RecordingFileSystem(LocalFileSystem())
        _ = Resolver(profiles: profiles, fs: recorder).resolve(source)

        let parents = source.parentMap()
        let runtimeSockets = source.listeningSockets().filter { s in
            guard let p = source.snapshot(of: s.pid) else { return false }
            return profiles.contains { $0.runtimeName(of: p) != nil }
        }
        var pids = Set<Int32>()
        for s in runtimeSockets {
            var pid: Int32? = s.pid
            while let p = pid, p > 1, !pids.contains(p) { pids.insert(p); pid = parents[p] }
        }
        let processes = pids.sorted().compactMap(source.snapshot(of:))

        let home = NSHomeDirectory()
        let anon = "/Users/dev"
        func scrub(_ s: String) -> String { s.replacingOccurrences(of: home, with: anon) }

        return Fixture(
            name: name, notes: notes, homeDirectory: anon,
            processes: processes.map { p in
                var p = p
                p.executablePath = scrub(p.executablePath)
                p.arguments = p.arguments.map(scrub)
                p.cwd = p.cwd.map(scrub)
                return p
            },
            sockets: runtimeSockets,
            files: Dictionary(uniqueKeysWithValues: recorder.recorded.map { (scrub($0.key), scrub($0.value)) }),
            otherPaths: recorder.existing.subtracting(recorder.recorded.keys).map(scrub).sorted())
    }
}

public struct FixtureProcessSource: ProcessSource {
    let byPID: [Int32: ProcessSnapshot]
    let sockets: [ListeningSocket]

    public init(_ fixture: Fixture) {
        byPID = Dictionary(uniqueKeysWithValues: fixture.processes.map { ($0.pid, $0) })
        sockets = fixture.sockets
    }

    public func listeningSockets() -> [ListeningSocket] { sockets }
    public func parentMap() -> [Int32: Int32] { byPID.mapValues(\.ppid) }
    public func snapshot(of pid: Int32) -> ProcessSnapshot? { byPID[pid] }
}
