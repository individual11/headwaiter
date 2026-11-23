import Foundation

/// CPython in all its spellings. Projects are pyproject.toml, setup.py/cfg, Pipfile,
/// requirements.txt or a Django manage.py.
public struct PythonProfile: RuntimeProfile {
    public init() {}

    public let id = "python"

    /// python, python3, python3.12, python3.13t, and framework builds' "Python".
    static let interpreter = try! NSRegularExpression(pattern: "^python(\\d+(\\.\\d+)*t?)?$", options: [.caseInsensitive])

    static func isInterpreterName(_ name: String) -> Bool {
        interpreter.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    public func runtimeName(of process: ProcessSnapshot) -> String? {
        Self.isInterpreterName(process.executableName) || Self.isInterpreterName(process.argv0Name) ? "python" : nil
    }

    public func auxiliaryReason(_ process: ProcessSnapshot) -> String? {
        let lines = [process.arguments]
        if Args.contains(lines, fragments: ["ipykernel_launcher", "ipykernel"]) { return "Jupyter kernel" }
        if Args.contains(lines, fragments: ["debugpy", "pydevd"]) { return "Python debugger" }
        if Args.invokes(lines, commands: ["pytest", "py.test"]) || Args.contains(lines, fragments: ["/_pytest/", "xdist"]) {
            return "Test runner worker"
        }
        return nil
    }

    /// The command a process runs: the script's basename for `python /venv/bin/uvicorn`,
    /// the module for `python -m flask`, else the executable name (`uv`, `poetry`).
    static func command(of process: ProcessSnapshot) -> String {
        let args = process.arguments
        if let i = args.firstIndex(of: "-m"), i + 1 < args.count { return args[i + 1] }
        if isInterpreterName(process.executableName) || isInterpreterName(process.argv0Name),
           let script = Args.script(of: args) {
            return (script as NSString).lastPathComponent
        }
        return process.argv0Name.isEmpty ? process.executableName : process.argv0Name
    }

    static let runners: Set<String> = ["uv", "poetry", "pipenv", "hatch", "pdm", "rye", "pixi"]
    static let supervisors: Set<String> = ["uvicorn", "hypercorn", "gunicorn", "granian", "watchfiles", "hupper",
                                           "watchmedo", "fastapi", "flask"]
    static let orchestrators: Set<String> = ["honcho", "foreman", "supervisord", "overmind"]

    public func role(of process: ProcessSnapshot) -> ProcessRole? {
        let command = Self.command(of: process)
        if Self.orchestrators.contains(command) { return .orchestrator }
        if Self.runners.contains(command) || Self.runners.contains(process.executableName) {
            return process.arguments.contains("run") ? .wrapper : nil
        }
        // Reloader/supervisor parents that hand the socket to a worker.
        if Self.supervisors.contains(command) { return .wrapper }
        return nil
    }

    public func scriptDirectories(of process: ProcessSnapshot) -> [String] {
        guard runtimeName(of: process) != nil, let script = Args.script(of: process.arguments),
              script.hasSuffix(".py"), !script.contains("/site-packages/"),
              let abs = Paths.absolute(script, relativeTo: process.cwd) else { return [] }
        return [(abs as NSString).deletingLastPathComponent]
    }

    static let manifests = ["pyproject.toml", "setup.py", "setup.cfg", "Pipfile", "requirements.txt", "manage.py"]

    public func resolvePackage(startDirectories: [String], fs: FileReading) -> Package? {
        for start in startDirectories {
            for dir in Paths.walkUp(from: start, home: fs.homeDirectory)
            where !dir.contains("/site-packages/") && !dir.contains("/.venv/") {
                if let manifest = Self.manifests.first(where: { fs.exists(Paths.join(dir, $0)) }) {
                    return Package(path: dir, name: manifestName(in: dir, fs: fs) ?? (dir as NSString).lastPathComponent,
                                   dependencies: dependencies(in: dir, fs: fs), manifest: manifest)
                }
            }
        }
        return nil
    }

    public func isWorkspaceRoot(_ dir: String, fs: FileReading) -> Bool {
        fs.contents(of: Paths.join(dir, "pyproject.toml"))?.contains("[tool.uv.workspace]") ?? false
    }

    public func manifestName(in dir: String, fs: FileReading) -> String? {
        if let toml = fs.contents(of: Paths.join(dir, "pyproject.toml")) {
            if let n = Self.tomlName(toml, sections: ["[project]", "[tool.poetry]"]) { return n }
        }
        if let cfg = fs.contents(of: Paths.join(dir, "setup.cfg")) {
            if let n = Self.tomlName(cfg, sections: ["[metadata]"]) { return n }
        }
        return nil
    }

    /// Finds `name = "x"` (or `name = x` in setup.cfg) inside the first matching section.
    static func tomlName(_ text: String, sections: [String]) -> String? {
        var inSection = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = sections.contains(line); continue }
            guard inSection, line.hasPrefix("name") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "name" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Names from the framework table that appear in any manifest. No full TOML or
    /// requirements parsing: framework detection only needs to know whether they're there.
    func dependencies(in dir: String, fs: FileReading) -> Set<String> {
        let text = ["pyproject.toml", "requirements.txt", "requirements-dev.txt", "Pipfile", "setup.py", "setup.cfg"]
            .compactMap { fs.contents(of: Paths.join(dir, $0)) }
            .joined(separator: "\n").lowercased()
        var deps = Set<String>()
        for name in ["django", "fastapi", "flask", "uvicorn", "starlette", "jupyterlab", "notebook"] {
            let pattern = "(?<![a-z0-9_-])\(name)(?![a-z0-9_-])"
            if text.range(of: pattern, options: .regularExpression) != nil { deps.insert(name) }
        }
        return deps
    }

    public let frameworks: [FrameworkRule] = [
        FrameworkRule(Framework(id: "jupyter", name: "Jupyter", defaultPorts: [8888])) { l, _ in
            Args.contains(l, fragments: ["jupyter-lab", "jupyter-notebook", "jupyter-server", "jupyter_server", "jupyterlab"])
                || Args.invokes(l, commands: ["jupyter", "jupyter-lab", "jupyter-notebook"])
        },
        FrameworkRule(Framework(id: "django", name: "Django", defaultPorts: [8000]), dependencies: ["django"]) { l, _ in
            l.contains { $0.contains("runserver") } && Args.invokes(l, commands: ["manage.py", "django-admin"])
        },
        FrameworkRule(Framework(id: "fastapi", name: "FastAPI", defaultPorts: [8000]), dependencies: ["fastapi"]) { l, deps in
            Args.invokes(l, commands: ["fastapi"]) || (Args.invokes(l, commands: ["uvicorn"]) && deps.contains("fastapi"))
        },
        FrameworkRule(Framework(id: "uvicorn", name: "Uvicorn", defaultPorts: [8000])) { l, _ in
            Args.invokes(l, commands: ["uvicorn"])
        },
        FrameworkRule(Framework(id: "flask", name: "Flask", defaultPorts: [5000]), dependencies: ["flask"]) { l, _ in
            Args.invokes(l, commands: ["flask"])
        },
    ]
}
