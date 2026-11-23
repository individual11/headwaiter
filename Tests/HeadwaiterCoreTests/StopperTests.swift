import Darwin
import Foundation
import Testing
@testable import HeadwaiterCore

/// Records signals instead of sending them; can simulate kernel refusals.
final class RecordingSender: SignalSending, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [(signal: Int32, pid: Int32)] = []
    var errors: [Int32: Int32] = [:]

    func send(_ signal: Int32, to pid: Int32) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if let e = errors[pid] { return e }
        sent.append((signal, pid))
        return 0
    }

    var pids: [Int32] { sent.map(\.pid) }
}

@Suite("Stopping")
struct StopperTests {
    func stopTargets(_ server: Server, _ source: ProcessSource) throws -> [Int32] {
        try #require(Stopper.plan(for: server, source: source)).targets.map(\.pid)
    }

    @Test func capturedPnpmConcurrentlyUnderAgent() throws {
        let url = try #require(Bundle.module.url(forResource: "pnpm-concurrently-agent", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let servers = fixture.resolve().servers
        let client = try #require(servers.first { $0.package.name == "@acme/client" })
        let server = try #require(servers.first { $0.package.name == "@acme/server" })

        // Deepest first, root last; nothing above the root.
        #expect(try stopTargets(client, fixture.source) == [41337, 41324])
        #expect(try stopTargets(server, fixture.source) == [41351, 41344, 41323])
        let all = try stopTargets(client, fixture.source) + (try stopTargets(server, fixture.source))
        #expect(Set(all).isDisjoint(with: [41316, 41289, 41269, 45402]))   // concurrently, pnpm dev, agent, Claude
    }

