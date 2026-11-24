import AppKit
import HeadwaiterCore
import SwiftUI

/// `HW_SNAPSHOT=/some/dir Headwaiter` renders the real views with sample data to PNGs
/// (light and dark) and exits. Lets every state be checked without staging it live.
@MainActor
enum Snapshots {
    static var directory: String? { ProcessInfo.processInfo.environment["HW_SNAPSHOT"] }

    /// A made-up project favicon for the renders: a symbol on a colored circle.
    static func sampleIcon(_ color: NSColor, symbol: String) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
                .applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: (32 - size.width) / 2, y: (32 - size.height) / 2,
                                      width: size.width, height: size.height))
            }
            return true
        }
    }

    static func renderAll(to dir: String) {
        let now = Date().timeIntervalSince1970
        let servers = sampleServers(now: now)
        let byName = { (name: String) in servers.first { $0.package.name == name }! }

        let list = ServerStore(live: false)
        list.preview(
            servers: servers,
            stopStates: [
                byName("docs").id: .stopping,
                byName("stubborn").id: .needsForceQuit(StopPlan(root: ProcessIdentity(pid: 1, startTime: 0), targets: [])),
                byName("ml-api").id: .failed("Not allowed to stop process 1102"),
            ],
            newSince: Date(timeIntervalSince1970: now - 120),
            recentlyStopped: sampleHistory(from: servers, now: now),
            openCount: 3,
            containers: sampleContainers(now: now),
            icons: [byName("@shop/web").package.path: sampleIcon(.systemOrange, symbol: "cart.fill"),
                    byName("ml-api").package.path: sampleIcon(.systemIndigo, symbol: "brain")],
            expanded: [byName("@shop/api").id])

        let emptyHistory = ServerStore(live: false)
        emptyHistory.preview(servers: [], recentlyStopped: sampleHistory(from: servers, now: now))

        let empty = ServerStore(live: false)
        empty.preview(servers: [])

        let welcome = ServerStore(live: false)
        welcome.preview(servers: Array(servers.prefix(2)), welcome: true)

        let filtering = PopoverKeyboard()
        filtering.preview(filter: "shop", selection: byName("@shop/api").id)

        let log = LogStore(previewLines: sampleLog(from: servers, now: now))

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            write(PopoverView(store: list), scheme: scheme, to: "\(dir)/popover-list-\(suffix).png")
            write(PopoverView(store: list, keyboard: filtering), scheme: scheme, to: "\(dir)/popover-filter-\(suffix).png")
            write(PopoverView(store: emptyHistory), scheme: scheme, to: "\(dir)/popover-empty-history-\(suffix).png")
            write(PopoverView(store: empty), scheme: scheme, to: "\(dir)/popover-empty-\(suffix).png")
            write(PopoverView(store: welcome), scheme: scheme, to: "\(dir)/popover-welcome-\(suffix).png")
            write(GeneralSettings(updater: Updater(previewVersion: nil)), scheme: scheme,
                  to: "\(dir)/settings-general-\(suffix).png")
            write(NotificationSettings(), scheme: scheme, to: "\(dir)/settings-notifications-\(suffix).png")
            write(ProjectSettings(store: list), scheme: scheme, to: "\(dir)/settings-projects-\(suffix).png")
            write(LogSettings(log: log), scheme: scheme, to: "\(dir)/settings-log-\(suffix).png")
            write(LogView(log: log).frame(width: 860, height: 260), scheme: scheme, to: "\(dir)/log-\(suffix).png")
            write(PopoverView(store: empty, updater: Updater(previewVersion: "0.5")), scheme: scheme,
                  to: "\(dir)/popover-update-\(suffix).png")
            writeIcons(scheme: scheme, to: "\(dir)/menubar-icons-\(suffix).png")
        }
        print("Snapshots written to \(dir)")
    }

    // MARK: Rendering

    /// Hosts the view in an offscreen window so AppKit-backed pieces (ScrollView, Menu,
    /// ProgressView) render, which ImageRenderer can't do.
    static func write<V: View>(_ view: V, scheme: ColorScheme, to path: String) {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2)) // let onGeometryChange settle
        host.layoutSubtreeIfNeeded()
        let fitted = host.fittingSize
        window.setContentSize(fitted)
        host.frame = NSRect(origin: .zero, size: fitted)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// The template icon tinted the way the menu bar would, on a matching bar color.
    static func writeIcons(scheme: ColorScheme, to path: String) {
        let variants: [(Int, Bool)] = [(0, false), (0, true), (3, false), (3, true), (12, true)]
        let images = variants.map { MenuBarIcon.image(count: $0.0, changed: $0.1) }
        let scale: CGFloat = 4
        let pad: CGFloat = 12
        let width = images.reduce(pad) { $0 + $1.size.width + pad }
        let size = NSSize(width: width * scale, height: 30 * scale)
        let canvas = NSImage(size: size, flipped: false) { rect in
            (scheme == .dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.9, alpha: 1)).setFill()
            rect.fill()
            var x = pad
            for image in images {
                let target = NSRect(x: x * scale, y: (30 - image.size.height) / 2 * scale,
                                    width: image.size.width * scale, height: image.size.height * scale)
                let tinted = NSImage(size: image.size, flipped: false) { r in
                    image.draw(in: r)
                    (scheme == .dark ? NSColor.white : NSColor.black).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: target)
                x += image.size.width + pad
            }
            return true
        }
        if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: Sample data (resolved through the real pipeline)

    static func sampleServers(now: Double) -> [Server] {
        let home = NSHomeDirectory()
        let node = "/usr/local/bin/node"
        let python = "/usr/bin/python3"
        var processes: [ProcessSnapshot] = []
        var sockets: [ListeningSocket] = []
        var files: [String: String] = [:]
        var otherPaths: [String] = []
        var denied: Set<String> = []
        var pcb: UInt64 = 1

        func proc(_ pid: Int32, _ ppid: Int32, _ exe: String, _ args: [String], _ cwd: String, age: Double) {
            processes.append(ProcessSnapshot(pid: pid, ppid: ppid, pgid: pid, uid: 501, startTime: now - age,
                                             executablePath: exe, arguments: args, cwd: cwd))
        }
        func listen(_ pid: Int32, _ port: UInt16) {
            pcb += 1
            sockets.append(ListeningSocket(pid: pid, port: port, address: "127.0.0.1", pcb: pcb))
        }

        proc(1, 0, "/sbin/launchd", ["launchd"], "/", age: 99_999)
        proc(10, 1, "/bin/zsh", ["-zsh"], home, age: 9_999)

        let shop = "\(home)/code/my-shop"
        files["\(shop)/package.json"] = #"{"name":"my-shop","workspaces":["apps/*"]}"#
        otherPaths.append("\(shop)/.git")
        files["\(shop)/apps/web/package.json"] = #"{"name":"@shop/web","dependencies":{"next":"15"}}"#
        files["\(shop)/apps/api/package.json"] = #"{"name":"@shop/api","dependencies":{"express":"5"}}"#
        proc(100, 10, "/opt/homebrew/bin/pnpm", ["pnpm", "--filter", "@shop/web", "dev"], "\(shop)/apps/web", age: 60)
        proc(101, 100, node, [node, "\(shop)/node_modules/next/dist/bin/next", "dev"], "\(shop)/apps/web", age: 60)
        listen(101, 3000); listen(101, 9229)
        proc(110, 10, "/opt/homebrew/bin/pnpm", ["pnpm", "--filter", "@shop/api", "dev"], "\(shop)/apps/api", age: 8_040)
        proc(111, 110, node, [node, "server.js"], "\(shop)/apps/api", age: 8_040)
        listen(111, 4000); listen(111, 4001)

        let tree = "\(shop)/.claude/worktrees/checkout-fix"
        files["\(tree)/package.json"] = #"{"name":"my-shop","workspaces":["apps/*"]}"#
        files["\(tree)/.git"] = "gitdir: \(shop)/.git/worktrees/checkout-fix\n"
        files["\(tree)/apps/web/package.json"] = #"{"name":"@shop/web","dependencies":{"next":"15"}}"#
        proc(150, 10, "/opt/homebrew/bin/pnpm", ["pnpm", "--filter", "@shop/web", "dev"], "\(tree)/apps/web", age: 30)
        proc(151, 150, node, [node, "\(tree)/node_modules/next/dist/bin/next", "dev", "--port", "3100"], "\(tree)/apps/web", age: 30)
        listen(151, 3100)

        let docs = "\(home)/code/docs"
        files["\(docs)/package.json"] = #"{"name":"docs","devDependencies":{"vite":"6"}}"#
        proc(200, 10, node, ["npm", "run", "dev"], docs, age: 900)
        proc(201, 200, node, [node, "\(docs)/node_modules/vite/bin/vite.js"], docs, age: 900)
        listen(201, 5173)

        let stubborn = "\(home)/code/stubborn"
        files["\(stubborn)/package.json"] = #"{"name":"stubborn"}"#
        proc(300, 10, node, ["npm", "run", "dev"], stubborn, age: 400)
        proc(301, 300, node, [node, "server.js"], stubborn, age: 400)
        listen(301, 3470)

        let ml = "\(home)/code/ml-api"
        files["\(ml)/pyproject.toml"] = "[project]\nname = \"ml-api\"\ndependencies = [\"fastapi\"]\n"
        proc(400, 10, "/opt/homebrew/bin/uv", ["uv", "run", "uvicorn", "app.main:app", "--reload"], ml, age: 186_000)
        proc(401, 400, python, ["python3", "\(ml)/.venv/bin/uvicorn", "app.main:app", "--reload"], ml, age: 186_000)
        listen(401, 8000)

        let secret = "\(home)/Desktop/client-portal"
        files["\(secret)/package.json"] = #"{"name":"@acme/portal","devDependencies":{"vite":"6"}}"#
        denied.insert("\(home)/Desktop")
        proc(500, 10, node, [node, "\(secret)/node_modules/vite/bin/vite.js"], secret, age: 3_700)
        listen(500, 5174)

        let fixture = Fixture(name: "snapshot", homeDirectory: home, processes: processes, sockets: sockets)
        let fs = InMemoryFileSystem(files: files, otherPaths: Set(otherPaths), deniedDirectories: denied, homeDirectory: home)
        return Resolver(fs: fs).resolve(fixture.source).servers
    }

    /// A Compose Postgres in the my-shop project, plus a loose nginx container.
    static func sampleContainers(now: Double) -> [ContainerServer] {
        let shop = "\(NSHomeDirectory())/code/my-shop"
        let raw: [DockerContainer] = [
            DockerContainer(Id: String(repeating: "a", count: 64), Names: ["/my-shop-db-1"], Image: "postgres:16",
                            Created: now - 9_000, State: "running",
                            Ports: [.init(IP: "0.0.0.0", PrivatePort: 5432, PublicPort: 5433, Type: "tcp")],
                            Labels: ["com.docker.compose.project": "my-shop", "com.docker.compose.service": "db",
                                     "com.docker.compose.project.working_dir": shop]),
            DockerContainer(Id: String(repeating: "b", count: 64), Names: ["/cranky_turing"], Image: "nginx:alpine",
                            Created: now - 300, State: "running",
                            Ports: [.init(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 8088, Type: "tcp")], Labels: [:]),
        ]
        return ContainerResolver.servers(from: raw)
    }

    static func sampleLog(from servers: [Server], now: Double) -> [String] {
        let items = servers.map { s in
            LogItem(id: s.id, key: s.id, name: s.package.name, project: s.project.displayName,
                    kind: s.framework?.name ?? s.runtime, port: s.primaryPort, process: ProcessIdentity(s.root),
                    path: s.package.path, startTime: s.startTime)
        }
        let starts = items.map { LogEvent(.started, $0, time: $0.startTime) }.sorted { $0.time < $1.time }
        let sources: [LogEvent.StopSource?] = [nil, .headwaiter, .forceQuit]
        let stops = zip(items, sources).map { LogEvent(.stopped($1), $0, time: now) }
        return (starts + stops).map { $0.line() }
    }

    static func sampleHistory(from servers: [Server], now: Double) -> [StoppedServer] {
        guard let template = servers.first(where: { $0.package.name == "docs" }) else { return [] }
        var a = StoppedServer(template, stoppedAt: Date(timeIntervalSince1970: now - 720))
        a.id = "h1"; a.packageName = "storybook"; a.framework = "Storybook"; a.frameworkID = "storybook"; a.port = 6006
        a.subtitle = "storybook"; a.projectName = "design-system"
        var b = StoppedServer(template, stoppedAt: Date(timeIntervalSince1970: now - 7_300))
        b.id = "h2"; b.packageName = "blog"; b.framework = "Astro"; b.frameworkID = "astro"; b.port = 4321; b.subtitle = "dev"; b.projectName = "blog"
        var c = StoppedServer(template, stoppedAt: Date(timeIntervalSince1970: now - 40))
        c.id = "h3"; c.packageName = "admin"; c.framework = "Vite"; c.frameworkID = "vite"; c.port = 5175
        c.subtitle = "apps/admin · dev"; c.projectName = "my-shop"
        return [c, a, b]
    }
}
