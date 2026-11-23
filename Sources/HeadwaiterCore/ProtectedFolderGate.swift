import Foundation

/// Wraps a file system and treats macOS-protected folders (Desktop, Documents, Downloads,
/// iCloud Drive) as unreadable without touching them. Touching them, even to check access, is
/// what triggers the privacy prompt; the app uses this until the first-run card has explained
/// why the prompt will appear.
public struct ProtectedFolderGate: FileReading {
    let base: FileReading
    let protected: [String]

    public init(_ base: FileReading) {
        self.base = base
        let home = base.homeDirectory
        protected = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { "\(home)/\($0)" }
    }

    func isProtected(_ path: String) -> Bool {
        protected.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    public func contents(of path: String) -> String? { isProtected(path) ? nil : base.contents(of: path) }
    public func exists(_ path: String) -> Bool { isProtected(path) ? false : base.exists(path) }
    public func isAccessDenied(_ directory: String) -> Bool { isProtected(directory) || base.isAccessDenied(directory) }
    public var homeDirectory: String { base.homeDirectory }
}
