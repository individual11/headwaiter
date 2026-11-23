import Foundation
import Testing
@testable import HeadwaiterCore

@Suite("Start and stop notifications")
struct ChangeTrackerTests {
    func item(_ name: String, id: String? = nil, started: Double = 0, hidden: Bool = false) -> RunningItem {
        RunningItem(id: id ?? name, key: "/p/\(name):3000", name: name, project: "shop", port: 3000,
                    url: URL(string: "http://localhost:3000"), startTime: started, isHidden: hidden)
    }

    /// A tracker that has seen `items` on its first scan, at time 0.
    func tracker(_ items: [RunningItem] = []) -> ChangeTracker {
        var t = ChangeTracker()
        #expect(t.update(items, now: 0).isEmpty)
        return t
    }

    @Test func alreadyRunningIsNotNews() {
        var t = tracker([item("web")])
        #expect(t.update([item("web")], now: 60).isEmpty)
    }

    @Test func startIsReportedOnceItSettles() {
        var t = tracker()
        let web = item("web", started: 100)
        #expect(t.update([web], now: 105).isEmpty)
        #expect(t.update([web], now: 110).started == [web])
        #expect(t.update([web], now: 115).isEmpty)
    }

    @Test func shortRunIsNeverReported() {
        var t = tracker()
        #expect(t.update([item("web", started: 100)], now: 105).isEmpty)
        #expect(t.update([], now: 108).isEmpty)
        #expect(t.update([], now: 200).isEmpty)
    }

    @Test func stopIsReportedOnceAfterTheGracePeriod() {
        let web = item("web")
        var t = tracker([web])
        #expect(t.update([], now: 100).isEmpty)
        #expect(t.update([], now: 105).isEmpty)
        #expect(t.update([], now: 110).stopped == [web])
        #expect(t.update([], now: 200).isEmpty)
    }

    @Test func quickRestartIsSilent() {
        var t = tracker([item("web", id: "1@0")])
        #expect(t.update([], now: 100).isEmpty)
        let back = item("web", id: "2@104", started: 104)
        #expect(t.update([back], now: 106).isEmpty)
        #expect(t.update([back], now: 200).isEmpty)
        // The restarted server's own stop is still reported.
        #expect(t.update([], now: 300).isEmpty)
        #expect(t.update([], now: 310).stopped == [back])
    }

    @Test func restartBetweenScansIsSilent() {
        var t = tracker([item("web", id: "1@0")])
        #expect(t.update([item("web", id: "2@100", started: 100)], now: 101).isEmpty)
        #expect(t.update([item("web", id: "2@100", started: 100)], now: 200).isEmpty)
    }

    @Test func slowRestartIsAStopThenAStart() {
        var t = tracker([item("web", id: "1@0")])
        _ = t.update([], now: 100)
        #expect(t.update([], now: 110).stopped.count == 1)
        let back = item("web", id: "2@120", started: 120)
        #expect(t.update([back], now: 130).started == [back])
    }

    @Test func stoppingFromTheAppIsSilent() {
        var t = tracker([item("web"), item("api")])
        t.willStop(id: "web")
        #expect(t.update([item("api")], now: 100).isEmpty)
        #expect(t.update([item("api")], now: 200).isEmpty)
    }

    @Test func slowStopFromTheAppIsSilent() {
        var t = tracker([item("web")])
        t.willStop(id: "web")
        #expect(t.update([item("web")], now: 5).isEmpty)
        #expect(t.update([item("web")], now: 60).isEmpty)
        _ = t.update([], now: 65)
        #expect(t.update([], now: 200).isEmpty)
    }

    @Test func failedStopMakesALaterExitNews() {
        var t = tracker([item("web")])
        t.willStop(id: "web")
        t.stopFailed(id: "web")
        _ = t.update([], now: 100)
        #expect(t.update([], now: 110).stopped.count == 1)
    }

    @Test func stoppingThenRestartingByHandReportsTheStart() {
        var t = tracker([item("web", id: "1@0")])
        t.willStop(id: "1@0")
        _ = t.update([], now: 100)
        let back = item("web", id: "2@103", started: 103)
        #expect(t.update([back], now: 113).started == [back])
    }

    @Test func hiddenItemsAreNeverReported() {
        var t = tracker([item("web")])
        // Hiding a running server isn't a stop; showing it again isn't a start.
        #expect(t.update([item("web", hidden: true)], now: 100).isEmpty)
        #expect(t.update([item("web")], now: 200).isEmpty)
        #expect(t.update([item("web"), item("api", started: 200, hidden: true)], now: 300).isEmpty)
        _ = t.update([item("web")], now: 400)
        #expect(t.update([item("web")], now: 500).isEmpty)
    }

    @Test func messages() {
        #expect(ChangeMessage([], verb: "started") == nil)
        let one = ChangeMessage([item("web")], verb: "started")
        #expect(one?.title == "web started")
        #expect(one?.body == "shop · localhost:3000")
        let many = ChangeMessage(["a", "b", "c", "d"].map { item($0) }, verb: "stopped")
        #expect(many?.title == "4 servers stopped")
        #expect(many?.body == "a, b, c and 1 more")
    }
}
