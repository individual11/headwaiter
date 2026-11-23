import Foundation
import Testing
@testable import HeadwaiterCore

@Suite("Go")
struct GoTests {
    let goMod = """
    module github.com/acme/shop-api/v2

    go 1.23

    require (
    \tgithub.com/gin-gonic/gin v1.10.0
    \tgithub.com/gofiber/fiber/v2 v2.52.0 // indirect
    )
    require golang.org/x/sync v0.8.0
    """

    @Test func goRunWithGin() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/shop-api"
        w.file("\(app)/go.mod", goMod)
        w.proc(200, parent: World.terminalShell, exe: "/opt/homebrew/Cellar/go/1.23.2/libexec/bin/go", ["go", "run", "./cmd/api"], cwd: app)
        w.proc(201, parent: 200, exe: "/private/var/folders/k3/x/T/go-build3141/b001/exe/api", ["/private/var/folders/k3/x/T/go-build3141/b001/exe/api"], cwd: app)
        w.listen(201, 8080, address: "::")

        let s = try #require(w.resolve().servers.first)
        #expect(s.runtime == "go")
        #expect(s.rootPID == 200)                         // go run is the wrapper; stop takes both
        #expect(s.package.name == "shop-api")             // module path, /v2 skipped
        #expect(s.framework?.name == "Gin")
        #expect(Display.scriptLabel(s.root) == "go run ./cmd/api")
    }

    @Test func airRebuildsIntoProjectTmp() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/blog-api"
        w.file("\(app)/go.mod", "module blog-api\n\nrequire github.com/labstack/echo/v4 v4.12.0\n")
        w.proc(300, parent: World.terminalShell, exe: "/Users/dev/go/bin/air", ["air"], cwd: app)
        w.proc(301, parent: 300, exe: "\(app)/tmp/main", ["./tmp/main"], cwd: app)
        w.listen(301, 1323)

        let s = try #require(w.resolve().servers.first)
        #expect(s.rootPID == 300)
        #expect(s.framework?.name == "Echo")
        #expect(s.package.name == "blog-api")
    }

    @Test func builtBinaryInsideProject() throws {
        var w = World.withTerminal()
        let app = "/Users/dev/code/edge"
        w.file("\(app)/go.mod", "module example.com/edge\n")
        w.proc(400, parent: World.terminalShell, exe: "\(app)/bin/edge", ["./bin/edge", "--port", "9000"], cwd: app)
        w.listen(400, 9000)

        let s = try #require(w.resolve().servers.first)
        #expect(s.runtime == "go")
        #expect(s.package.name == "edge")
        #expect(s.primaryPort == 9000)
    }

    @Test func hugoServer() throws {
        var w = World.withTerminal()
        let site = "/Users/dev/sites/notes"
        w.exists("\(site)/hugo.toml")
        w.proc(500, parent: World.terminalShell, exe: "/opt/homebrew/bin/hugo", ["hugo", "server", "-D"], cwd: site)
        w.listen(500, 1313)

        let s = try #require(w.resolve().servers.first)
        #expect(s.framework?.name == "Hugo")
        #expect(s.package.manifest == "hugo.toml")
    }

    @Test func unrelatedBinariesAreNotGo() {
        var w = World.withTerminal()
        // Installed Go tools in ~/go/bin and app binaries are not projects.
        w.file("/Users/dev/go.mod", "module oops\n")  // even a stray go.mod in ~ doesn't count
        w.proc(600, parent: World.terminalShell, exe: "/Users/dev/go/bin/someproxy", ["someproxy"], cwd: "/Users/dev")
        w.listen(600, 7000)
        w.proc(601, parent: 1, exe: "/Applications/Dropbox.app/Contents/MacOS/Dropbox", ["Dropbox"], cwd: "/")
        w.listen(601, 17600)
        w.proc(602, parent: World.terminalShell, exe: "/Users/dev/go/bin/dlv", ["dlv", "debug", "--headless"], cwd: "/Users/dev/code/edge")
        w.listen(602, 2345)

        #expect(w.resolve().servers.isEmpty)
    }

    @Test func moduleParsing() {
        #expect(GoProfile.moduleName("module github.com/acme/shop-api/v2\n") == "shop-api")
        #expect(GoProfile.moduleName("module \"example.com/x\"") == "x")
        #expect(GoProfile.requirements(goMod) == ["github.com/gin-gonic/gin", "github.com/gofiber/fiber", "golang.org/x/sync"])
    }
}
