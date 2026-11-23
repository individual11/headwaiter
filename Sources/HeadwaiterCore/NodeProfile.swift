import Foundation

/// node, bun and deno. Projects are package.json or deno.json(c).
public struct NodeProfile: RuntimeProfile {
    public init() {}

    public let id = "node"

    static let runtimes: Set<String> = ["node", "nodejs", "bun", "deno"]

    public func runtimeName(of process: ProcessSnapshot) -> String? {
        let exe = process.executableName
        if Self.runtimes.contains(exe) { return exe == "nodejs" ? "node" : exe }
        return nil
    }

    /// Test workers often listen (tests start the app on port 0) but come and go every second.
    static let testWorkerFragments = ["/vitest/dist/workers/", "/vitest/dist/worker.js", "jest-worker", "/jest-runner/",
                                      "/jest-circus/", "/mocha/lib/", "/ava/lib/worker", "/@playwright/test/",
                                      "/playwright/lib/", "/playwright-core/lib/"]

    public func auxiliaryReason(_ process: ProcessSnapshot) -> String? {
        let lines = [process.arguments]
        if Args.contains(lines, fragments: Self.testWorkerFragments) { return "Test runner worker" }
        if Args.contains(lines, fragments: ["/typescript/lib/tsserver.js"]) { return "Node helper process" }
        return nil
    }

    // Package managers and framework CLIs that sit above the real server process.
    static let wrapperExecutables: Set<String> = ["npm", "npx", "pnpm", "pnpx", "yarn", "yarnpkg", "bunx", "corepack"]
    static let wrapperScriptFragments = [
        "/npm/bin/npm-cli.js", "/npm/bin/npx-cli.js", "/pnpm/bin/pnpm.cjs", "/pnpm/dist/pnpm.cjs",
        "/yarn/bin/yarn.js", "/.yarn/releases/", "/corepack/",
        "/tsx/dist/cli", "/nodemon/", "/ts-node-dev/", "/vite-node/",
        "/next/dist/bin/next", "/@nestjs/cli/", "/@remix-run/dev/", "/@react-router/dev/",
        "/astro/astro.js", "/@expo/cli/", "/expo/bin/", "/storybook/", "/@storybook/cli",
    ]
    static let orchestratorExecutables: Set<String> = ["turbo", "nx"]
    static let orchestratorFragments = ["/concurrently/", "/turbo/", "/nx/bin/", "/npm-run-all/",
                                        "/npm-run-all2/", "/lerna/", "/wireit/"]

    public func role(of process: ProcessSnapshot) -> ProcessRole? {
        let exe = process.executableName
        let args = process.arguments
        let lines = [args]

        if Self.orchestratorExecutables.contains(exe) || Args.contains(lines, fragments: Self.orchestratorFragments) {
            return .orchestrator
        }

        let isPackageManager = Self.wrapperExecutables.contains(exe)
            || Self.wrapperExecutables.contains(process.argv0Name)
            || Args.contains(lines, fragments: Array(Self.wrapperScriptFragments.prefix(7)))
        if isPackageManager {
            // Running a script in many packages at once is orchestration, not one server.
            let recursive: Set<String> = ["-r", "--recursive", "--parallel", "--workspaces", "-ws", "foreach"]
            return args.contains(where: recursive.contains) ? .orchestrator : .wrapper
        }

        if Args.contains(lines, fragments: Self.wrapperScriptFragments) { return .wrapper }

        switch exe {
        case "node", "nodejs":
            if args.contains("--watch") || args.contains(where: { $0.hasPrefix("--watch-path") }) { return .wrapper }
        case "bun":
            // `bun run dev`, `bunx vite`, `bun --watch server.ts`
            if let sub = Args.script(of: args), ["run", "x", "exec"].contains(sub) { return .wrapper }
            if args.contains("--watch") || args.contains("--hot") { return .wrapper }
        case "deno":
            if let sub = Args.script(of: args), sub == "task" { return .wrapper }
        default:
            break
        }
        return nil
    }

    public func scriptDirectories(of process: ProcessSnapshot) -> [String] {
        guard runtimeName(of: process) != nil, let script = Args.script(of: process.arguments),
              !script.contains("/node_modules/"),
              let abs = Paths.absolute(script, relativeTo: process.cwd) else { return [] }
        return [(abs as NSString).deletingLastPathComponent]
    }

    public func resolvePackage(startDirectories: [String], fs: FileReading) -> Package? {
        for start in startDirectories {
            for dir in Paths.walkUp(from: start, home: fs.homeDirectory) where !dir.contains("/node_modules/") {
                if let pkg = package(in: dir, fs: fs) { return pkg }
            }
        }
        return nil
    }

