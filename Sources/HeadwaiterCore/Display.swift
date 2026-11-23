import Foundation

/// Text formatting shared by the CLI and the app.
public enum Display {
    /// "40s", "12m", "2h 14m", "3d 05h".
    public static func uptime(since start: Double, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince1970 - start))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m" }
        return "\(s / 86400)d \(String(format: "%02d", (s % 86400) / 3600))h"
    }

    /// Replaces the home directory prefix with "~".
    public static func abbreviatingHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Command line with argv[0] shortened to its basename and home paths abbreviated:
    /// `pnpm --filter web dev`.
    public static func command(_ p: ProcessSnapshot, home: String = NSHomeDirectory()) -> String {
        ([p.argv0Name] + p.arguments.dropFirst())
            .joined(separator: " ")
            .replacingOccurrences(of: home + "/", with: "~/")
    }
}

extension Display {
    static let packageManagers: Set<String> = ["npm", "pnpm", "yarn", "yarnpkg", "bun", "npx", "pnpx", "bunx",
                                               "deno", "uv", "poetry", "pipenv", "hatch", "pdm", "rye", "bundle"]
    /// Package-manager flags that take a value we don't want to show (`--filter @shop/web`).
    static let valueFlags: Set<String> = ["--filter", "-F", "-C", "--dir", "--prefix", "--workspace", "-w", "--cwd"]
    static let subcommands: Set<String> = ["run", "exec", "x", "task", "run-script"]

    /// What a person would type, shortened: "dev" for `pnpm --filter web dev`,
    /// "tsx launch.mts" for `pnpm exec tsx /long/path/launch.mts`,
    /// "manage.py runserver 8001" for `python manage.py runserver 8001`.
    /// Build tools whose commands are short and meaningful as typed: `go run ./cmd/api`.
    static let literalCommands: Set<String> = ["go", "air", "cargo", "dotnet", "gow", "reflex", "hugo"]

    public static func scriptLabel(_ p: ProcessSnapshot) -> String {
        var args = Array(p.arguments.dropFirst())
        if literalCommands.contains(p.argv0Name) {
            return ([p.argv0Name] + args).joined(separator: " ")
        }
        // `ruby /path/bundle exec rails server`, `python /venv/bin/poetry run …`: the package
        // manager is the script, not argv[0].
        var manager = packageManagers.contains(p.argv0Name)
        if !manager, let script = Args.script(of: p.arguments),
           packageManagers.contains((script as NSString).lastPathComponent),
           let i = p.arguments.firstIndex(of: script) {
            args = Array(p.arguments[(i + 1)...])
            manager = true
        }
        var tokens: [String] = []
        if manager {
            var i = 0
            while i < args.count {
                let a = args[i]
                if valueFlags.contains(a) { i += 2; continue }
                if a.hasPrefix("-") { i += 1; continue }
                tokens.append(a)
                i += 1
            }
            if let first = tokens.first, subcommands.contains(first), tokens.count > 1 { tokens.removeFirst() }
        } else if let i = p.arguments.firstIndex(of: "-m") {
            tokens = Array(p.arguments[i...])
        } else if let script = Args.script(of: p.arguments), let i = p.arguments.firstIndex(of: script) {
            tokens = Array(p.arguments[i...])
        } else {
            tokens = args
        }
        // Paths shrink to their file name; framework CLIs inside node_modules shrink to the tool.
        let shown = tokens.map { token -> String in
            guard token.contains("/") else { return token }
            if let r = token.range(of: "/node_modules/") {
                let rest = token[r.upperBound...].split(separator: "/")
                if let pkg = rest.first(where: { $0 != ".bin" && !$0.hasPrefix(".") && !$0.hasPrefix("@") }) { return String(pkg) }
            }
            return (token as NSString).lastPathComponent
        }
        let label = shown.joined(separator: " ")
        return label.isEmpty ? p.argv0Name : label
    }
}

extension Server {
    /// Short subtitle: "apps/client · dev".
    public var subtitle: String {
        let script = Display.scriptLabel(root)
        let path = relativePackagePath
        return path.isEmpty ? script : "\(path) · \(script)"
    }

    /// Package directory relative to the project root, e.g. "apps/web"; empty at the root.
    public var relativePackagePath: String {
        guard package.path.hasPrefix(project.rootPath + "/") else { return "" }
        return String(package.path.dropFirst(project.rootPath.count + 1))
    }
}
