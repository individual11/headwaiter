import Foundation

/// Where process data comes from: libproc on a live Mac, or a captured fixture in tests.
public protocol ProcessSource {
    func listeningSockets() -> [ListeningSocket]
    /// PID to parent PID for every visible process; used for walking chains and subtrees.
    func parentMap() -> [Int32: Int32]
    func snapshot(of pid: Int32) -> ProcessSnapshot?
}

/// File access used by project resolution, swappable for an in-memory fake in tests.
public protocol FileReading {
    func contents(of path: String) -> String?
    func exists(_ path: String) -> Bool
    /// False when macOS privacy protection (Desktop, Documents, Downloads...) denies this app
    /// access to the directory. Reads there silently fail, so callers must not mistake that for
    /// "no manifest here".
    func isAccessDenied(_ directory: String) -> Bool
    var homeDirectory: String { get }
}

public struct LocalFileSystem: FileReading {
    public init() {}

    public func contents(of path: String) -> String? {
        // Manifests are small; refuse anything large rather than read it every scan.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size < 2_000_000 else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    public func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    public func isAccessDenied(_ directory: String) -> Bool {
        // opendir() fails with EPERM (privacy protection) or EACCES (Unix permissions).
        guard let dir = opendir(directory) else { return errno == EPERM || errno == EACCES }
        closedir(dir)
        return false
    }

    public var homeDirectory: String { NSHomeDirectory() }
}

public struct InMemoryFileSystem: FileReading {
    public var files: [String: String]
    /// Paths that exist without content worth storing (`.git`, `manage.py`, directories).
    public var otherPaths: Set<String>
    /// Directories (and everything under them) this app may not read, like a denied ~/Desktop.
    public var deniedDirectories: Set<String>
    public var homeDirectory: String

    public init(files: [String: String], otherPaths: Set<String> = [], deniedDirectories: Set<String> = [],
                homeDirectory: String = "/Users/dev") {
        self.files = files
        self.otherPaths = otherPaths
        self.deniedDirectories = deniedDirectories
        self.homeDirectory = homeDirectory
    }

    public func isAccessDenied(_ directory: String) -> Bool {
        deniedDirectories.contains { directory == $0 || directory.hasPrefix($0 + "/") }
    }

    public func contents(of path: String) -> String? {
        isAccessDenied((path as NSString).deletingLastPathComponent) ? nil : files[path]
    }

    public func exists(_ path: String) -> Bool {
        if isAccessDenied((path as NSString).deletingLastPathComponent) { return false }
        if files[path] != nil || otherPaths.contains(path) { return true }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return files.keys.contains { $0.hasPrefix(prefix) }
    }
}

/// Wraps a file system and records every file that was found, so a fixture can include them.
public final class RecordingFileSystem: FileReading {
    let base: FileReading
    public private(set) var recorded: [String: String] = [:]
    /// Paths that exist but whose content wasn't read (e.g. `.git`, `manage.py`).
    public private(set) var existing: Set<String> = []

    public init(_ base: FileReading) { self.base = base }

    public func contents(of path: String) -> String? {
        let c = base.contents(of: path)
        if let c { recorded[path] = c }
        return c
    }

    public func exists(_ path: String) -> Bool {
        let e = base.exists(path)
        if e { existing.insert(path) }
        return e
    }

    public func isAccessDenied(_ directory: String) -> Bool { base.isAccessDenied(directory) }

    public var homeDirectory: String { base.homeDirectory }
}
