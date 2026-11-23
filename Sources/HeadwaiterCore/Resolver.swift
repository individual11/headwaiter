import Foundation

/// Turns raw processes and sockets into servers. Runtime-agnostic: all runtime knowledge
/// comes from the profiles.
///
/// Pipeline:
/// 1. Group listening PIDs that share a socket (reloader parent + worker) into units.
/// 2. Keep units whose processes belong to a profile's runtime; drop helpers.
/// 3. Climb each unit's wrapper chain (npm, pnpm, tsx, uv, reloaders...), stopping at
///    orchestrators, interactive shells, agents and anything that is also above another server.
///    A listening wrapper above another unit absorbs it (one server, several ports).
/// 4. Resolve package and project, framework, primary port and URL.
public struct Resolver {
    public var profiles: [RuntimeProfile]
    public var fs: FileReading

    public init(profiles: [RuntimeProfile] = Resolver.defaultProfiles, fs: FileReading = LocalFileSystem()) {
        self.profiles = profiles
        self.fs = fs
    }

    public static let defaultProfiles: [RuntimeProfile] = [NodeProfile(), PythonProfile(), GoProfile(), RubyProfile()]

    /// Ports that are debugger or inspector endpoints, never the page you want to open.
    static let inspectorPorts: Set<UInt16> = [9229, 9230]

    public func resolve(_ source: ProcessSource) -> ResolveResult {
        let parents = source.parentMap()
        let sockets = source.listeningSockets()
        var dropped: [DroppedListener] = []

        // 1. Units: PIDs connected by a shared socket.
        let units = Self.groupBySharedSocket(sockets, parents: parents)

        // 2. Runtime filter.
        struct Candidate {
            var pids: [Int32]          // all listener PIDs; first is the topmost
            var listener: ProcessSnapshot
            var profile: RuntimeProfile
            var runtime: String
        }
        var candidates: [Candidate] = []
        for unit in units {
            let ports = Self.ports(of: unit, in: sockets)
            guard let top = source.snapshot(of: unit[0]) else {
                dropped.append(DroppedListener(pid: unit[0], command: "?", ports: ports, reason: "process not readable"))
                continue
            }
            let snaps = unit.compactMap(source.snapshot(of:))
            let context = ProfileContext(fs: fs) { child in child.ppid > 1 ? source.snapshot(of: child.ppid) : nil }
            let match = profiles.lazy.compactMap { p in
                snaps.lazy.compactMap { s in p.runtimeName(of: s, context: context).map { (p, s, $0) } }.first
            }.first
            guard let (profile, _, runtime) = match else {
                dropped.append(DroppedListener(pid: top.pid, command: top.commandLine, ports: ports,
                                               reason: "not a supported runtime (\(top.executableName))"))
                continue
            }
            if let reason = snaps.lazy.compactMap(profile.auxiliaryReason).first {
                dropped.append(DroppedListener(pid: top.pid, command: top.commandLine, ports: ports, reason: reason))
                continue
            }
            candidates.append(Candidate(pids: unit, listener: top, profile: profile, runtime: runtime))
        }

        // 3a. Climb each candidate's wrapper path, ignoring other servers for now.
        var paths: [[ProcessSnapshot]] = candidates.map { climbablePath(from: $0.listener, source: source) }

        // 3b. A candidate whose listener is a wrapper above another candidate absorbs it.
        var absorbedInto: [Int: Int] = [:]
        for (i, path) in paths.enumerated() {
            let wrapperPIDs = Set(path.dropLast().map(\.pid))
            if let outer = candidates.indices.first(where: { $0 != i && wrapperPIDs.contains(candidates[$0].listener.pid) }) {
                absorbedInto[i] = outer
            }
        }
        func finalOwner(_ i: Int) -> Int {
            var j = i
            while let k = absorbedInto[j] { j = k }
            return j
        }
        var groups: [Int: [Int]] = [:]
        for i in candidates.indices { groups[finalOwner(i), default: []].append(i) }

        // 3c. Trim each path so its root isn't also above another server (orchestrator detection
        // that works even for orchestrators no profile knows about).
        let owners = groups.keys.sorted()
        let ownerListeners = owners.map { candidates[$0].listener.pid }
        func ancestors(of pid: Int32) -> Set<Int32> {
            var result = Set<Int32>()
            var p = parents[pid]
            while let q = p, q > 1, !result.contains(q) { result.insert(q); p = parents[q] }
            return result
        }
        let ancestorSets = Dictionary(uniqueKeysWithValues: ownerListeners.map { ($0, ancestors(of: $0)) })

        var servers: [Server] = []
        for owner in owners {
            let c = candidates[owner]
            let members = groups[owner]!.map { candidates[$0] }
            let others = ownerListeners.filter { $0 != c.listener.pid }
            var path = paths[owner]
            // path is root-first; drop roots that are ancestors of another server.
            while path.count > 1, others.contains(where: { ancestorSets[$0]?.contains(path[0].pid) == true }) {
                path.removeFirst()
            }
            paths[owner] = path

            let listenerPIDs = members.flatMap(\.pids)
            let memberSnaps = members.map(\.listener)
            let commandLines = path.map(\.arguments) + memberSnaps.dropFirst().map(\.arguments)

            // 4. Package and project.
            var starts: [String] = []
            for s in memberSnaps { if let cwd = s.cwd { starts.append(cwd) } }
            for s in path.reversed() { starts.append(contentsOf: c.profile.scriptDirectories(of: s)) }
            if let rootCwd = path[0].cwd { starts.append(rootCwd) }
            starts = starts.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }

            let ports = Self.ports(of: listenerPIDs, in: sockets)
            let package: Package
            let project: Project
            if let found = c.profile.resolvePackage(startDirectories: starts, fs: fs) {
                package = found
                project = projectFor(package: found, profile: c.profile)
            } else if let denied = starts.first(where: { $0 != fs.homeDirectory && $0 != "/" && fs.isAccessDenied($0) }) {
                // A protected folder we may not read is not proof of "no project": show the
                // server, named after its working directory (which the kernel gives us freely).
                let folder = (denied as NSString).lastPathComponent
                package = Package(path: denied, name: folder, dependencies: [], manifest: "", accessDenied: true)
                project = Project(rootPath: denied, name: folder)
            } else {
                dropped.append(DroppedListener(pid: c.listener.pid, command: c.listener.commandLine, ports: ports,
                                               reason: "no project found (cwd: \(c.listener.cwd ?? "unknown"))"))
                continue
            }
            let framework = Self.detectFramework(c.profile.frameworks, commandLines: commandLines,
                                                 dependencies: package.dependencies)

            let hidden = Self.hiddenPorts(commandLines: commandLines, ports: ports)
            let visible = ports.filter { !hidden.contains($0) }
            guard !visible.isEmpty else {
                dropped.append(DroppedListener(pid: c.listener.pid, command: c.listener.commandLine, ports: ports,
                                               reason: "only debugger ports"))
                continue
            }
            let primary = Self.primaryPort(visible: visible, commandLines: commandLines, framework: framework)
            let socketsOfPrimary = sockets.filter { listenerPIDs.contains($0.pid) && $0.port == primary }

            servers.append(Server(
                runtime: c.runtime, project: project, package: package, framework: framework,
                rootPID: path[0].pid, chain: path, listenerPIDs: listenerPIDs,
                primaryPort: primary, secondaryPorts: visible.filter { $0 != primary },
                hiddenPorts: hidden.sorted(),
                url: Self.url(port: primary, sockets: socketsOfPrimary, https: Self.usesHTTPS(commandLines)),
                startTime: path[0].startTime))
        }

