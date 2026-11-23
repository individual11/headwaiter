import Foundation
import Testing
@testable import HeadwaiterCore

@Suite("URL overrides")
struct URLOverrideTests {
    @Test func samePortFollowsTheServer() throws {
        let o = try #require(URLOverride(text: "http://localhost:3000/admin", serverPort: 3000))
        #expect(o.port == nil)
        #expect(o.url(defaultPort: 3001)?.absoluteString == "http://localhost:3001/admin")
    }

    @Test func differentPortIsFixed() throws {
        let o = try #require(URLOverride(text: "https://app.localhost:8443/", serverPort: 3000))
        #expect(o.port == 8443)
        #expect(o.url(defaultPort: 3000)?.absoluteString == "https://app.localhost:8443/")
    }

    @Test func schemeIsOptional() throws {
        let o = try #require(URLOverride(text: "  localhost:5173/docs ", serverPort: 5173))
        #expect(o.url(defaultPort: 5173)?.absoluteString == "http://localhost:5173/docs")
    }

    @Test func garbageIsRejected() {
        #expect(URLOverride(text: "", serverPort: 3000) == nil)
        #expect(URLOverride(text: "http://", serverPort: 3000) == nil)
    }
}

@Suite("Protected folder gate")
struct ProtectedFolderGateTests {
    @Test func protectedFoldersAreNeverTouched() {
        let fs = InMemoryFileSystem(files: ["/Users/dev/Desktop/app/package.json": "{}",
                                            "/Users/dev/code/app/package.json": "{}"])
        let gate = ProtectedFolderGate(fs)
        #expect(gate.contents(of: "/Users/dev/Desktop/app/package.json") == nil)
        #expect(gate.isAccessDenied("/Users/dev/Desktop/app"))
        #expect(gate.contents(of: "/Users/dev/code/app/package.json") == "{}")
        #expect(!gate.isAccessDenied("/Users/dev/code/app"))
        #expect(!gate.isAccessDenied("/Users/dev/DesktopApps/x"))   // prefix match is per folder
    }
}