    @Test func turboSiblingIsUntouched() throws {
        var w = World.withTerminal()
        let repo = "/Users/dev/code/shop"
        w.file("\(repo)/pnpm-workspace.yaml")
        w.file("\(repo)/apps/web/package.json", #"{"name":"@shop/web"}"#)
        w.file("\(repo)/apps/api/package.json", #"{"name":"@shop/api"}"#)
        w.proc(401, parent: World.terminalShell, exe: "/opt/homebrew/bin/turbo", ["turbo", "run", "dev"], cwd: repo)
        w.proc(410, parent: 401, exe: "/opt/homebrew/bin/pnpm", ["pnpm", "run", "dev"], cwd: "\(repo)/apps/web")
        w.proc(411, parent: 410, exe: node, [node, "\(repo)/apps/web/node_modules/vite/bin/vite.js"], cwd: "\(repo)/apps/web")
        w.proc(412, parent: 411, exe: "/opt/esbuild", ["esbuild", "--service=0.24.0", "--ping"], cwd: "\(repo)/apps/web")
        w.proc(420, parent: 401, exe: "/opt/homebrew/bin/pnpm", ["pnpm", "run", "dev"], cwd: "\(repo)/apps/api")
        w.proc(421, parent: 420, exe: node, [node, "server.js"], cwd: "\(repo)/apps/api")
        w.listen(411, 5173)
        w.listen(421, 4000)

        let web = try #require(w.resolve().servers.first { $0.package.name == "@shop/web" })
        #expect(try stopTargets(web, w.source) == [412, 411, 410])         // includes vite's esbuild helper
    }

    @Test func unknownOrchestratorStopsOnlyOneServer() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/pair"
        w.file("\(app)/package.json", #"{"name":"pair"}"#)
        w.proc(500, parent: World.terminalShell, exe: "/opt/homebrew/bin/pnpm", ["pnpm", "dev"], cwd: app)
        w.proc(501, parent: 500, exe: "/bin/sh", ["sh", "-c", "node a.js & node b.js"], cwd: app)
        w.proc(502, parent: 501, exe: node, [node, "a.js"], cwd: app)
        w.proc(503, parent: 501, exe: node, [node, "b.js"], cwd: app)
        w.listen(502, 3001)
        w.listen(503, 3002)

        let a = try #require(w.resolve().servers.first { $0.primaryPort == 3001 })
        #expect(try stopTargets(a, w.source) == [502])
    }

    @Test func npxThroughShell() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/site"
        w.file("\(app)/package.json", #"{"name":"site"}"#)
        // npx retitles itself to "npm exec vite" and runs the binary via `sh -c`.
        w.proc(600, parent: World.terminalShell, exe: node, ["npm", "exec", "vite"], cwd: app)
        w.proc(601, parent: 600, exe: "/bin/sh", ["sh", "-c", "vite"], cwd: app)
        w.proc(602, parent: 601, exe: node, [node, "\(app)/node_modules/.bin/vite"], cwd: app)
        w.listen(602, 5173)

        let s = try #require(w.resolve().servers.first)
        #expect(s.rootPID == 600)
        #expect(s.framework?.name == "Vite")
        #expect(try stopTargets(s, w.source) == [602, 601, 600])
    }

    /// nx runs tasks in forked workers. Whatever the exact tree, Stop must never reach nx itself.
    @Test func nxIsNeverAStopTarget() throws {
        var w = World.withTerminal()
        let repo = "/Users/dev/code/nxrepo"
        w.file("\(repo)/package.json", #"{"name":"nxrepo","devDependencies":{"nx":"20","vite":"6"}}"#)
        w.file("\(repo)/nx.json", "{}")
        w.proc(700, parent: World.terminalShell, exe: node, ["npm", "exec", "nx", "serve", "web"], cwd: repo)
        w.proc(701, parent: 700, exe: node, [node, "\(repo)/node_modules/nx/bin/nx.js", "serve", "web"], cwd: repo)
        w.proc(702, parent: 701, exe: node, [node, "\(repo)/node_modules/nx/src/tasks-runner/fork.js", "serve", "web"], cwd: repo)
        w.listen(702, 4200)

        let s = try #require(w.resolve().servers.first)
        let targets = try stopTargets(s, w.source)
        #expect(!targets.contains(701) && !targets.contains(700))
        #expect(targets.contains(702))
    }

    @Test func uvicornReloadStopsRunnerSupervisorAndWorker() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/ml-api"
        w.file("\(app)/pyproject.toml", "[project]\nname = \"ml-api\"\ndependencies = [\"fastapi\"]\n")
        w.proc(1100, parent: World.terminalShell, exe: "/opt/homebrew/bin/uv", ["uv", "run", "uvicorn", "app:app", "--reload"], cwd: app)
        w.proc(1101, parent: 1100, exe: python, ["python3", "\(app)/.venv/bin/uvicorn", "app:app", "--reload"], cwd: app)
        w.proc(1102, parent: 1101, exe: python, ["python3", "-c", "from multiprocessing.spawn import spawn_main"], cwd: app)
        let pcb = w.listen(1101, 8000)
        w.listen(1102, 8000, pcb: pcb)

        let s = try #require(w.resolve().servers.first)
        #expect(try stopTargets(s, w.source) == [1102, 1101, 1100])
        let targets = try stopTargets(s, w.source)
        #expect(!targets.contains(World.terminalShell))
    }

    // MARK: - Signalling

    func simpleServer() -> World {
        var w = World.withTerminal()
        w.file("/Users/dev/code/app/package.json", #"{"name":"app"}"#)
        w.proc(200, parent: World.terminalShell, exe: node, ["npm", "run", "dev"], cwd: "/Users/dev/code/app", start: 1000)
        w.proc(201, parent: 200, exe: node, [node, "server.js"], cwd: "/Users/dev/code/app", start: 1001)
        w.listen(201, 3000)
        return w
    }

    func planFirst(_ w: World) throws -> StopPlan {
        let server = try #require(w.resolve().servers.first)
        return try #require(Stopper.plan(for: server, source: w.source))
    }

    @Test func sigtermGoesToSubtreeDeepestFirst() throws {
        let w = simpleServer()
        let plan = try planFirst(w)
        let sender = RecordingSender()
        let result = Stopper.signal(SIGTERM, plan, source: w.source, sender: sender)
        #expect(sender.pids == [201, 200])
        #expect(sender.sent.allSatisfy { $0.signal == SIGTERM })
        #expect((try? result.get())?.count == 2)
    }

    @Test func reusedPIDIsNeverSignalled() throws {
        var w = simpleServer()
        let plan = try planFirst(w)
        // Both exit; an unrelated process gets PID 201 before the user clicks Stop.
        w.exit(200)
        w.exit(201)
        w.proc(201, parent: 1, exe: "/usr/bin/some-daemon", ["some-daemon"], start: 5000)

        let sender = RecordingSender()
        let result = Stopper.signal(SIGTERM, plan, source: w.source, sender: sender)
        #expect(sender.sent.isEmpty)
        #expect(result == .failure(.alreadyExited))
        #expect(Stopper.plan(root: plan.root, source: w.source) == nil)
    }

    @Test func permissionDeniedIsReported() throws {
        let w = simpleServer()
        let plan = try planFirst(w)
        let sender = RecordingSender()
        sender.errors = [200: EPERM, 201: EPERM]
        #expect(Stopper.signal(SIGTERM, plan, source: w.source, sender: sender) == .failure(.permissionDenied(pid: 201)))
    }

    @Test func survivorsIncludeRespawnedChildren() throws {
        var w = simpleServer()
        let plan = try planFirst(w)
        // The child exited but the wrapper ignored SIGTERM and started a new one.
        w.exit(201)
        w.proc(202, parent: 200, exe: node, [node, "server.js"], cwd: "/Users/dev/code/app", start: 1010)

        let survivors = try #require(Stopper.survivors(of: plan, source: w.source))
        #expect(Set(survivors.targets.map(\.pid)) == [200, 202])

        w.exit(200)
        w.exit(202)
        #expect(Stopper.survivors(of: plan, source: w.source) == nil)
    }

    @Test func neverPlansLaunchdOrSelf() {
        let w = World.withTerminal()
        #expect(Stopper.plan(root: ProcessIdentity(pid: 1, startTime: 0), source: w.source) == nil)
        #expect(Stopper.plan(root: ProcessIdentity(pid: getpid(), startTime: 0), source: w.source) == nil)
    }
}
