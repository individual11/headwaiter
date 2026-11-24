import Foundation
import Testing
@testable import HeadwaiterCore

@Suite("Server log")
struct ServerLogTests {
    func item(_ name: String, id: String? = nil, started: Double = 0, hidden: Bool = false) -> LogItem {
        LogItem(id: id ?? name, key: "/p/\(name):3000", name: name, project: "shop", kind: "Next.js", port: 3000,
                process: ProcessIdentity(pid: 812, startTime: started), path: "/Users/me/shop/\(name)",
                startTime: started, isHidden: hidden)
    }

    /// A tracker that has seen `items` on its first scan, at time 10.
    func tracker(_ items: [LogItem] = []) -> LogTracker {
        var t = LogTracker()
        #expect(t.update(items, now: 10, isAlive: { _ in false }).isEmpty)
        return t
    }

    @Test func startsAndStopsAreReportedRightAway() {
        var t = tracker()
        let web = item("web", started: 12)
        #expect(t.update([web], now: 15, isAlive: { _ in false }) == [LogEvent(.started, web, time: 15)])
        #expect(t.update([web], now: 20, isAlive: { _ in false }).isEmpty)
        #expect(t.update([], now: 25, isAlive: { _ in false }) == [LogEvent(.stopped(nil), web, time: 25)])
        #expect(t.update([], now: 60, isAlive: { _ in false }).isEmpty)
    }

    @Test func restartIsAStopThenAStart() {
        var t = tracker([item("web", id: "a")])
        let back = item("web", id: "b", started: 13)
        let events = t.update([back], now: 15, isAlive: { _ in false })
        #expect(events.map(\.change) == [.stopped(nil), .started])
        #expect(events.map(\.item.id) == ["a", "b"])
    }

    @Test func briefGapInAListeningProcessIsSilent() {
        let web = item("web")
        var t = tracker([web])
        #expect(t.update([], now: 15, isAlive: { _ in true }).isEmpty)
        #expect(t.update([web], now: 20, isAlive: { _ in true }).isEmpty)
        #expect(t.update([], now: 25, isAlive: { _ in false }).count == 1)
    }

    @Test func longGapIsAStopThenAStart() {
        let web = item("web")
        var t = tracker([web])
        #expect(t.update([], now: 15, isAlive: { _ in true }).isEmpty)
        #expect(t.update([], now: 25, isAlive: { _ in true }).map(\.change) == [.stopped(nil)])
        #expect(t.update([web], now: 30, isAlive: { _ in true }).map(\.change) == [.started])
    }

    @Test func gapEndsWhenTheProcessExits() {
        var t = tracker([item("web")])
        #expect(t.update([], now: 15, isAlive: { _ in true }).isEmpty)
        #expect(t.update([], now: 17, isAlive: { _ in false }).map(\.change) == [.stopped(nil)])
    }

    @Test func losingTheWrapperIsSilent() {
        var t = tracker([item("web", id: "npm", started: 1)])
        let node = item("web", id: "node", started: 2)
        #expect(t.update([node], now: 15, isAlive: { _ in false }).isEmpty)
        #expect(t.update([], now: 20, isAlive: { _ in false }).map(\.item.id) == ["node"])
    }

    @Test func stopsFromTheAppSaySo() {
        var t = tracker([item("web"), item("api")])
        t.willStop(id: "web", .headwaiter)
        t.willStop(id: "api", .headwaiter)
        t.willStop(id: "api", .forceQuit)
        let events = t.update([], now: 15, isAlive: { _ in false })
        #expect(events.map(\.change) == [.stopped(.forceQuit), .stopped(.headwaiter)])
    }

    @Test func failedStopIsForgotten() {
        var t = tracker([item("web")])
        t.willStop(id: "web", .headwaiter)
        t.stopFailed(id: "web")
        #expect(t.update([], now: 15, isAlive: { _ in false }).map(\.change) == [.stopped(nil)])
    }

    @Test func hiddenItemsAreNeverLogged() {
        var t = tracker([item("web")])
        // Hiding a running server isn't a stop, and showing it again isn't a start.
        #expect(t.update([item("web", hidden: true)], now: 15, isAlive: { _ in false }).isEmpty)
        #expect(t.update([item("web")], now: 20, isAlive: { _ in false }).isEmpty)
        #expect(t.update([item("web"), item("api", started: 21, hidden: true)], now: 25, isAlive: { _ in false }).isEmpty)
        #expect(t.update([item("web")], now: 30, isAlive: { _ in false }).isEmpty)
    }

    // MARK: Lines

    let utc = TimeZone(identifier: "UTC")!

    @Test func startLine() {
        let event = LogEvent(.started, item("web"), time: 0)
        #expect(event.line(timeZone: utc, home: "/Users/me")
            == "1970-01-01 00:00:00  Started  web (shop)  Next.js  localhost:3000  PID 812  ~/shop/web")
    }

    @Test func stopLines() {
        #expect(LogEvent(.stopped(nil), item("web"), time: 8040).line(timeZone: utc)
            == "1970-01-01 02:14:00  Stopped  web (shop)  Next.js  localhost:3000  PID 812  ran 2h 14m")
        #expect(LogEvent(.stopped(.headwaiter), item("web"), time: 5).line(timeZone: utc)
            .hasSuffix("ran 5s  stopped from Headwaiter"))
        #expect(LogEvent(.stopped(.forceQuit), item("web"), time: 5).line(timeZone: utc)
            .hasSuffix("ran 5s  force quit from Headwaiter"))
    }

    @Test func containerLine() {
        let db = LogItem(id: "c1", key: "container:db:5432", name: "db", project: "Docker", kind: "postgres:16",
                         port: 5432, startTime: 0)
        #expect(LogEvent(.started, db, time: 0).line(timeZone: utc)
            == "1970-01-01 00:00:00  Started  db (Docker)  postgres:16  localhost:5432")
    }

    @Test func projectIsLeftOutWhenItRepeatsTheName() {
        #expect(LogEvent(.started, item("shop"), time: 0).line(timeZone: utc).contains("Started  shop  Next.js"))
    }

    @Test func namesCannotAddLines() {
        var web = item("web")
        web.name = "a\nb\u{2028}c\td"
        #expect(LogEvent(.started, web, time: 0).line(timeZone: utc).contains("Started  a b c d (shop)"))
    }

    // MARK: File

    func temporaryFile(maxBytes: Int = 1_000_000) -> LogFile {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hw-log-\(UUID().uuidString)")
        return LogFile(url: dir.appendingPathComponent("servers.log"), maxBytes: maxBytes)
    }

    @Test func appendReadAndClear() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        #expect(file.lines().isEmpty)
        try file.append([])
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
        #expect(try file.append(["one", "two"]) == false)
        try file.append(["three"])
        #expect(file.lines() == ["one", "two", "three"])
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        try file.clear()
        try file.clear()   // nothing left to clear is fine
        #expect(file.lines().isEmpty)
        try file.append(["four"])
        #expect(file.lines() == ["four"])
    }

    @Test func dropsTheOldestLinesWhenFull() throws {
        let file = temporaryFile(maxBytes: 1000)
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        for i in 100..<400 { try file.append(["line \(i)"]) }
        let lines = file.lines()
        #expect(lines.last == "line 399")
        #expect(lines.count < 112)
        #expect(lines.allSatisfy { $0.hasPrefix("line ") && $0.count == 8 })
        #expect(zip(lines, lines.dropFirst()).allSatisfy { $0 < $1 })
    }
}
