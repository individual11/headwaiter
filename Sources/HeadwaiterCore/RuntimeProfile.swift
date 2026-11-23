import Foundation

/// Everything one runtime family knows. Adding a runtime means adding one of these;
/// the resolver itself has no runtime-specific code.
public protocol RuntimeProfile: Sendable {
    /// Stable id, e.g. "node", "python".
    var id: String { get }

    /// Is this process an interpreter of this runtime (a candidate listener)?
    /// Returns the runtime name to show ("node", "bun", "deno", "python") or nil.
    func runtimeName(of process: ProcessSnapshot) -> String?

    /// Listeners that are helpers rather than servers (e.g. Jupyter kernels). Dropped.
    func auxiliaryReason(_ process: ProcessSnapshot) -> String?

    /// Classify an ancestor of a listener. nil means "not mine"; the resolver falls back to generic rules.
    func role(of process: ProcessSnapshot) -> ProcessRole?

    /// Find the package a server runs from, trying each start directory in order.
    func resolvePackage(startDirectories: [String], fs: FileReading) -> Package?

    /// Directories this runtime's process was clearly started for, besides its cwd
    /// (e.g. the folder of `node /path/server.js`).
    func scriptDirectories(of process: ProcessSnapshot) -> [String]

    /// Is `dir` the root of a workspace/monorepo in this ecosystem?
    func isWorkspaceRoot(_ dir: String, fs: FileReading) -> Bool

    /// Name declared by the manifest in `dir`, if any (used for the project group name).
    func manifestName(in dir: String, fs: FileReading) -> String?

    /// Ordered most specific first.
    var frameworks: [FrameworkRule] { get }

    /// Like `runtimeName(of:)`, with access to files and the parent process. Compiled runtimes
    /// (Go) need this: their servers are the project's own binaries, recognized by where they
    /// live or what launched them. Defaults to `runtimeName(of:)`.
    func runtimeName(of process: ProcessSnapshot, context: ProfileContext) -> String?
}

extension RuntimeProfile {
    public func runtimeName(of process: ProcessSnapshot, context: ProfileContext) -> String? {
        runtimeName(of: process)
    }
}

/// What a profile may look at beyond the process itself.
public struct ProfileContext {
    public var fs: FileReading
    public var parent: (ProcessSnapshot) -> ProcessSnapshot?

    public init(fs: FileReading, parent: @escaping (ProcessSnapshot) -> ProcessSnapshot?) {
        self.fs = fs
        self.parent = parent
    }
}

/// One framework, recognized from the command lines in a server's chain and/or its dependencies.
public struct FrameworkRule: Sendable {
    public var framework: Framework
    /// Matches the server's command lines (every process from root to listener) and package dependencies.
    public var matchesCommand: @Sendable (_ commandLines: [[String]], _ dependencies: Set<String>) -> Bool
    /// Fallback when no rule matched a command: any of these dependencies identifies the framework.
    public var dependencies: [String]

    public init(_ framework: Framework, dependencies: [String] = [],
                matchesCommand: @escaping @Sendable ([[String]], Set<String>) -> Bool) {
        self.framework = framework
        self.dependencies = dependencies
        self.matchesCommand = matchesCommand
    }
}

// MARK: - Shared helpers for profiles

public enum Args {
    /// True if any argument contains one of the fragments (path pieces like "/vite/bin/vite.js").
    public static func contains(_ lines: [[String]], fragments: [String]) -> Bool {
        lines.contains { line in line.contains { arg in fragments.contains { arg.contains($0) } } }
    }

    /// True if any argument's basename is one of the commands, or `-m <module>` names one.
    public static func invokes(_ lines: [[String]], commands: [String]) -> Bool {
        lines.contains { line in
            for (i, arg) in line.enumerated() {
                if commands.contains((arg as NSString).lastPathComponent) { return true }
                if arg == "-m", i + 1 < line.count, commands.contains(line[i + 1]) { return true }
            }
            return false
        }
    }

    /// The first argument after the interpreter that isn't a flag, i.e. the script or subcommand.
    /// Skips the values of flags known to take one (`--require x`, `-r x`, `--import x`).
    public static func script(of args: [String]) -> String? {
        var i = 1
        let takesValue: Set<String> = ["-r", "--require", "--import", "--loader", "--experimental-loader",
                                       "-W", "-X", "--env-file", "--conditions", "-C"]
        while i < args.count {
            let a = args[i]
            if a == "-m" || a == "-c" { return nil }
            if takesValue.contains(a) { i += 2; continue }
            if a.hasPrefix("-") { i += 1; continue }
            return a
        }
        return nil
    }
}

public enum Paths {
    /// Directories from `start` upward, stopping before the home directory and "/".
    /// Files sitting directly in ~ (a stray ~/package.json) never identify a project.
    public static func walkUp(from start: String, home: String) -> [String] {
        var dirs: [String] = []
        var dir = (start as NSString).standardizingPath
        let home = (home as NSString).standardizingPath
        while dir != "/" && dir != home && !dir.isEmpty {
            dirs.append(dir)
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return dirs
    }

    public static func join(_ dir: String, _ name: String) -> String { (dir as NSString).appendingPathComponent(name) }

    public static func absolute(_ path: String, relativeTo cwd: String?) -> String? {
        if path.hasPrefix("/") { return path }
        guard let cwd else { return nil }
        return (join(cwd, path) as NSString).standardizingPath
    }
}

public enum Shells {
    static let names: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "ksh", "tcsh", "csh"]

    /// Generic classification for shells: `sh -c "cmd"` is a command shell; anything else is interactive.
    public static func role(of process: ProcessSnapshot) -> ProcessRole? {
        let argv0 = process.argv0Name
        let name = argv0.hasPrefix("-") ? String(argv0.dropFirst()) : argv0
        guard names.contains(name) || names.contains(process.executableName) else { return nil }
        // A login shell ("-zsh") is interactive even if it was given -c.
        if argv0.hasPrefix("-") { return .other }
        let hasCommandFlag = process.arguments.dropFirst().contains { arg in
            arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.contains("c")
        }
        return hasCommandFlag ? .shellCommand : .other
    }
}
