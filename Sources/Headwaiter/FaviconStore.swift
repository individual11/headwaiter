import AppKit
import HeadwaiterCore
import Observation

/// Project icons for rows, looked up once per package (or container) and cached for the session.
///
/// Order: the project's own files first (no network, no server log lines), then, if allowed in
/// Settings, one request for `/favicon.ico` on the running server. Starter icons are skipped
/// (`Favicon.isUsable`), so those rows keep the framework mark.
@MainActor
@Observable
final class FaviconStore {
    private(set) var images: [String: NSImage] = [:]

    /// Lookups that found nothing. `final` once settled; otherwise retried (a server that wasn't
    /// accepting connections yet), a few times at most.
    private struct Miss { var final: Bool; var tries: Int; var last: Date }
    @ObservationIgnored private var misses: [String: Miss] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// Bumped by `reset()` so lookups started before it can't write stale results.
    @ObservationIgnored private var generation = 0

    static let retryInterval: TimeInterval = 20
    static let maxTries = 3

    func image(for server: Server) -> NSImage? { images[server.package.path] }
    func image(forPackage path: String) -> NSImage? { images[path] }
    func image(for container: ContainerServer) -> NSImage? { images[Self.key(container)] }

    private static func key(_ container: ContainerServer) -> String { "container:\(container.id)" }

    /// Starts lookups for anything not seen yet. Cheap to call on every scan.
    func update(servers: [Server], containers: [ContainerServer], gated: Bool) {
        guard Preferences.showFavicons else { return }
        for server in servers {
            let folders = server.package.accessDenied ? [] :
                Favicon.searchFolders(packagePath: server.package.path, projectRoot: server.project.rootPath)
            request(key: server.package.path, folders: folders, url: server.url, gated: gated)
        }
        for container in containers where container.isHTTP {
            request(key: Self.key(container), folders: [], url: container.url, gated: gated)
        }
    }

    /// Forget everything, e.g. after a Settings change or once protected folders may be read.
    func reset() {
        generation += 1
        images = [:]
        misses = [:]
        inFlight = []
    }

    /// Snapshot rendering: show given icons without looking anything up.
    func preview(_ icons: [String: NSImage]) { images = icons }

    private func request(key: String, folders: [String], url: URL, gated: Bool) {
        guard images[key] == nil, !inFlight.contains(key) else { return }
        if let miss = misses[key], miss.final || miss.tries >= Self.maxTries
            || Date().timeIntervalSince(miss.last) < Self.retryInterval { return }
        inFlight.insert(key)
        let fetch = Preferences.fetchFavicons
        let started = generation
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await Self.lookup(folders: folders, url: url, gated: gated, fetch: fetch)
            }.value
            guard let self, self.generation == started else { return }
            self.inFlight.remove(key)
            if ServerStore.debug {
                FileHandle.standardError.write(Data("favicon: \(key) → \(result.summary)\n".utf8))
            }
            switch result {
            case .found(let data):
                self.images[key] = Self.decode(data)
                self.misses[key] = nil
            case .missing(let final):
                let tries = (self.misses[key]?.tries ?? 0) + 1
                self.misses[key] = Miss(final: final, tries: tries, last: Date())
            }
        }
    }

    private enum Result: Sendable {
        /// Image bytes, already checked to decode (NSImage itself isn't Sendable).
        case found(Data)
        /// `final`: the files were checked and the server answered (or wasn't asked).
        case missing(final: Bool)

        var summary: String {
            switch self {
            case .found(let data): "found (\(data.count) bytes)"
            case .missing(let final): final ? "none" : "none yet (will retry)"
            }
        }
    }

    private nonisolated static func lookup(folders: [String], url: URL, gated: Bool, fetch: Bool) async -> Result {
        let fs: FileReading = gated ? ProtectedFolderGate(LocalFileSystem()) : LocalFileSystem()
        if let found = Favicon.find(in: folders, fs: fs), decode(found.data) != nil {
            return .found(found.data)
        }
        guard fetch, let iconURL = Favicon.serverURL(for: url) else { return .missing(final: true) }
        switch await fetcher.fetch(iconURL) {
        case .found(let data): return decode(data) != nil ? .found(data) : .missing(final: true)
        case .none: return .missing(final: true)
        case .unreachable: return .missing(final: false)   // not accepting connections yet; try again later
        }
    }

    private nonisolated static let fetcher = FaviconFetcher()

    /// NSImage reads ICO, PNG and SVG. A decoded image with no size isn't worth showing.
    private nonisolated static func decode(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.isValid, image.size.width > 0 else { return nil }
        return image
    }
}
