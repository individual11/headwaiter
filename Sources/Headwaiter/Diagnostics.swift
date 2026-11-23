import AppKit
import HeadwaiterCore

/// "Capture Diagnostics" for dogfooding: freezes the current machine state as a test fixture
/// (every Node/Python listener with its process chain and the project files read), plus a
/// readable summary of what the app concluded and why it skipped anything.
///
/// Files stay on this Mac, in ~/Library/Application Support/Headwaiter/Captures. Home paths
/// are rewritten to /Users/dev; command lines can still contain secrets, so check before sharing.
enum Diagnostics {
    static var directory: URL {
        StateFile.url.deletingLastPathComponent().appendingPathComponent("Captures", isDirectory: true)
    }

    /// Writes capture-<time>.json (fixture) and capture-<time>.txt (summary); returns the JSON URL.
    static func capture() throws -> URL {
        let source = LiveProcessSource()
        let stamp = Self.stamp()
        let fixture = Fixture.capture(name: "capture \(stamp)", notes: "Captured from the menu bar app", source: source)
        let result = Resolver().resolve(source)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appendingPathComponent("capture-\(stamp).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(fixture).write(to: json)
        try summary(result).write(to: directory.appendingPathComponent("capture-\(stamp).txt"),
                                  atomically: true, encoding: .utf8)
        return json
    }

    static func summary(_ result: ResolveResult) -> String {
        let home = NSHomeDirectory()
        func scrub(_ s: String) -> String { s.replacingOccurrences(of: home, with: "~") }
        var lines = ["Headwaiter diagnostics, \(Date().formatted(date: .abbreviated, time: .standard))", ""]
        lines.append("\(result.servers.count) servers")
        for s in result.servers {
            lines.append("- \(s.project.displayName) / \(s.package.name)  \(s.framework?.name ?? s.runtime)  :\(s.primaryPort)"
                         + (s.secondaryPorts.isEmpty ? "" : " +\(s.secondaryPorts.map(String.init).joined(separator: ","))"))
            lines.append("    project \(scrub(s.project.rootPath)), package \(scrub(s.package.path)) (\(s.package.manifest.isEmpty ? "no access" : s.package.manifest))")
            lines.append("    stop root \(s.rootPID): \(scrub(Display.command(s.root)))")
            lines.append("    chain: " + s.chain.map { "\($0.pid) \($0.argv0Name)" }.joined(separator: " → "))
        }
        lines.append("")
        // Node/Python listeners that were skipped are the interesting ones; fold the rest.
        let otherRuntime = result.dropped.filter { $0.reason.hasPrefix("not a supported runtime") }
        let relevant = result.dropped.filter { !$0.reason.hasPrefix("not a supported runtime") }
        lines.append("\(relevant.count) skipped Node/Python listeners")
        for d in relevant.sorted(by: { $0.pid < $1.pid }) {
            lines.append("- pid \(d.pid) :\(d.ports.map(String.init).joined(separator: ","))  \(d.reason)")
            lines.append("    \(scrub(d.command).prefix(160))")
        }
        let names = Dictionary(grouping: otherRuntime) { d in
            d.reason.replacingOccurrences(of: "not a supported runtime (", with: "").dropLast()
        }
        .map { "\($0.key)\($0.value.count > 1 ? " ×\($0.value.count)" : "")" }
        .sorted()
        lines.append("")
        lines.append("\(otherRuntime.count) other listeners: \(names.joined(separator: ", "))")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