        servers.sort { ($0.project.name, $0.project.rootPath, $0.package.name, $0.primaryPort)
            < ($1.project.name, $1.project.rootPath, $1.package.name, $1.primaryPort) }
        return ResolveResult(servers: servers, dropped: dropped)
    }

    // MARK: - Steps

    /// Groups listener PIDs that hold the same socket. The first PID of each unit is the
    /// topmost (an ancestor of the others when they're related), else the lowest.
    static func groupBySharedSocket(_ sockets: [ListeningSocket], parents: [Int32: Int32]) -> [[Int32]] {
        var link: [Int32: Int32] = [:]
        func find(_ x: Int32) -> Int32 {
            var x = x
            while let p = link[x], p != x { x = p }
            return x
        }
        var firstByPCB: [UInt64: Int32] = [:]
        for s in sockets {
            if link[s.pid] == nil { link[s.pid] = s.pid }
            if let other = firstByPCB[s.pcb] {
                let a = find(other), b = find(s.pid)
                if a != b { link[b] = a }
            } else {
                firstByPCB[s.pcb] = s.pid
            }
        }
        var groups: [Int32: [Int32]] = [:]
        for pid in link.keys { groups[find(pid), default: []].append(pid) }

        func depth(_ pid: Int32) -> Int {
            var d = 0, p = parents[pid]
            while let q = p, q > 1, d < 512 { d += 1; p = parents[q] }
            return d
        }
        return groups.values
            .map { $0.sorted { (depth($0), $0) < (depth($1), $1) } }
            .sorted { $0[0] < $1[0] }
    }

    /// The listener plus every ancestor that belongs to the same server, root first.
    func climbablePath(from listener: ProcessSnapshot, source: ProcessSource) -> [ProcessSnapshot] {
        var path = [listener]
        var child = listener
        while child.ppid > 1, let parent = source.snapshot(of: child.ppid), path.count < 64 {
            let role = classify(parent, child: child)
            var climb = role == .wrapper
            if role == .shellCommand, parent.ppid > 1, let grandparent = source.snapshot(of: parent.ppid) {
                // npm runs scripts via `sh -c`; an agent's or terminal's `zsh -c` is not ours.
                climb = classify(grandparent, child: parent) == .wrapper
            }
            guard climb else { break }
            path.insert(parent, at: 0)
            child = parent
        }
        return path
    }

    func classify(_ process: ProcessSnapshot, child: ProcessSnapshot) -> ProcessRole {
        for profile in profiles {
            if let role = profile.role(of: process) { return role }
        }
        if let role = Shells.role(of: process) { return role }
        // Reloaders (Django runserver, Werkzeug) re-run themselves with the same arguments.
        for profile in profiles where profile.runtimeName(of: process) != nil && profile.runtimeName(of: child) != nil {
            if Self.scriptArguments(process) == Self.scriptArguments(child) { return .wrapper }
        }
        return .other
    }

    /// Arguments from the script onward, ignoring the interpreter path and its flags.
    static func scriptArguments(_ p: ProcessSnapshot) -> [String] {
        guard let script = Args.script(of: p.arguments), let i = p.arguments.firstIndex(of: script) else {
            return Array(p.arguments.dropFirst())
        }
        return Array(p.arguments[i...])
    }

    func projectFor(package: Package, profile: RuntimeProfile) -> Project {
        var root = package.path
        for dir in Paths.walkUp(from: package.path, home: fs.homeDirectory) {
            // .git is a directory in a clone and a file in a worktree; both mark a repo root.
            if profile.isWorkspaceRoot(dir, fs: fs) || fs.exists(Paths.join(dir, ".git")) {
                root = dir
                break
            }
        }
        let folder = (root as NSString).lastPathComponent
        let name = profile.manifestName(in: root, fs: fs) ?? folder
        // A worktree's .git is a file: "gitdir: /repo/.git/worktrees/<name>".
        let isWorktree = fs.contents(of: Paths.join(root, ".git"))?.hasPrefix("gitdir:") == true
        return Project(rootPath: root, name: name, worktree: isWorktree && folder != name ? folder : nil)
    }

    static func detectFramework(_ rules: [FrameworkRule], commandLines: [[String]], dependencies: Set<String>) -> Framework? {
        if let rule = rules.first(where: { $0.matchesCommand(commandLines, dependencies) }) { return rule.framework }
        return rules.first(where: { !dependencies.isDisjoint(with: $0.dependencies) })?.framework
    }

    static func ports(of pids: [Int32], in sockets: [ListeningSocket]) -> [UInt16] {
        let set = Set(pids)
        return Array(Set(sockets.filter { set.contains($0.pid) }.map(\.port))).sorted()
    }

    /// Ports explicitly requested on the command line: `--port 3001`, `--port=3001`, `-p 3001`,
    /// and Django's `runserver [addr:]8001`.
    static func requestedPorts(_ commandLines: [[String]]) -> [UInt16] {
        var result: [UInt16] = []
        for line in commandLines {
            for (i, arg) in line.enumerated() {
                let next = i + 1 < line.count ? line[i + 1] : nil
                if arg == "--port" || arg == "-p", let n = next, let p = UInt16(n) { result.append(p) }
                if arg.hasPrefix("--port="), let p = UInt16(arg.dropFirst(7)) { result.append(p) }
                if arg == "runserver", let n = next, let p = UInt16(n.split(separator: ":").last ?? "") { result.append(p) }
            }
        }
        return result
    }

    static func hiddenPorts(commandLines: [[String]], ports: [UInt16]) -> Set<UInt16> {
        var hidden = inspectorPorts
        for line in commandLines {
            for arg in line where arg.hasPrefix("--inspect") {
                if let value = arg.split(separator: "=").last, let p = UInt16(value.split(separator: ":").last ?? "") {
                    hidden.insert(p)
                }
            }
        }
        return hidden.intersection(ports)
    }

    static func primaryPort(visible: [UInt16], commandLines: [[String]], framework: Framework?) -> UInt16 {
        if let p = requestedPorts(commandLines).first(where: visible.contains) { return p }
        if let p = framework?.defaultPorts.first(where: visible.contains) { return p }
        return visible[0]
    }

    static func usesHTTPS(_ commandLines: [[String]]) -> Bool {
        let flags: Set<String> = ["--https", "--experimental-https", "--ssl-certfile", "--certfile", "--cert-file",
                                  "--ssl-keyfile", "--keyfile"]
        return commandLines.contains { line in line.contains { arg in flags.contains(arg.split(separator: "=").first.map(String.init) ?? arg) } }
    }

    static func url(port: UInt16, sockets: [ListeningSocket], https: Bool) -> URL {
        var host = "localhost"
        // Only use the bound address when the server isn't reachable via localhost at all.
        if !sockets.isEmpty, !sockets.contains(where: { $0.isLoopback || $0.isWildcard }) {
            let a = sockets[0].address
            host = a.contains(":") ? "[\(a)]" : a
        }
        return URL(string: "\(https ? "https" : "http")://\(host):\(port)")!
    }
}
