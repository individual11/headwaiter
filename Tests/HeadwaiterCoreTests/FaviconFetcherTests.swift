import Foundation
import Testing
@testable import HeadwaiterCore

/// Answers requests in-process, so no server or network is involved.
/// Each test uses its own host; the host picks the behavior.
private final class StubServer: URLProtocol, @unchecked Sendable {
    static let icon = Data("<svg xmlns='http://www.w3.org/2000/svg'><circle r='9'/></svg>".utf8)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    nonisolated(unsafe) private static var sentBytes: [String: Int] = [:]
    private let stopLock = NSLock()
    private var stopped = false

    static func requests(containing text: String) -> [String] { lock.withLock { log.filter { $0.contains(text) } } }
    static func bytesSent(_ host: String) -> Int { lock.withLock { sentBytes[host] ?? 0 } }

    private var isStopped: Bool { stopLock.withLock { stopped } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { stopLock.withLock { stopped = true } }

    override func startLoading() {
        let url = request.url!, host = url.host!
        Self.lock.withLock { Self.log.append(url.absoluteString) }
        func respond(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        switch host {
        case "redirect.test", "same-host.test":
            let target = URL(string: host == "redirect.test" ? "http://outside.test/icon" : "http://same-host.test/other.svg")!
            if url == target || url.path != "/favicon.ico" { return send(respond(200), [Self.icon]) }
            let response = respond(302, ["Location": target.absoluteString])
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // Unless the redirect is followed, the 302 itself is the answer.
            send(response, [])
        case "endless.test":
            stream(respond(200), chunk: Data(count: 100_000), every: 0.002, limit: 400)
        case "drip.test":
            stream(respond(200), chunk: Data([0x20]), every: 0.05, limit: 200)
        case "declared.test":
            stream(respond(200, ["Content-Length": "50000000"]), chunk: Data(count: 100_000), every: 0.002, limit: 400)
        case "missing.test":
            send(respond(404), [Self.icon])
        case "down.test":
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        default:
            send(respond(200), [Self.icon])
        }
    }

    private func send(_ response: HTTPURLResponse, _ chunks: [Data]) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func stream(_ response: HTTPURLResponse, chunk: Data, every: TimeInterval, limit: Int) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let host = response.url!.host!
        Thread.detachNewThread { [self] in
            for _ in 0..<limit {
                if isStopped { return }
                client?.urlProtocol(self, didLoad: chunk)
                Self.lock.withLock { Self.sentBytes[host, default: 0] += chunk.count }
                Thread.sleep(forTimeInterval: every)
            }
            if !isStopped { client?.urlProtocolDidFinishLoading(self) }
        }
    }
}

@Suite("Favicon requests")
struct FaviconFetcherTests {
    func fetch(_ host: String, total: TimeInterval = 5) async -> FaviconFetcher.Outcome {
        await FaviconFetcher(totalTimeout: total, protocolClasses: [StubServer.self])
            .fetch(URL(string: "http://\(host)/favicon.ico")!)
    }

    @Test func returnsAnIcon() async {
        #expect(await fetch("ok.test") == .found(StubServer.icon))
    }

    @Test func neverFollowsARedirectToAnotherHost() async {
        #expect(await fetch("redirect.test") == .none)
        #expect(StubServer.requests(containing: "outside.test").isEmpty)
    }

    @Test func neverFollowsARedirectOnTheSameHost() async {
        #expect(await fetch("same-host.test") == .none)
        #expect(StubServer.requests(containing: "other.svg").isEmpty)
    }

    @Test func stopsReadingPastTheSizeLimit() async {
        #expect(await fetch("endless.test") == .none)
        #expect(StubServer.bytesSent("endless.test") < 20_000_000)   // of 40 MB on offer
    }

    @Test func rejectsADeclaredOversizeWithoutReadingIt() async {
        #expect(await fetch("declared.test") == .none)
        #expect(StubServer.bytesSent("declared.test") < 20_000_000)
    }

    @Test func givesUpOnASlowDrip() async {
        let start = ContinuousClock.now
        #expect(await fetch("drip.test", total: 0.5) == .unreachable)   // each byte resets the idle timeout
        #expect(ContinuousClock.now - start < .seconds(4))
    }

    @Test func notFoundIsFinalAndDownIsNot() async {
        #expect(await fetch("missing.test") == .none)
        #expect(await fetch("down.test") == .unreachable)
    }
}
