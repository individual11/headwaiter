import Foundation
import Testing
@testable import HeadwaiterCore

// MARK: - Captured from a real Mac

@Suite("Captured fixtures")
struct CapturedFixtureTests {
    func load(_ name: String) throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// `pnpm dev` → concurrently → two `pnpm --filter` servers, started by a Claude Code agent,
    /// plus a separate `pnpm exec tsx` server. All share the agent's process group.
    @Test func pnpmConcurrentlyUnderAgent() throws {
        let result = try load("pnpm-concurrently-agent").resolve()
        #expect(result.servers.count == 3)

        let client = try #require(result.servers.first { $0.package.name == "@acme/client" })
        #expect(client.framework?.name == "Vite")
        #expect(client.primaryPort == 4101)
        #expect(client.rootPID == 41324)               // pnpm --filter @acme/client dev, not concurrently
        #expect(client.url.absoluteString == "http://localhost:4101")
        #expect(client.project.name == "acme")

        let server = try #require(result.servers.first { $0.package.name == "@acme/server" })
        #expect(server.rootPID == 41323)               // pnpm → tsx cli → node collapsed
        #expect(server.chain.map(\.pid) == [41323, 41344, 41351])
        #expect(server.primaryPort == 4100)
        #expect(server.secondaryPorts == [4102])

        let agentLaunched = try #require(result.servers.first { $0.rootPID == 47419 })
        #expect(agentLaunched.chain.first?.arguments.contains("exec") == true)

        // Never signal the orchestrator or the agent's helper.
        let roots = Set(result.servers.map(\.rootPID))
        #expect(roots.isDisjoint(with: [41316, 41289, 41269, 47418]))
    }
}

// MARK: - Node family

@Suite("Node chains")
struct NodeChainTests {
    @Test func npmRunDevThroughShell() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/docs"
        w.file("\(app)/package.json", #"{"name":"docs","devDependencies":{"vite":"^6"}}"#)
        w.exists("\(app)/.git")
        w.proc(200, parent: World.terminalShell, exe: node, ["npm", "run", "dev"], cwd: app)
        w.proc(201, parent: 200, exe: "/bin/sh", ["sh", "-c", "vite"], cwd: app)
        w.proc(202, parent: 201, exe: node, ["node", "\(app)/node_modules/.bin/vite"], cwd: app)
        w.listen(202, 5173, address: "::1")

        let s = try #require(w.resolve().servers.first)
        #expect(s.rootPID == 200)                      // npm, not the interactive zsh
        #expect(s.chain.count == 3)
        #expect(s.framework?.id == "vite")
        #expect(s.project.name == "docs")
        #expect(s.url.absoluteString == "http://localhost:5173")
    }

    @Test func yarnNextDevMergesParentAndChildServer() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/shop"
        w.file("\(app)/package.json", #"{"name":"my-shop","dependencies":{"next":"15.0.0","react":"19"}}"#)
        w.proc(300, parent: World.terminalShell, exe: node, [node, "/Users/dev/.yarn/releases/yarn-4.5.cjs", "dev"], cwd: app)
        w.proc(301, parent: 300, exe: node, [node, "\(app)/node_modules/next/dist/bin/next", "dev"], cwd: app)
        // Next's dev server child renames itself via process.title.
        w.proc(302, parent: 301, exe: node, ["next-server (v15.0.0)"], cwd: app)
        w.listen(301, 3000)
        w.listen(302, 51234)

        let result = w.resolve()
        #expect(result.servers.count == 1)
        let s = try #require(result.servers.first)
        #expect(s.framework?.name == "Next.js")
        #expect(s.primaryPort == 3000)
        #expect(s.secondaryPorts == [51234])
        #expect(s.rootPID == 300)
    }

