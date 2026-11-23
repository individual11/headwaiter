import Foundation
import Testing
@testable import HeadwaiterCore

@Suite("Docker")
struct DockerTests {
    /// Shape of `GET /containers/json` from Docker Engine (trimmed to the fields used).
    static let sample = #"""
    [
      {"Id":"a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2","Names":["/shop-db-1"],
       "Image":"postgres:16","Created":1763600000,"State":"running",
       "Ports":[{"IP":"0.0.0.0","PrivatePort":5432,"PublicPort":5433,"Type":"tcp"},
                {"IP":"::","PrivatePort":5432,"PublicPort":5433,"Type":"tcp"}],
       "Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"db",
                 "com.docker.compose.project.working_dir":"/Users/dev/code/my-shop"}},
      {"Id":"ffff00001111ffff00001111ffff00001111ffff00001111ffff00001111ffff","Names":["/shop-api-1"],
       "Image":"ghcr.io/acme/api@sha256:abc","Created":1763600100,"State":"running",
       "Ports":[{"IP":"0.0.0.0","PrivatePort":8080,"PublicPort":8080,"Type":"tcp"},
                {"IP":"0.0.0.0","PrivatePort":9090,"PublicPort":9091,"Type":"tcp"},
                {"PrivatePort":53,"PublicPort":5353,"Type":"udp"}],
       "Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"api",
                 "com.docker.compose.project.working_dir":"/Users/dev/code/my-shop"}},
      {"Id":"1234123412341234123412341234123412341234123412341234123412341234","Names":["/cranky_turing"],
       "Image":"nginx:alpine","Created":1763600200,"State":"running",
       "Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8088,"Type":"tcp"}],"Labels":{}},
      {"Id":"9999999999999999999999999999999999999999999999999999999999999999","Names":["/worker"],
       "Image":"busybox","Created":1763600300,"State":"running",
       "Ports":[{"PrivatePort":80,"Type":"tcp"}],"Labels":null}
    ]
    """#

    func decoded() throws -> [DockerContainer] {
        try JSONDecoder().decode([DockerContainer].self, from: Data(Self.sample.utf8))
    }

    @Test func publishedTCPContainersBecomeRows() throws {
        let rows = ContainerResolver.servers(from: try decoded())
        #expect(rows.map(\.name) == ["api", "db", "cranky_turing"])   // Compose projects first, loose containers last
        #expect(!rows.contains { $0.name == "worker" })              // no published port: not reachable
    }

    @Test func composeLabelsMapToTheProjectFolder() throws {
        let db = try #require(ContainerResolver.servers(from: try decoded()).first { $0.name == "db" })
        #expect(db.project?.rootPath == "/Users/dev/code/my-shop")
        #expect(db.project?.name == "shop")
        #expect(db.primaryPort == 5433)                              // the host port, IPv4 and v6 deduped
        #expect(db.imageShortName == "postgres:16")
        #expect(!db.isHTTP)                                          // copy localhost:5433, don't open a browser
        #expect(db.address == "localhost:5433")
    }

    @Test func webContainersOpenInTheBrowser() throws {
        let api = try #require(ContainerResolver.servers(from: try decoded()).first { $0.name == "api" })
        #expect(api.isHTTP)
        #expect(api.primaryPort == 8080)
        #expect(api.secondaryPorts == [9091])                        // UDP 5353 ignored
        #expect(api.imageShortName == "api")
        #expect(api.url.absoluteString == "http://localhost:8080")
    }

    @Test func httpResponseParsing() {
        let ok = Data("HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n\r\n[]".utf8)
        #expect(DockerSocketSource.body(ofHTTPResponse: ok).map { String(decoding: $0, as: UTF8.self) } == "[]")
        let noContent = Data("HTTP/1.0 204 No Content\r\n\r\n".utf8)
        #expect(DockerSocketSource.body(ofHTTPResponse: noContent)?.isEmpty == true)
        let notFound = Data("HTTP/1.0 404 Not Found\r\n\r\n{\"message\":\"x\"}".utf8)
        #expect(DockerSocketSource.body(ofHTTPResponse: notFound) == nil)
    }

    @Test func socketDiscoveryPrefersDockerHost() {
        let found = DockerSocketSource.findSocket(environment: ["DOCKER_HOST": "unix:///nonexistent.sock"], home: "/nowhere")
        // Nothing exists in this test environment except possibly /var/run/docker.sock.
        #expect(found == nil || found == "/var/run/docker.sock")
    }
}
