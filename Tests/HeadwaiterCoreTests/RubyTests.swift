import Foundation
import Testing
@testable import HeadwaiterCore

@Suite("Ruby")
struct RubyTests {
    let ruby = "/Users/dev/.rbenv/versions/3.3.5/bin/ruby"
    let gemfile = "source \"https://rubygems.org\"\ngem \"rails\", \"~> 7.2\"\ngem \"puma\"\n"

    /// `bin/dev` → foreman (orchestrator) → puma (retitled) and a CSS watcher. Stop must take
    /// only Puma, never foreman or the watcher.
    @Test func railsUnderForeman() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/shop"
        w.file("\(app)/Gemfile", gemfile)
        w.proc(200, parent: World.terminalShell, exe: ruby, [ruby, "/Users/dev/.rbenv/versions/3.3.5/bin/foreman", "start", "-f", "Procfile.dev"], cwd: app)
        w.proc(201, parent: 200, exe: ruby, ["puma", "6.4.3", "(tcp://localhost:3000)", "[shop]"], cwd: app)
        w.proc(202, parent: 200, exe: "/Users/dev/code/shop/bin/tailwindcss", ["tailwindcss", "-w"], cwd: app)
        w.listen(201, 3000)

        let s = try #require(w.resolve().servers.first)
        #expect(s.runtime == "ruby")
        #expect(s.framework?.name == "Rails")
        #expect(s.rootPID == 201)
        #expect(s.package.name == "shop")
        let targets = try #require(Stopper.plan(for: s, source: w.source)).targets.map(\.pid)
        #expect(targets == [201])
    }

    @Test func bundleExecRailsServer() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/blog"
        w.file("\(app)/Gemfile", gemfile)
        w.proc(300, parent: World.terminalShell, exe: ruby, [ruby, "/Users/dev/.rbenv/shims/bundle", "exec", "rails", "server"], cwd: app)
        w.proc(301, parent: 300, exe: ruby, ["puma", "6.4.3", "(tcp://127.0.0.1:3000)", "[blog]"], cwd: app)
        w.listen(301, 3000)

        let s = try #require(w.resolve().servers.first)
        #expect(s.rootPID == 300)
        #expect(s.framework?.name == "Rails")
        #expect(Display.scriptLabel(s.root) == "rails server")
    }

    @Test func pumaClusterWorkersShareTheSocket() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/api"
        w.exists("\(app)/config.ru")
        w.file("\(app)/Gemfile", "gem 'sinatra'\ngem 'puma'\n")
        w.proc(400, parent: World.terminalShell, exe: ruby, ["puma", "6.4.3", "(tcp://0.0.0.0:9292)", "[api]"], cwd: app)
        w.proc(401, parent: 400, exe: ruby, ["puma:", "cluster", "worker", "0:", "400", "[api]"], cwd: app)
        w.proc(402, parent: 400, exe: ruby, ["puma:", "cluster", "worker", "1:", "400", "[api]"], cwd: app)
        let pcb = w.listen(400, 9292, address: "0.0.0.0")
        w.listen(401, 9292, address: "0.0.0.0", pcb: pcb)
        w.listen(402, 9292, address: "0.0.0.0", pcb: pcb)

        let result = w.resolve()
        #expect(result.servers.count == 1)
        let s = try #require(result.servers.first)
        #expect(s.framework?.name == "Puma")          // the command says puma; Sinatra only from deps
        #expect(Set(s.listenerPIDs) == [400, 401, 402])
    }

    @Test func jekyllServe() throws {
        var w = World.withTerminal()
        let site = "/Users/dev/sites/journal"
        w.file("\(site)/Gemfile", "gem \"jekyll\", \"~> 4.3\"\n")
        w.proc(500, parent: World.terminalShell, exe: ruby, [ruby, "/Users/dev/.rbenv/shims/bundle", "exec", "jekyll", "serve"], cwd: site)
        w.listen(500, 4000)
        w.listen(500, 35729)                          // livereload

        let s = try #require(w.resolve().servers.first)
        #expect(s.framework?.name == "Jekyll")
        #expect(s.primaryPort == 4000)
        #expect(s.secondaryPorts == [35729])
    }

    @Test func springIsHidden() {
        var w = World.withTerminal()
        let app = "/Users/dev/code/shop"
        w.file("\(app)/Gemfile", gemfile)
        w.proc(600, parent: 1, exe: ruby, ["spring", "server", "|", "shop", "|", "started", "3", "mins", "ago"], cwd: app)
        w.listen(600, 51000)
        let result = w.resolve()
        #expect(result.servers.isEmpty)
        #expect(result.dropped.contains { $0.reason == "Rails Spring preloader" })
    }
}
