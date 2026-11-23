import Foundation

/// Asks a running server for its `/favicon.ico`, trusting the server as little as possible:
/// no redirects (so it can't point the app at another site or service), no cookies or cache,
/// at most `Favicon.maxBytes` read, and a limit on the whole request, not only on idle time.
public struct FaviconFetcher: Sendable {
    public enum Outcome: Sendable, Equatable {
        case found(Data)
        /// The server answered, but not with a usable icon (including any redirect).
        case none
        /// No complete answer: not accepting connections yet, or too slow.
        case unreachable
    }

    private let session: URLSession

    public init(idleTimeout: TimeInterval = 2, totalTimeout: TimeInterval = 5, protocolClasses: [AnyClass]? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = totalTimeout
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config)
    }

    public func fetch(_ url: URL) async -> Outcome {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: RefuseRedirects())
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.expectedContentLength <= Int64(Favicon.maxBytes) else { return .none }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > Favicon.maxBytes { return .none }
            }
            return Favicon.isUsable(data) ? .found(data) : .none
        } catch {
            return .unreachable
        }
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
