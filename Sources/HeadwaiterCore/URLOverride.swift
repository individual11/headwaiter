import Foundation

/// A user-chosen URL for a package's server ("Set URL…"). A nil port means "whatever port the
/// server is on", so the override survives the server moving to another port.
public struct URLOverride: Codable, Equatable, Sendable {
    public var scheme: String
    public var host: String
    public var path: String
    public var port: UInt16?

    public func url(defaultPort: UInt16) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.port = Int(port ?? defaultPort)
        c.path = path
        return c.url
    }

    /// Parses what the user typed. A port equal to the server's current port is stored as
    /// "follow the server".
    public init?(text: String, serverPort: UInt16) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let c = URLComponents(string: withScheme), let scheme = c.scheme, let host = c.host, !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.path = c.path
        let typed = c.port.map(UInt16.init)
        self.port = (typed == nil || typed == serverPort) ? nil : typed
    }
}
