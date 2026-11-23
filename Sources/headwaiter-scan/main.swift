import Darwin
import Foundation
import HeadwaiterCore

let usage = """
usage: headwaiter-scan [--json] [--all]
       headwaiter-scan --bench [N]          time N scans (default 50); CPU and memory per scan
       headwaiter-scan --oracle             compare libproc's listening sockets with lsof
       headwaiter-scan --capture NAME FILE  write a test fixture of the current machine state
       headwaiter-scan --stop PORT|PID [--force]  stop a server like the app does (SIGTERM, 3 s, SIGKILL)

  --json   machine-readable output
  --all    also list listeners that were skipped, and why
"""

var args = Array(CommandLine.arguments.dropFirst())
@MainActor func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}

let home = NSHomeDirectory()
func tilde(_ path: String) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}
func short(_ s: String, _ n: Int = 90) -> String {
    let t = tilde(s.replacingOccurrences(of: home, with: "~"))
    return t.count <= n ? t : String(t.prefix(n - 1)) + "…"
}
func uptime(_ start: Double) -> String { Display.uptime(since: start) }
func display(_ p: ProcessSnapshot) -> String { Display.command(p) }
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count) }

// MARK: - Commands

func printServers(json: Bool, all: Bool) {
    let result = Resolver().resolve(LiveProcessSource())
    if json {
        struct Output: Encodable { var servers: [Server]; var dropped: [DroppedListener]? }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try! enc.encode(Output(servers: result.servers, dropped: all ? result.dropped : nil))
        print(String(decoding: data, as: UTF8.self))
        return
    }

    let n = result.servers.count
    print(n == 0 ? "No dev servers running" : "\(n) server\(n == 1 ? "" : "s") running")
    var lastProject: String?
    for s in result.servers {
        if s.project.rootPath != lastProject {
            print("\n\(s.project.displayName)  \(tilde(s.project.rootPath))")
            lastProject = s.project.rootPath
        }
        let ports = ":\(s.primaryPort)" + (s.secondaryPorts.isEmpty ? "" : " +" + s.secondaryPorts.map(String.init).joined(separator: ","))
        print("  " + pad(s.package.name, 22) + pad(s.framework?.name ?? "–", 11) + pad(ports, 16)
              + pad(uptime(s.startTime), 9) + pad(s.runtime, 7) + s.url.absoluteString)
        let root = s.root
        print("      stop → pid \(root.pid): \(short(display(root), 80))")
        if s.chain.count > 1 {
            print("      listener pid \(s.listener.pid) (\(s.chain.count - 1) wrapper\(s.chain.count == 2 ? "" : "s") above)"
                  + (s.listenerPIDs.count > 1 ? ", shared socket with \(s.listenerPIDs.dropFirst().map(String.init).joined(separator: ","))" : ""))
        }
    }
    let docker = DockerSocketSource()
    if let raw = docker.runningContainers() {
        let containers = ContainerResolver.servers(from: raw)
        print("\nDocker (\(docker.socketPath ?? "?")): \(containers.count) container\(containers.count == 1 ? "" : "s") with published ports")
        for c in containers {
            let ports = ":\(c.primaryPort)" + (c.secondaryPorts.isEmpty ? "" : " +" + c.secondaryPorts.map(String.init).joined(separator: ","))
            print("  " + pad(c.name, 22) + pad(c.imageShortName, 18) + pad(ports, 16)
                  + pad(uptime(c.startTime), 9) + (c.isHTTP ? c.url.absoluteString : c.address))
            print("      project: \(c.project.map { "\($0.name)  \(tilde($0.rootPath))" } ?? "(not Compose)")  id \(c.id.prefix(12))")
        }
    }
    if all, !result.dropped.isEmpty {
        print("\nSkipped listeners:")
        for d in result.dropped.sorted(by: { $0.pid < $1.pid }) {
            print("  pid \(pad(String(d.pid), 7)) :\(pad(d.ports.map(String.init).joined(separator: ","), 14)) \(d.reason)")
            print("      \(short(d.command, 100))")
        }
    }
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
        + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func bench(_ runs: Int) {
    let resolver = Resolver()
    _ = resolver.resolve(LiveProcessSource()) // warm up
    var wall: [Double] = []
    var servers = 0
    var sockets = 0
    let cpu0 = cpuSeconds()
    for _ in 0..<runs {
        let t = DispatchTime.now().uptimeNanoseconds
        let source = LiveProcessSource()
        servers = resolver.resolve(source).servers.count
        sockets = source.listeningSockets().count
        wall.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
    }
    let cpuPerScan = (cpuSeconds() - cpu0) / Double(runs) * 1000
    wall.sort()
    let mean = wall.reduce(0, +) / Double(runs)
    let p95 = wall[min(runs - 1, Int(Double(runs) * 0.95))]
    print("""
    \(runs) scans, \(LiveProcessSourceStats.processCount()) processes, \(sockets) listening sockets, \(servers) servers
    wall per scan:  mean \(String(format: "%.1f", mean)) ms, p95 \(String(format: "%.1f", p95)) ms
    CPU per scan:   \(String(format: "%.1f", cpuPerScan)) ms
    idle CPU at a 5 s poll: \(String(format: "%.2f", cpuPerScan / 5000 * 100))%   (target < 1%)
    at a 2 s poll:          \(String(format: "%.2f", cpuPerScan / 2000 * 100))%
    memory footprint: \(String(format: "%.1f", footprintMB())) MB (CLI process; target < 50 MB for the app)
    """)
}

enum LiveProcessSourceStats {
    static func processCount() -> Int { Int(proc_listallpids(nil, 0)) }
}

/// Checks the scanner against lsof: every (pid, port) lsof sees should be found, and vice versa.
func oracle() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    task.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pn"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try! task.run()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    task.waitUntilExit()

    struct Key: Hashable, Comparable {
        var pid: Int32; var port: UInt16
        static func < (a: Key, b: Key) -> Bool { (a.pid, a.port) < (b.pid, b.port) }
    }
    var lsof = Set<Key>()
    var pid: Int32 = 0
    for line in out.split(separator: "\n") {
        if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
        if line.hasPrefix("n"), let port = line.split(separator: ":").last.flatMap({ UInt16($0) }) {
            lsof.insert(Key(pid: pid, port: port))
        }
    }
    let ours = Set(LiveProcessSource().listeningSockets().map { Key(pid: $0.pid, port: $0.port) })
    let missing = lsof.subtracting(ours).sorted()
    let extra = ours.subtracting(lsof).sorted()
    print("lsof: \(lsof.count) (pid, port) pairs; libproc: \(ours.count)")
    print(missing.isEmpty ? "✓ nothing lsof saw is missing" : "✗ missing from libproc: \(missing.map { "\($0.pid):\($0.port)" })")
    print(extra.isEmpty ? "✓ nothing extra" : "✗ extra in libproc (may have started between the two reads): \(extra.map { "\($0.pid):\($0.port)" })")
    if !missing.isEmpty { exit(1) }
}