    func package(in dir: String, fs: FileReading) -> Package? {
        let folder = (dir as NSString).lastPathComponent
        if let text = fs.contents(of: Paths.join(dir, "package.json")) {
            let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
            var deps = Set<String>()
            for key in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
                if let d = json[key] as? [String: Any] { deps.formUnion(d.keys) }
            }
            let name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folder
            return Package(path: dir, name: name, dependencies: deps, manifest: "package.json")
        }
        for manifest in ["deno.json", "deno.jsonc"] {
            if let text = fs.contents(of: Paths.join(dir, manifest)) {
                return Package(path: dir, name: Self.jsonStringField("name", in: text) ?? folder,
                               dependencies: Self.denoDependencies(text), manifest: manifest)
            }
        }
        return nil
    }

    public func isWorkspaceRoot(_ dir: String, fs: FileReading) -> Bool {
        for marker in ["pnpm-workspace.yaml", "lerna.json", "nx.json", "turbo.json"] where fs.exists(Paths.join(dir, marker)) {
            return true
        }
        if let text = fs.contents(of: Paths.join(dir, "package.json")),
           let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
           json["workspaces"] != nil {
            return true
        }
        for manifest in ["deno.json", "deno.jsonc"] {
            if let text = fs.contents(of: Paths.join(dir, manifest)), text.contains("\"workspace\"") { return true }
        }
        return false
    }

    public func manifestName(in dir: String, fs: FileReading) -> String? {
        guard let pkg = package(in: dir, fs: fs) else { return nil }
        return pkg.name == (dir as NSString).lastPathComponent ? nil : pkg.name
    }

    /// Lenient `"field": "value"` lookup that tolerates JSONC comments.
    static func jsonStringField(_ field: String, in text: String) -> String? {
        let pattern = "\"\(field)\"\\s*:\\s*\"([^\"]+)\""
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// `"npm:express@^4"` and `"jsr:@std/http"` import specifiers become dependency names.
    static func denoDependencies(_ text: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: "\"(?:npm|jsr):(@?[^@\"/]+(?:/[^@\"/]+)?)") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(re.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } })
    }

    // Most specific first: meta-frameworks before Vite, Vite before plain HTTP libraries.
    public let frameworks: [FrameworkRule] = [
        FrameworkRule(Framework(id: "next", name: "Next.js", defaultPorts: [3000]), dependencies: ["next"]) { l, _ in
            Args.contains(l, fragments: ["/next/dist/", "next-server"]) || Args.invokes(l, commands: ["next"])
        },
        FrameworkRule(Framework(id: "remix", name: "Remix", defaultPorts: [5173, 3000]),
                      dependencies: ["@remix-run/dev"]) { l, _ in
            Args.contains(l, fragments: ["/@remix-run/dev/"]) || Args.invokes(l, commands: ["remix"])
        },
        FrameworkRule(Framework(id: "react-router", name: "React Router", defaultPorts: [5173]),
                      dependencies: ["@react-router/dev"]) { l, _ in
            Args.contains(l, fragments: ["/@react-router/dev/"]) || Args.invokes(l, commands: ["react-router"])
        },
        FrameworkRule(Framework(id: "astro", name: "Astro", defaultPorts: [4321]), dependencies: ["astro"]) { l, _ in
            Args.contains(l, fragments: ["/astro/astro.js", "/astro/dist/"]) || Args.invokes(l, commands: ["astro"])
        },
        FrameworkRule(Framework(id: "expo", name: "Expo", defaultPorts: [8081]), dependencies: ["expo"]) { l, _ in
            Args.contains(l, fragments: ["/@expo/cli/", "/expo/bin/"]) || Args.invokes(l, commands: ["expo"])
        },
        // Storybook is often a devDependency of an app; only its own command identifies it.
        FrameworkRule(Framework(id: "storybook", name: "Storybook", defaultPorts: [6006])) { l, _ in
            Args.contains(l, fragments: ["/storybook/", "/@storybook/"])
                || Args.invokes(l, commands: ["storybook", "start-storybook"])
        },
        FrameworkRule(Framework(id: "nest", name: "Nest", defaultPorts: [3000]), dependencies: ["@nestjs/core"]) { l, _ in
            Args.contains(l, fragments: ["/@nestjs/cli/"]) || Args.invokes(l, commands: ["nest"])
        },
        FrameworkRule(Framework(id: "vite", name: "Vite", defaultPorts: [5173]), dependencies: ["vite"]) { l, _ in
            Args.contains(l, fragments: ["/vite/bin/vite.js"]) || Args.invokes(l, commands: ["vite"])
        },
        FrameworkRule(Framework(id: "express", name: "Express", defaultPorts: [3000]), dependencies: ["express"]) { _, _ in false },
        FrameworkRule(Framework(id: "fastify", name: "Fastify", defaultPorts: [3000]), dependencies: ["fastify"]) { _, _ in false },
        FrameworkRule(Framework(id: "hono", name: "Hono", defaultPorts: [3000]), dependencies: ["hono"]) { _, _ in false },
        FrameworkRule(Framework(id: "koa", name: "Koa", defaultPorts: [3000]), dependencies: ["koa"]) { _, _ in false },
    ]
}
