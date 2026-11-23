import Foundation

/// Ruby: Rails (Puma), Sinatra, Hanami, Jekyll, plain Rack. Projects are Gemfile, config.ru or a
/// gemspec. Puma retitles its process ("puma 6.4.2 (tcp://localhost:3000) [shop]"); the
/// executable is still ruby. `bin/dev` runs foreman, which is an orchestrator (it also runs the
/// CSS/JS watchers), so Stop never climbs into it.
public struct RubyProfile: RuntimeProfile {
    public init() {}

    public let id = "ruby"

    /// ruby, ruby3.3, and the system ruby.
    static let interpreter = try! NSRegularExpression(pattern: "^ruby(\\d+(\\.\\d+)*)?$")

    static func isInterpreterName(_ name: String) -> Bool {
        interpreter.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    public func runtimeName(of process: ProcessSnapshot) -> String? {
        Self.isInterpreterName(process.executableName) ? "ruby" : nil
    }

    /// The command a ruby process runs: the script's basename (`bundle`, `rails`, `foreman`),
    /// or the executable name for non-ruby binaries (overmind, hivemind).
    static func command(of process: ProcessSnapshot) -> String {
        guard isInterpreterName(process.executableName) else { return process.executableName }
        if let script = Args.script(of: process.arguments) { return (script as NSString).lastPathComponent }
        return process.argv0Name
    }

    public func auxiliaryReason(_ process: ProcessSnapshot) -> String? {
        let lines = [process.arguments]
        if Args.contains(lines, fragments: ["spring server", "spring app"]) || process.argv0Name.hasPrefix("spring") {
            return "Rails Spring preloader"
        }
        if Args.invokes(lines, commands: ["solargraph", "ruby-lsp", "steep"]) { return "Ruby language server" }
        if Args.invokes(lines, commands: ["rdbg"]) { return "Ruby debugger" }
        if Args.invokes(lines, commands: ["rspec", "minitest"]) { return "Test runner worker" }
        return nil
    }

    static let orchestrators: Set<String> = ["foreman", "overmind", "hivemind"]
    static let reloaders: Set<String> = ["rerun", "guard", "rackup-reload"]

    public func role(of process: ProcessSnapshot) -> ProcessRole? {
        let command = Self.command(of: process)
        if Self.orchestrators.contains(command) || Self.orchestrators.contains(process.argv0Name) { return .orchestrator }
        if command == "bundle", process.arguments.contains("exec") { return .wrapper }
        if Self.reloaders.contains(command) { return .wrapper }
        return nil
    }

    public func scriptDirectories(of process: ProcessSnapshot) -> [String] {
        guard runtimeName(of: process) != nil, let script = Args.script(of: process.arguments),
              script.hasSuffix(".rb") || script.hasSuffix(".ru"), !script.contains("/gems/"),
              let abs = Paths.absolute(script, relativeTo: process.cwd) else { return [] }
        return [(abs as NSString).deletingLastPathComponent]
    }

    static let manifests = ["Gemfile", "config.ru", "Rakefile"]

    public func resolvePackage(startDirectories: [String], fs: FileReading) -> Package? {
        for start in startDirectories {
            for dir in Paths.walkUp(from: start, home: fs.homeDirectory) where !dir.contains("/gems/") {
                if let manifest = Self.manifests.first(where: { fs.exists(Paths.join(dir, $0)) }) {
                    return Package(path: dir, name: (dir as NSString).lastPathComponent,
                                   dependencies: dependencies(in: dir, fs: fs), manifest: manifest)
                }
            }
        }
        return nil
    }

    public func isWorkspaceRoot(_ dir: String, fs: FileReading) -> Bool { false }
    public func manifestName(in dir: String, fs: FileReading) -> String? { nil }

    /// Gem names from Gemfile and Gemfile.lock that the framework table cares about.
    func dependencies(in dir: String, fs: FileReading) -> Set<String> {
        let text = ["Gemfile", "Gemfile.lock"].compactMap { fs.contents(of: Paths.join(dir, $0)) }.joined(separator: "\n")
        var deps = Set<String>()
        for gem in ["rails", "railties", "sinatra", "hanami", "jekyll", "roda", "puma", "rack"] {
            let pattern = "(gem ['\"]\(gem)['\"]|^\\s+\(gem) \\()"
            if text.range(of: pattern, options: [.regularExpression]) != nil { deps.insert(gem) }
        }
        return deps
    }

    public let frameworks: [FrameworkRule] = [
        FrameworkRule(Framework(id: "jekyll", name: "Jekyll", defaultPorts: [4000]), dependencies: ["jekyll"]) { l, _ in
            Args.invokes(l, commands: ["jekyll"])
        },
        FrameworkRule(Framework(id: "rails", name: "Rails", defaultPorts: [3000]), dependencies: ["rails", "railties"]) { l, deps in
            let railsCommand = Args.invokes(l, commands: ["rails"])
                && l.contains { $0.contains("server") || $0.contains("s") }
            let pumaInRails = Args.invokes(l, commands: ["puma"]) && (deps.contains("rails") || deps.contains("railties"))
            return railsCommand || pumaInRails
        },
        FrameworkRule(Framework(id: "hanami", name: "Hanami", defaultPorts: [2300]), dependencies: ["hanami"]) { l, _ in
            Args.invokes(l, commands: ["hanami"])
        },
        FrameworkRule(Framework(id: "sinatra", name: "Sinatra", defaultPorts: [4567]), dependencies: ["sinatra"]) { _, _ in false },
        FrameworkRule(Framework(id: "puma", name: "Puma", defaultPorts: [9292, 3000])) { l, _ in
            Args.invokes(l, commands: ["puma"])
        },
        FrameworkRule(Framework(id: "rack", name: "Rack", defaultPorts: [9292])) { l, _ in
            Args.invokes(l, commands: ["rackup"])
        },
    ]
}