/// Stops the server on a port (or with a root/listener PID) the way the app will:
/// SIGTERM to its subtree, wait up to 3 s, then report survivors or SIGKILL them with --force.
func stop(_ target: String, force: Bool) {
    guard let n = Int32(target) else { print(usage); exit(2) }
    let servers = Resolver().resolve(LiveProcessSource()).servers
    guard let server = servers.first(where: {
        $0.primaryPort == UInt16(clamping: n) || $0.secondaryPorts.contains(UInt16(clamping: n))
            || $0.rootPID == n || $0.listenerPIDs.contains(n)
    }) else {
        print("No server on port or PID \(target)."); exit(1)
    }
    guard let plan = Stopper.plan(for: server, source: LiveProcessSource()) else {
        print("Already stopped."); return
    }
    print("Stopping \(server.package.name) :\(server.primaryPort): SIGTERM → \(plan.targets.map(\.description).joined(separator: ", ")) (deepest first)")
    if case .failure(let f) = Stopper.signal(SIGTERM, plan, source: LiveProcessSource()) {
        print("✗ \(f)"); exit(1)
    }

    let start = Date()
    var survivors: StopPlan? = plan
    while let s = survivors, Date().timeIntervalSince(start) < 3 {
        usleep(100_000)
        survivors = Stopper.survivors(of: s, source: LiveProcessSource())
    }
    guard let remaining = survivors else {
        print("✓ Stopped in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        return
    }
    print("Still running after 3 s: \(remaining.targets.map(\.description).joined(separator: ", "))")
    guard force else { print("Run again with --force to SIGKILL them."); exit(1) }
    _ = Stopper.signal(SIGKILL, remaining, source: LiveProcessSource())
    usleep(300_000)
    if let left = Stopper.survivors(of: remaining, source: LiveProcessSource()) {
        print("✗ Still alive after SIGKILL: \(left.targets.map(\.description).joined(separator: ", "))"); exit(1)
    }
    print("✓ Force quit")
}

func capture(name: String, path: String) {
    let fixture = Fixture.capture(name: name, source: LiveProcessSource())
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try! enc.encode(fixture).write(to: URL(fileURLWithPath: path))
    print("Wrote \(path): \(fixture.processes.count) processes, \(fixture.sockets.count) sockets, \(fixture.files.count) files.")
    print("Home paths were rewritten to /Users/dev. Check command lines for secrets before committing.")
}

// MARK: - Main

if flag("--help") || flag("-h") { print(usage); exit(0) }
if flag("--bench") {
    bench(args.first.flatMap(Int.init) ?? 50)
} else if flag("--oracle") {
    oracle()
} else if flag("--stop") {
    let force = flag("--force")
    guard args.count == 1 else { print(usage); exit(2) }
    stop(args[0], force: force)
} else if flag("--capture") {
    guard args.count == 2 else { print(usage); exit(2) }
    capture(name: args[0], path: args[1])
} else {
    let json = flag("--json")
    let all = flag("--all")
    guard args.isEmpty else { print(usage); exit(2) }
    printServers(json: json, all: all)
}
