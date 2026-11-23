import Darwin
import Foundation

// Docker containers with published ports. Their ports belong to Docker's own helper process
// (com.docker.backend, OrbStack, Colima's VM), so process inspection can't see what's inside;
// the Docker Engine API can. Compose labels name the project folder, which lets containers
// group with the Node/Python servers of the same repo.

/// A running container as the Docker API lists it (only the fields used).
public struct DockerContainer: Codable, Hashable, Sendable {
    public struct PortMapping: Codable, Hashable, Sendable {
        public var IP: String?
        public var PrivatePort: UInt16
        public var PublicPort: UInt16?
        public var `Type`: String

        public init(IP: String?, PrivatePort: UInt16, PublicPort: UInt16?, Type: String) {
            self.IP = IP
            self.PrivatePort = PrivatePort
            self.PublicPort = PublicPort
            self.Type = Type
        }
    }

    public var Id: String
    public var Names: [String]
    public var Image: String
    public var Created: Double
    public var State: String
    public var Ports: [PortMapping]
    public var Labels: [String: String]?

    public init(Id: String, Names: [String], Image: String, Created: Double, State: String,
                Ports: [PortMapping], Labels: [String: String]?) {
        self.Id = Id
        self.Names = Names
        self.Image = Image
        self.Created = Created
        self.State = State
        self.Ports = Ports
        self.Labels = Labels
    }
}

/// One row in the UI for a container.
public struct ContainerServer: Codable, Hashable, Sendable, Identifiable {
    public var id: String                 // container ID
    public var name: String               // Compose service, else container name
    public var image: String              // e.g. "postgres:16"
    public var project: Project?          // from Compose labels; nil groups under "Docker"
    public var composeProject: String?
    public var primaryPort: UInt16
    public var secondaryPorts: [UInt16]
    /// Web servers open in a browser; databases and the like copy host:port instead.
    public var isHTTP: Bool
    public var url: URL
    public var startTime: Double

    /// "postgres:16" from "docker.io/library/postgres:16" or a digest-pinned image.
    public var imageShortName: String {
        let last = image.split(separator: "/").last.map(String.init) ?? image
        return last.split(separator: "@").first.map(String.init) ?? last
    }

    public var address: String { "localhost:\(primaryPort)" }
}

public protocol ContainerSource {
    /// nil when Docker isn't running or reachable; [] when it is but nothing runs.
    func runningContainers() -> [DockerContainer]?
    func stop(_ id: String, kill: Bool) -> Bool
}

public enum ContainerResolver {
    /// Images whose ports aren't web pages.
    static let nonHTTPImages = ["postgres", "postgis", "mysql", "mariadb", "redis", "valkey", "mongo", "memcached",
                                "rabbitmq", "kafka", "zookeeper", "elasticsearch", "cassandra", "clickhouse",
                                "nats", "minio/minio:", "localstack"]

    public static func servers(from containers: [DockerContainer]) -> [ContainerServer] {
        containers.compactMap { c in
            guard c.State == "running" else { return nil }
            let ports = Array(Set(c.Ports.filter { $0.Type == "tcp" }.compactMap(\.PublicPort))).sorted()
            guard let primary = ports.first else { return nil }   // nothing reachable from the Mac
            let labels = c.Labels ?? [:]
            let service = labels["com.docker.compose.service"]
            let composeProject = labels["com.docker.compose.project"]
            let project = labels["com.docker.compose.project.working_dir"].map {
                Project(rootPath: $0, name: composeProject ?? ($0 as NSString).lastPathComponent)
            }
            let name = service ?? c.Names.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String(c.Id.prefix(12))
            let image = c.Image.lowercased()
            let isHTTP = !nonHTTPImages.contains { image.contains($0) }
            return ContainerServer(
                id: c.Id, name: name, image: c.Image, project: project, composeProject: composeProject,
                primaryPort: primary, secondaryPorts: Array(ports.dropFirst()), isHTTP: isHTTP,
                url: URL(string: "http://localhost:\(primary)")!, startTime: c.Created)
        }
        .sorted { ($0.project?.rootPath ?? "~", $0.name) < ($1.project?.rootPath ?? "~", $1.name) }
    }
}

/// Talks to the Docker Engine API over its Unix socket with plain HTTP/1.0. No dependencies.
public struct DockerSocketSource: ContainerSource {
    public let socketPath: String?

    public init(socketPath: String? = DockerSocketSource.findSocket()) {
        self.socketPath = socketPath
    }

    /// DOCKER_HOST (unix://), then the usual places for Docker Desktop, OrbStack, Colima and
    /// Rancher Desktop, then the system default.
    public static func findSocket(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: String = NSHomeDirectory()) -> String? {
        var candidates: [String] = []
        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            candidates.append(String(host.dropFirst("unix://".count)))
        }
        candidates += ["\(home)/.docker/run/docker.sock", "\(home)/.orbstack/run/docker.sock",
                       "\(home)/.colima/default/docker.sock", "\(home)/.rd/docker.sock", "/var/run/docker.sock"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    public func runningContainers() -> [DockerContainer]? {
        guard let body = request("GET", "/containers/json") else { return nil }
        return try? JSONDecoder().decode([DockerContainer].self, from: body)
    }

    public func stop(_ id: String, kill: Bool) -> Bool {
        guard id.allSatisfy({ $0.isHexDigit }) else { return false }
        return request("POST", kill ? "/containers/\(id)/kill" : "/containers/\(id)/stop?t=10", timeout: 15) != nil
    }

    /// Returns the response body for a 2xx response, else nil.
    func request(_ method: String, _ path: String, timeout: Int = 3) -> Data? {
        guard let socketPath else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }

        let requestText = "\(method) \(path) HTTP/1.0\r\nHost: docker\r\nContent-Length: 0\r\n\r\n"
        let sent = requestText.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
        guard sent > 0 else { return nil }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            response.append(contentsOf: buffer[0..<n])
            if response.count > 20_000_000 { return nil }
        }
        return Self.body(ofHTTPResponse: response)
    }

    /// Splits an HTTP/1.0 response; returns the body when the status is 2xx.
    static func body(ofHTTPResponse data: Data) -> Data? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let parts = head.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let status = Int(parts[1]), (200..<300).contains(status) else { return nil }
        return data[headerEnd.upperBound...]
    }
}