    @Test func turboStopsAtOrchestratorAndNamesMonorepoPackages() throws {
        var w = World.withTerminal()
        let repo = "/Users/dev/code/shop"
        w.file("\(repo)/package.json", #"{"name":"shop","private":true,"devDependencies":{"turbo":"2"}}"#)
        w.file("\(repo)/pnpm-workspace.yaml", "packages:\n  - apps/*\n")
        w.exists("\(repo)/.git")
        w.file("\(repo)/apps/web/package.json", #"{"name":"@shop/web","dependencies":{"next":"15"}}"#)
        w.file("\(repo)/apps/api/package.json", #"{"name":"@shop/api","dependencies":{"express":"5"}}"#)

        w.proc(400, parent: World.terminalShell, exe: "/opt/homebrew/bin/pnpm", ["pnpm", "dev"], cwd: repo)
        w.proc(401, parent: 400, exe: "\(repo)/node_modules/turbo-darwin-arm64/bin/turbo", ["turbo", "run", "dev"], cwd: repo)
        w.proc(410, parent: 401, exe: "/opt/homebrew/bin/pnpm", ["pnpm", "run", "dev"], cwd: "\(repo)/apps/web")
        w.proc(411, parent: 410, exe: node, [node, "\(repo)/node_modules/next/dist/bin/next", "dev"], cwd: "\(repo)/apps/web")
        w.proc(420, parent: 401, exe: "/opt/homebrew/bin/pnpm", ["pnpm", "run", "dev"], cwd: "\(repo)/apps/api")
        w.proc(421, parent: 420, exe: node, [node, "--watch", "server.js"], cwd: "\(repo)/apps/api")
        w.proc(422, parent: 421, exe: node, [node, "server.js"], cwd: "\(repo)/apps/api")
        w.listen(411, 3000)
        w.listen(422, 4000)

        let result = w.resolve()
        #expect(result.servers.count == 2)
        let web = try #require(result.servers.first { $0.package.name == "@shop/web" })
        let api = try #require(result.servers.first { $0.package.name == "@shop/api" })
        #expect(web.rootPID == 410)
        #expect(api.rootPID == 420)                    // through node --watch, stopping below turbo
        #expect(web.project == api.project)
        #expect(web.project.name == "shop")
        #expect(web.project.rootPath == repo)
        #expect(api.framework?.name == "Express")
    }

    /// An orchestrator no profile knows: `pnpm dev` with `"dev": "node a.js & node b.js"`.
    @Test func unknownOrchestratorDetectedBySiblingServers() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/pair"
        w.file("\(app)/package.json", #"{"name":"pair"}"#)
        w.proc(500, parent: World.terminalShell, exe: "/opt/homebrew/bin/pnpm", ["pnpm", "dev"], cwd: app)
        w.proc(501, parent: 500, exe: "/bin/sh", ["sh", "-c", "node a.js & node b.js"], cwd: app)
        w.proc(502, parent: 501, exe: node, [node, "a.js"], cwd: app)
        w.proc(503, parent: 501, exe: node, [node, "b.js"], cwd: app)
        w.listen(502, 3001)
        w.listen(503, 3002)

        let roots = w.resolve().servers.map(\.rootPID).sorted()
        #expect(roots == [502, 503])                   // stopping one must not kill the other
    }

    @Test func agentShellIsNotPartOfTheServer() throws {
        var w = World()
        let app = "/Users/dev/code/blog"
        w.file("\(app)/package.json", #"{"name":"blog","dependencies":{"astro":"5"}}"#)
        w.proc(1, parent: 0, exe: "/sbin/launchd", ["/sbin/launchd"])
        w.proc(600, parent: 1, exe: "/Users/dev/.local/bin/claude", ["claude"], cwd: app)
        w.proc(601, parent: 600, exe: "/bin/zsh", ["/bin/zsh", "-c", "-l", "npm run dev"], cwd: app)
        w.proc(602, parent: 601, exe: node, ["npm", "run", "dev"], cwd: app)
        w.proc(603, parent: 602, exe: "/bin/sh", ["sh", "-c", "astro dev"], cwd: app)
        w.proc(604, parent: 603, exe: node, [node, "\(app)/node_modules/astro/astro.js", "dev"], cwd: app)
        w.listen(604, 4321)

        let s = try #require(w.resolve().servers.first)
        #expect(s.rootPID == 602)
        #expect(s.framework?.name == "Astro")
    }

    @Test func bunRunDev() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/api"
        w.file("\(app)/package.json", #"{"name":"bun-api","dependencies":{"hono":"4"}}"#)
        w.proc(700, parent: World.terminalShell, exe: "/Users/dev/.bun/bin/bun", ["bun", "run", "dev"], cwd: app)
        w.proc(701, parent: 700, exe: "/Users/dev/.bun/bin/bun", ["bun", "src/index.ts"], cwd: app)
        w.listen(701, 3000, address: "0.0.0.0")

        let s = try #require(w.resolve().servers.first)
        #expect(s.runtime == "bun")
        #expect(s.rootPID == 700)
        #expect(s.framework?.name == "Hono")
    }

    @Test func denoTaskWithDenoJSON() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/fresh"
        w.file("\(app)/deno.json", #"{ "name": "@me/fresh", "imports": { "hono": "jsr:@hono/hono@^4" } }"#)
        w.proc(750, parent: World.terminalShell, exe: "/opt/homebrew/bin/deno", ["deno", "task", "dev"], cwd: app)
        w.proc(751, parent: 750, exe: "/opt/homebrew/bin/deno", ["deno", "run", "-A", "main.ts"], cwd: app)
        w.listen(751, 8000)

        let s = try #require(w.resolve().servers.first)
        #expect(s.runtime == "deno")
        #expect(s.package.name == "@me/fresh")
        #expect(s.rootPID == 750)
    }

    @Test func inspectorPortHiddenAndHTTPSDetected() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/secure"
        w.file("\(app)/package.json", #"{"name":"secure","devDependencies":{"vite":"6"}}"#)
        w.proc(800, parent: World.terminalShell, exe: node,
               [node, "--inspect=127.0.0.1:9231", "\(app)/node_modules/vite/bin/vite.js", "--https", "--port", "5200"], cwd: app)
        w.listen(800, 9231)
        w.listen(800, 5200)
        w.listen(800, 24678)                            // HMR websocket

        let s = try #require(w.resolve().servers.first)
        #expect(s.primaryPort == 5200)
        #expect(s.hiddenPorts == [9231])
        #expect(s.secondaryPorts == [24678])
        #expect(s.url.absoluteString == "https://localhost:5200")
    }

    @Test func globalToolWithoutProjectIsDropped() throws {
        var w = World.withTerminal()
        w.proc(900, parent: World.terminalShell, exe: node,
               [node, "/opt/homebrew/lib/node_modules/some-mcp-server/dist/index.js"], cwd: World.home)
        w.listen(900, 7777)
        // A stray ~/package.json must not turn everything under ~ into one project.
        w.file("\(World.home)/package.json", #"{"name":"oops"}"#)

        let result = w.resolve()
        #expect(result.servers.isEmpty)
        #expect(result.dropped.first?.reason.hasPrefix("no project found") == true)
    }

    /// The user denied this app access to ~/Desktop: the server must still appear.
    @Test func deniedFolderStillShowsServer() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/Desktop/projects/acme/apps/client"
        w.file("\(app)/package.json", #"{"name":"@acme/client","devDependencies":{"vite":"6"}}"#)
        w.denied = ["/Users/dev/Desktop"]
        w.proc(960, parent: World.terminalShell, exe: node, [node, "\(app)/node_modules/vite/bin/vite.js"], cwd: app)
        w.listen(960, 5173)

        let s = try #require(w.resolve().servers.first)
        #expect(s.package.accessDenied)
        #expect(s.package.name == "client")            // folder name: package.json was unreadable
        #expect(s.framework?.name == "Vite")           // still known from the command line
        #expect(s.project.rootPath == app)
    }

    /// Seen live: vitest fork workers in a worktree listen on throwaway ports while tests run.
    @Test func testRunnerWorkersAreNotServers() {
        var w = World.withTerminal()
        let repo = "/Users/dev/code/acme"
        w.file("\(repo)/package.json", #"{"name":"acme","devDependencies":{"vitest":"5"}}"#)
        w.proc(970, parent: World.terminalShell, exe: node, [node, "\(repo)/node_modules/vitest/vitest.mjs", "run"], cwd: repo)
        w.proc(971, parent: 970, exe: node,
               [node, "--experimental-import-meta-resolve", "--conditions", "node",
                "\(repo)/node_modules/.pnpm/vitest@5.0.5/node_modules/vitest/dist/workers/forks.js"], cwd: repo)
        w.listen(971, 64193)
        w.file("/Users/dev/code/api/pyproject.toml", "[project]\nname = \"api\"\n")
        w.proc(980, parent: World.terminalShell, exe: python, ["python3", "-m", "pytest", "-n", "4"], cwd: "/Users/dev/code/api")
        w.listen(980, 52000)

        let result = w.resolve()
        #expect(result.servers.isEmpty)
        #expect(result.dropped.filter { $0.reason == "Test runner worker" }.count == 2)
    }

    @Test func nonRuntimeListenersAreIgnored() {
        var w = World.withTerminal()
        w.proc(950, parent: 1, exe: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
               ["ControlCenter"])
        w.listen(950, 5000, address: "0.0.0.0")
        #expect(w.resolve().servers.isEmpty)
    }
}

// MARK: - Python

@Suite("Python chains")
struct PythonChainTests {
    @Test func djangoRunserverAutoreloader() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/blog"
        w.exists("\(app)/manage.py")
        w.file("\(app)/requirements.txt", "Django==5.1\npsycopg[binary]\n")
        // Django's reloader parent re-runs itself; the child serves.
        w.proc(1000, parent: World.terminalShell, exe: python, ["python3", "manage.py", "runserver", "8001"], cwd: app)
        w.proc(1001, parent: 1000, exe: python, [python, "-W", "ignore", "manage.py", "runserver", "8001"], cwd: app)
        w.listen(1001, 8001)

        let s = try #require(w.resolve().servers.first)
        #expect(s.runtime == "python")
        #expect(s.rootPID == 1000)
        #expect(s.framework?.name == "Django")
        #expect(s.package.manifest == "requirements.txt")
        #expect(s.primaryPort == 8001)
    }

    @Test func uvRunUvicornReloadSharedSocket() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/ml-api"
        w.file("\(app)/pyproject.toml", """
        [project]
        name = "ml-api"
        dependencies = ["fastapi>=0.115", "uvicorn[standard]"]
        """)
        w.proc(1100, parent: World.terminalShell, exe: "/opt/homebrew/bin/uv",
               ["uv", "run", "uvicorn", "app.main:app", "--reload", "--port", "8010"], cwd: app)
        w.proc(1101, parent: 1100, exe: python,
               ["\(app)/.venv/bin/python3", "\(app)/.venv/bin/uvicorn", "app.main:app", "--reload", "--port", "8010"], cwd: app)
        w.proc(1102, parent: 1101, exe: python,
               ["\(app)/.venv/bin/python3", "-c", "from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=5, pipe_handle=7)",
                "--multiprocessing-fork"], cwd: app)
        let pcb = w.listen(1101, 8010)
        w.listen(1102, 8010, pcb: pcb)                // worker inherited the supervisor's socket

        let result = w.resolve()
        #expect(result.servers.count == 1)
        let s = try #require(result.servers.first)
        #expect(s.rootPID == 1100)
        #expect(s.framework?.name == "FastAPI")
        #expect(s.package.name == "ml-api")
        #expect(Set(s.listenerPIDs) == [1101, 1102])
    }

    @Test func flaskRunWithWerkzeugReloader() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/shortener"
        w.file("\(app)/pyproject.toml", "[tool.poetry]\nname = \"shortener\"\n[tool.poetry.dependencies]\nflask = \"^3\"\n")
        w.proc(1200, parent: World.terminalShell, exe: python, ["python3", "-m", "flask", "run", "--port", "5001", "--debug"], cwd: app)
        w.proc(1201, parent: 1200, exe: python, [python, "-m", "flask", "run", "--port", "5001", "--debug"], cwd: app)
        let pcb = w.listen(1200, 5001)
        w.listen(1201, 5001, pcb: pcb)

        let s = try #require(w.resolve().servers.first)
        #expect(s.framework?.name == "Flask")
        #expect(s.package.name == "shortener")
        #expect(s.rootPID == 1200)
    }

    @Test func jupyterLabShownKernelsDropped() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/analysis"
        w.file("\(app)/requirements.txt", "jupyterlab\npandas\n")
        w.proc(1300, parent: World.terminalShell, exe: python, ["\(app)/.venv/bin/python", "\(app)/.venv/bin/jupyter-lab"], cwd: app)
        w.proc(1301, parent: 1300, exe: python,
               ["\(app)/.venv/bin/python", "-m", "ipykernel_launcher", "-f", "/Users/dev/Library/Jupyter/runtime/kernel-1.json"], cwd: app)
        w.listen(1300, 8888)
        for port: UInt16 in [50001, 50002, 50003, 50004, 50005] { w.listen(1301, port) }

        let result = w.resolve()
        #expect(result.servers.count == 1)
        #expect(result.servers.first?.framework?.name == "Jupyter")
        #expect(result.servers.first?.primaryPort == 8888)
        #expect(result.dropped.contains { $0.reason == "Jupyter kernel" })
    }

    @Test func pythonInterpreterNames() {
        for name in ["python", "python3", "python3.12", "Python", "python3.13t"] {
            #expect(PythonProfile.isInterpreterName(name), "\(name)")
        }
        for name in ["pythonw-helper", "ipython", "pyright"] {
            #expect(!PythonProfile.isInterpreterName(name), "\(name)")
        }
    }
}

// MARK: - Units

@Suite("Helpers")
struct HelperTests {
    @Test func shellRoles() {
        func p(_ args: [String]) -> ProcessSnapshot {
            ProcessSnapshot(pid: 1, ppid: 0, pgid: 1, uid: 501, startTime: 0, executablePath: "/bin/zsh", arguments: args, cwd: nil)
        }
        #expect(Shells.role(of: p(["-zsh"])) == .other)
        #expect(Shells.role(of: p(["/bin/zsh", "-i"])) == .other)
        #expect(Shells.role(of: p(["sh", "-c", "vite"])) == .shellCommand)
        #expect(Shells.role(of: p(["/bin/zsh", "-lc", "npm run dev"])) == .shellCommand)
    }

    @Test func retitledArgvIsSplit() {
        #expect(LiveProcessSource.normalizeRetitled(["npm run dev", "", "", ""]) == ["npm", "run", "dev"])
        #expect(LiveProcessSource.normalizeRetitled(["node", "server.js"]) == ["node", "server.js"])
        #expect(LiveProcessSource.normalizeRetitled(["/Applications/My App.app/Contents/MacOS/My App", "--flag"])
                == ["/Applications/My App.app/Contents/MacOS/My App", "--flag"])
    }

    @Test func scriptArgumentSkipsInterpreterFlags() {
        #expect(Args.script(of: ["node", "--require", "x.cjs", "--import", "y.mjs", "src/index.ts"]) == "src/index.ts")
        #expect(Args.script(of: ["python3", "-W", "ignore", "manage.py", "runserver"]) == "manage.py")
        #expect(Args.script(of: ["python3", "-m", "flask"]) == nil)
    }

    @Test func requestedPorts() {
        #expect(Resolver.requestedPorts([["vite", "--port", "5200"]]) == [5200])
        #expect(Resolver.requestedPorts([["jupyter-lab", "--port=8899"]]) == [8899])
        #expect(Resolver.requestedPorts([["python", "manage.py", "runserver", "0.0.0.0:8002"]]) == [8002])
    }

    @Test func walkUpStopsBeforeHome() {
        #expect(Paths.walkUp(from: "/Users/dev/code/a", home: "/Users/dev") == ["/Users/dev/code/a", "/Users/dev/code"])
        #expect(Paths.walkUp(from: "/Users/dev", home: "/Users/dev").isEmpty)
    }

    @Test func pyprojectName() {
        let toml = "[build-system]\nname = \"wrong\"\n[project]\nname = \"right\"\n"
        #expect(PythonProfile.tomlName(toml, sections: ["[project]"]) == "right")
    }
}
