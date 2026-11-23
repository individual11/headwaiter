import Darwin
import Foundation

// Sandbox spike. Signed with the App Sandbox entitlement by
// scripts/sandbox-spike.sh, it tries every call the real app depends on against a
// target process it did NOT start, and prints PASS/FAIL per call. Answers: what could an
// App Store edition still do?
//
// Usage (via the script): sandbox-spike <target-pid> <target-port> <project-file> <kill-pid>

let args = CommandLine.arguments
guard args.count == 5, let target = Int32(args[1]), let port = UInt16(args[2]), let killPID = Int32(args[4]) else {
    print("usage: sandbox-spike <target-pid> <target-port> <project-file> <kill-pid>")
    exit(2)
}
let projectFile = args[3]

var results: [(String, Bool, String)] = []
@MainActor func record(_ name: String, _ ok: Bool, _ detail: String) {
    results.append((name, ok, detail))
    print("\(ok ? "PASS" : "FAIL")  \(name)  — \(detail)")
}
func err() -> String { String(cString: strerror(errno)) }

let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
print("App Sandbox active: \(sandboxed)  (container: \(NSHomeDirectory()))\n")

// 1. List all processes.
let count = proc_listallpids(nil, 0)
record("proc_listallpids", count > 0, count > 0 ? "\(count) pids visible" : "returned \(count): \(err())")

// 2. Basic info on another user process.
var bsd = proc_bsdinfo()
let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
let bsdOK = proc_pidinfo(target, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize
record("proc_pidinfo TBSDINFO (parent, start time)", bsdOK, bsdOK ? "ppid \(bsd.pbi_ppid)" : err())

// 3. Executable path.
var pathBuf = [CChar](repeating: 0, count: 4096)
let pathOK = proc_pidpath(target, &pathBuf, UInt32(pathBuf.count)) > 0
record("proc_pidpath", pathOK, pathOK ? String(decoding: pathBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : err())

// 4. File descriptors → listening socket.
let fdBytes = proc_pidinfo(target, PROC_PIDLISTFDS, 0, nil, 0)
var listening = false
if fdBytes > 0 {
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride + 8)
    let got = proc_pidinfo(target, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
    for fd in fds.prefix(Int(max(got, 0)) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
        var si = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        if proc_pidfdinfo(target, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size,
           si.psi.soi_kind == Int32(SOCKINFO_TCP), si.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) {
            listening = true
        }
    }
}
record("proc_pidinfo LISTFDS (open files)", fdBytes > 0, fdBytes > 0 ? "\(fdBytes) bytes" : err())
record("proc_pidfdinfo SOCKETINFO (find listening socket)", listening, listening ? "found TCP LISTEN" : "no listening socket seen")

// 5. Working directory.
var vnode = proc_vnodepathinfo()
let vSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
let cwdOK = proc_pidinfo(target, PROC_PIDVNODEPATHINFO, 0, &vnode, vSize) == vSize
let cwd = cwdOK ? withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) } : ""
record("proc_pidinfo VNODEPATHINFO (cwd)", cwdOK, cwdOK ? cwd : err())

// 6. Command line.
var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, target]
var buf = [UInt8](repeating: 0, count: 65536)
var len = buf.count
let argsOK = sysctl(&mib, 3, &buf, &len, nil, 0) == 0
record("sysctl KERN_PROCARGS2 (arguments)", argsOK, argsOK ? "\(len) bytes" : err())

// 7. Read the project's manifest outside the container.
let manifest = FileManager.default.contents(atPath: projectFile)
record("read project manifest", manifest != nil, manifest != nil ? "\(manifest!.count) bytes from \(projectFile)" : "denied: \(projectFile)")

// 8. Shell out to lsof (child inherits the sandbox).
let lsof = Process()
lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
lsof.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "p"]
let pipe = Pipe()
lsof.standardOutput = pipe
lsof.standardError = FileHandle.nullDevice
var lsofLines = 0
do {
    try lsof.run()
    lsofLines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").count
    lsof.waitUntilExit()
    record("run lsof", lsofLines > 0, "\(lsofLines) processes listed, exit \(lsof.terminationStatus)")
} catch {
    record("run lsof", false, "\(error)")
}

// 9. Probe the port over TCP and HTTP (network.client).
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = inet_addr("127.0.0.1")
let sock = socket(AF_INET, SOCK_STREAM, 0)
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
} == 0
close(sock)
record("TCP connect to localhost:\(port)", connected, connected ? "port answers" : err())

let sem = DispatchSemaphore(value: 0)
nonisolated(unsafe) var httpDetail = "no response"
nonisolated(unsafe) var httpOK = false
URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:\(port)/")!) { data, response, error in
    if let http = response as? HTTPURLResponse {
        httpOK = true
        httpDetail = "HTTP \(http.statusCode), \(data?.count ?? 0) bytes, server: \(http.value(forHTTPHeaderField: "Server") ?? "-")"
    } else if let error { httpDetail = error.localizedDescription }
    sem.signal()
}.resume()
_ = sem.wait(timeout: .now() + 3)
record("HTTP GET localhost:\(port)", httpOK, httpDetail)

// 10. Bind probing: is a port in use? (network.server)
let bsock = socket(AF_INET, SOCK_STREAM, 0)
var baddr = addr
let bound = withUnsafePointer(to: &baddr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(bsock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
let bindErr = errno
close(bsock)
let bindInformative = bound != 0 && bindErr == EADDRINUSE
record("bind probe on :\(port) (detect in-use)", bindInformative,
       bound == 0 ? "bind succeeded (port looked free?)" : String(cString: strerror(bindErr)))

// 10b. With proc_listallpids denied, can PIDs be found by trying every number?
let sweepStart = Date()
var found = 0
for pid in Int32(1)...Int32(99_999) {
    var info = proc_bsdinfo()
    if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, bsdSize) == bsdSize { found += 1 }
}
record("PID sweep 1…99999 via TBSDINFO", found > 0,
       "\(found) processes found in \(Int(Date().timeIntervalSince(sweepStart) * 1000)) ms")

// 11. Signal a process it didn't start. Never pid <= 1: kill(0, …) signals our own process
// group and kill(-1, …) every process we may signal.
guard killPID > 1 else {
    print("\n(kill test skipped)\n\(results.filter { $0.1 }.count)/\(results.count) passed")
    exit(0)
}
let alive = kill(killPID, 0) == 0
record("kill(pid, 0) on foreign process", alive, alive ? "allowed" : err())
let termed = kill(killPID, SIGTERM) == 0
record("kill(pid, SIGTERM) on foreign process", termed, termed ? "signal sent" : err())

print("\n\(results.filter { $0.1 }.count)/\(results.count) passed")
