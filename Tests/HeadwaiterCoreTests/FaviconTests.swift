import Foundation
import Testing
@testable import HeadwaiterCore

@Suite("Favicons")
struct FaviconTests {
    let custom = Data("<svg xmlns='http://www.w3.org/2000/svg'><circle r='8'/></svg>".utf8)

    /// Files exist in the in-memory file system; their bytes come from `blobs`.
    func find(_ blobs: [String: Data], folders: [String], denied: Set<String> = [],
              gate: Bool = false) -> (path: String, data: Data)? {
        let memory = InMemoryFileSystem(files: blobs.mapValues { _ in "" }, deniedDirectories: denied)
        let fs: FileReading = gate ? ProtectedFolderGate(memory) : memory
        return Favicon.find(in: folders, fs: fs, load: { blobs[$0] })
    }

    @Test func prefersNextAppIconOverPublicFavicon() throws {
        let found = try #require(find([
            "/p/web/public/favicon.ico": custom,
            "/p/web/app/icon.svg": custom,
        ], folders: ["/p/web"]))
        #expect(found.path == "/p/web/app/icon.svg")
    }

    @Test func fallsBackToProjectRoot() throws {
        let folders = Favicon.searchFolders(packagePath: "/p/apps/web", projectRoot: "/p")
        #expect(folders == ["/p/apps/web", "/p"])
        let found = try #require(find(["/p/static/favicon.png": custom], folders: folders))
        #expect(found.path == "/p/static/favicon.png")
        #expect(Favicon.searchFolders(packagePath: "/p", projectRoot: "/p") == ["/p"])
    }

    @Test func skipsEmptyFilesAndKeepsLooking() throws {
        // Rails ships an empty public/favicon.ico next to its starter icon.png.
        let found = try #require(find([
            "/r/public/favicon.ico": Data(),
            "/r/favicon.svg": custom,
        ], folders: ["/r"]))
        #expect(found.path == "/r/favicon.svg")
    }

    @Test func starterIconsAreRecognized() {
        // The Rails starter icon.svg, byte for byte.
        let railsSVG = Data("""
        <svg width="512" height="512" xmlns="http://www.w3.org/2000/svg">
          <circle cx="256" cy="256" r="256" fill="red"/>
        </svg>

        """.utf8)
        #expect(Favicon.isStarter(railsSVG))
        #expect(find(["/r/public/icon.svg": railsSVG], folders: ["/r"]) == nil)
        #expect(!Favicon.isStarter(custom))
        #expect(Favicon.isUsable(custom))
        #expect(!Favicon.isUsable(Data(count: Favicon.maxBytes + 1)))
    }

    @Test func protectedFoldersAreNotTouchedWhileGated() {
        let blobs = ["/Users/dev/Desktop/app/public/favicon.svg": custom]
        #expect(find(blobs, folders: ["/Users/dev/Desktop/app"], gate: true) == nil)
        #expect(find(blobs, folders: ["/Users/dev/Desktop/app"]) != nil)
    }

    @Test func deniedFoldersAreSkipped() {
        #expect(find(["/d/public/favicon.svg": custom], folders: ["/d"], denied: ["/d"]) == nil)
    }

    @Test func serverURLAsksOnlyForFaviconIco() {
        let url = URL(string: "http://localhost:5173/app?x=1#top")!
        #expect(Favicon.serverURL(for: url)?.absoluteString == "http://localhost:5173/favicon.ico")
    }
}
