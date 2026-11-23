import Foundation
@testable import HeadwaiterCore

/// Small builder for hand-written fixtures: a fake process tree, sockets and project files.
struct World {
    var processes: [ProcessSnapshot] = []
    var sockets: [ListeningSocket] = []
    var files: [String: String] = [:]
    var otherPaths: [String] = []
    var denied: Set<String> = []
    private var nextPCB: UInt64 = 1

    static let home = "/Users/dev"
    static let terminalShell: Int32 = 100

    /// launchd, Terminal.app and an interactive login shell (pid 100), as on a real Mac.
    static func withTerminal() -> World {
        var w = World()
        w.proc(1, parent: 0, exe: "/sbin/launchd", ["/sbin/launchd"])
        w.proc(50, parent: 1, exe: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
               ["/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"])
        w.proc(80, parent: 50, exe: "/usr/bin/login", ["login", "-pf", "dev"])
        w.proc(terminalShell, parent: 80, exe: "/bin/zsh", ["-zsh"], cwd: home)
        return w
    }

    mutating func proc(_ pid: Int32, parent: Int32, exe: String, _ args: [String],
                       cwd: String? = nil, start: Double = 1_000) {
        processes.append(ProcessSnapshot(pid: pid, ppid: parent, pgid: pid, uid: 501, startTime: start,
                                         executablePath: exe, arguments: args, cwd: cwd))
    }

    /// Adds a listening socket. Pass the same `pcb` for processes sharing one socket.
    @discardableResult
    mutating func listen(_ pid: Int32, _ port: UInt16, address: String = "127.0.0.1", pcb: UInt64? = nil) -> UInt64 {
        let id = pcb ?? { nextPCB += 1; return nextPCB }()
        sockets.append(ListeningSocket(pid: pid, port: port, address: address, pcb: id))
        return id
    }

    mutating func file(_ path: String, _ content: String = "") { files[path] = content }
    mutating func exists(_ path: String) { otherPaths.append(path) }

    var source: FixtureProcessSource {
        Fixture(name: "test", homeDirectory: Self.home, processes: processes, sockets: sockets).source
    }

    /// Removes a process, as if it exited.
    mutating func exit(_ pid: Int32) {
        processes.removeAll { $0.pid == pid }
        sockets.removeAll { $0.pid == pid }
    }

    func resolve() -> ResolveResult {
        let fs = InMemoryFileSystem(files: files, otherPaths: Set(otherPaths), deniedDirectories: denied,
                                    homeDirectory: Self.home)
        let fixture = Fixture(name: "test", homeDirectory: Self.home, processes: processes, sockets: sockets)
        return Resolver(fs: fs).resolve(fixture.source)
    }
}

let node = "/Users/dev/.nvm/versions/node/v24.0.0/bin/node"
let npmCLI = "/Users/dev/.nvm/versions/node/v24.0.0/lib/node_modules/npm/bin/npm-cli.js"
let python = "/opt/homebrew/Cellar/python@3.12/3.12.7/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python"
