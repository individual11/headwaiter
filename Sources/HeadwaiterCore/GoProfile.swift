import Foundation

/// Go. A Go server has no runtime executable to match: it *is* the project's compiled binary.
/// It's recognized by how it was built or where it lives:
/// - `go run` builds into Go's cache (…/go-build…/exe/<name>) with `go run` as the parent;
/// - reloaders (air, gow, reflex, CompileDaemon) rebuild it, usually into ./tmp or ./bin;
/// - any binary inside a folder tree with a go.mod (./bin/api, ./tmp/main).
/// Hugo (`hugo server`) counts too. Rust and .NET can reuse this "compiled server" approach.
public struct GoProfile: RuntimeProfile {
    public init() {}

    public let id = "go"

    static let reloaders: Set<String> = ["air", "gow", "reflex", "CompileDaemon", "gin", "realize", "fresh"]
    static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Applications/", "/Library/",
                                 "/opt/homebrew/Cellar/", "/opt/homebrew/Caskroom/"]

    public func runtimeName(of process: ProcessSnapshot) -> String? {
        if Self.isGoRunBinary(process.executablePath) || process.executableName == "hugo" { return "go" }
        return nil
    }

    public func runtimeName(of process: ProcessSnapshot, context: ProfileContext) -> String? {
        if let name = runtimeName(of: process) { return name }
        if let parent = context.parent(process) {
            if parent.executableName == "go", parent.arguments.dropFirst().first == "run" { return "go" }
            if Self.reloaders.contains(parent.executableName) { return "go" }
        }
        // A binary that lives inside a Go project.
        let exe = process.executablePath
        guard exe.hasPrefix("/"), !Self.systemPrefixes.contains(where: exe.hasPrefix) else { return nil }
        let dir = (exe as NSString).deletingLastPathComponent
        return Paths.walkUp(from: dir, home: context.fs.homeDirectory)
            .contains { context.fs.exists(Paths.join($0, "go.mod")) } ? "go" : nil
    }

    /// `go run` output: $TMPDIR/go-build123456/b001/exe/<name>.
    static func isGoRunBinary(_ path: String) -> Bool {
        path.contains("/go-build") && path.contains("/exe/")
    }

    public func auxiliaryReason(_ process: ProcessSnapshot) -> String? {
        switch process.executableName {
        case "dlv": "Go debugger"
        case "gopls": "Go language server"
        default: nil
        }
    }

    public func role(of process: ProcessSnapshot) -> ProcessRole? {
        let exe = process.executableName
        if exe == "go", process.arguments.dropFirst().first == "run" { return .wrapper }
        if Self.reloaders.contains(exe) { return .wrapper }
        return nil
    }

    public func scriptDirectories(of process: ProcessSnapshot) -> [String] {
        let exe = process.executablePath
        guard !Self.isGoRunBinary(exe), !Self.systemPrefixes.contains(where: exe.hasPrefix) else { return [] }
        return [(exe as NSString).deletingLastPathComponent]
    }

    public func resolvePackage(startDirectories: [String], fs: FileReading) -> Package? {
        for start in startDirectories {
            for dir in Paths.walkUp(from: start, home: fs.homeDirectory) {
                if let mod = fs.contents(of: Paths.join(dir, "go.mod")) {
                    return Package(path: dir, name: Self.moduleName(mod) ?? (dir as NSString).lastPathComponent,
                                   dependencies: Self.requirements(mod), manifest: "go.mod")
                }
                for config in ["hugo.toml", "hugo.yaml", "hugo.json"] where fs.exists(Paths.join(dir, config)) {
                    return Package(path: dir, name: (dir as NSString).lastPathComponent, dependencies: [], manifest: config)
                }
            }
        }
        return nil
    }

    public func isWorkspaceRoot(_ dir: String, fs: FileReading) -> Bool {
        fs.exists(Paths.join(dir, "go.work"))
    }

    public func manifestName(in dir: String, fs: FileReading) -> String? {
        fs.contents(of: Paths.join(dir, "go.mod")).flatMap(Self.moduleName)
    }

    /// "github.com/acme/shop-api" → "shop-api"; a trailing major version (/v2) is skipped.
    static func moduleName(_ mod: String) -> String? {
        guard let line = mod.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("module ") }) else { return nil }
        let path = line.trimmingCharacters(in: .whitespaces).dropFirst("module ".count)
            .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let parts = path.split(separator: "/")
        if parts.count > 1, let last = parts.last, last.first == "v", Int(last.dropFirst()) != nil {
            return String(parts[parts.count - 2])
        }
        return parts.last.map(String.init)
    }

    /// Module paths from require lines and blocks, with major-version suffixes (/v2) stripped.
    static func requirements(_ mod: String) -> Set<String> {
        var deps = Set<String>()
        var inBlock = false
        for raw in mod.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("require (") { inBlock = true; continue }
            if inBlock && line.hasPrefix(")") { inBlock = false; continue }
            var spec: Substring?
            if inBlock { spec = Substring(line) } else if line.hasPrefix("require ") { spec = line.dropFirst("require ".count) }
            guard let spec, let path = spec.split(separator: " ").first, path.contains(".") else { continue }
            var module = String(path)
            if let range = module.range(of: #"/v\d+$"#, options: .regularExpression) { module.removeSubrange(range) }
            deps.insert(module)
        }
        return deps
    }

    public let frameworks: [FrameworkRule] = [
        FrameworkRule(Framework(id: "hugo", name: "Hugo", defaultPorts: [1313])) { l, _ in
            Args.invokes(l, commands: ["hugo"])
        },
        FrameworkRule(Framework(id: "gin", name: "Gin", defaultPorts: [8080]), dependencies: ["github.com/gin-gonic/gin"]) { _, _ in false },
        FrameworkRule(Framework(id: "echo", name: "Echo", defaultPorts: [1323]), dependencies: ["github.com/labstack/echo"]) { _, _ in false },
        FrameworkRule(Framework(id: "fiber", name: "Fiber", defaultPorts: [3000]), dependencies: ["github.com/gofiber/fiber"]) { _, _ in false },
        FrameworkRule(Framework(id: "chi", name: "Chi", defaultPorts: [3000]), dependencies: ["github.com/go-chi/chi"]) { _, _ in false },
        FrameworkRule(Framework(id: "gorilla", name: "Gorilla", defaultPorts: [8080]), dependencies: ["github.com/gorilla/mux"]) { _, _ in false },
    ]
}
