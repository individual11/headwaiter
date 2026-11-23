import Foundation
import Testing
@testable import HeadwaiterCore

@Suite("Display")
struct DisplayTests {
    func p(_ args: [String], exe: String = "/usr/local/bin/node") -> ProcessSnapshot {
        ProcessSnapshot(pid: 1, ppid: 0, pgid: 1, uid: 501, startTime: 0, executablePath: exe, arguments: args, cwd: nil)
    }

    @Test(arguments: [
        (["pnpm", "--filter", "@acme/client", "dev"], "dev"),
        (["npm", "run", "dev"], "dev"),
        (["pnpm", "exec", "tsx", "/Users/dev/code/acme/.claude/worktrees/x/launch.mts"], "tsx launch.mts"),
        (["yarn", "workspace", "web", "start"], "workspace web start"),
        (["uv", "run", "uvicorn", "app.main:app", "--reload"], "uvicorn app.main:app"),
        (["python3", "manage.py", "runserver", "8001"], "manage.py runserver 8001"),
        (["python3", "-m", "http.server", "8765"], "-m http.server 8765"),
        (["node", "--require", "/x/tsx/preflight.cjs", "src/index.ts"], "index.ts"),
        (["node", "/Users/dev/code/app/node_modules/.bin/../vite/bin/vite.js"], "vite"),
    ])
    func scriptLabels(args: [String], expected: String) {
        #expect(Display.scriptLabel(p(args)) == expected)
    }

    @Test func worktreeProjectsAreLabelled() throws {
        var w = World.withTerminal()
        let main = "/Users/dev/code/acme"
        let tree = "\(main)/.claude/worktrees/checkout-fix"
        for root in [main, tree] {
            w.file("\(root)/package.json", #"{"name":"acme"}"#)
            w.file("\(root)/pnpm-workspace.yaml")
        }
        w.exists("\(main)/.git")                                    // a directory in the main clone
        w.file("\(tree)/.git", "gitdir: \(main)/.git/worktrees/checkout-fix\n")
        w.proc(200, parent: World.terminalShell, exe: node, [node, "a.js"], cwd: main)
        w.proc(201, parent: World.terminalShell, exe: node, [node, "a.js"], cwd: tree)
        w.listen(200, 3000)
        w.listen(201, 3001)

        let projects = w.resolve().servers.map(\.project)
        #expect(projects.map(\.displayName).sorted() == ["acme", "acme › checkout-fix"])
    }
}
