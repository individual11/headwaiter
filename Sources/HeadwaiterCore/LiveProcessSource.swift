import Darwin
import Foundation

/// Reads processes and sockets straight from the kernel with libproc and sysctl.
/// No subprocesses. Processes owned by other users are skipped where the kernel refuses access.
///
/// One instance is one scan: it captures the socket list and parent map once and caches
/// per-PID snapshots, so create a new instance for each poll.
public final class LiveProcessSource: ProcessSource {
    private var sockets: [ListeningSocket] = []
    private var parents: [Int32: Int32] = [:]
    private var bsdInfo: [Int32: proc_bsdinfo] = [:]
    private var snapshots: [Int32: ProcessSnapshot?] = [:]

    public init() {
        scan()
    }

    public func listeningSockets() -> [ListeningSocket] { sockets }
    public func parentMap() -> [Int32: Int32] { parents }

    public func snapshot(of pid: Int32) -> ProcessSnapshot? {
        if let cached = snapshots[pid] { return cached }
        let snap = buildSnapshot(pid)
        snapshots[pid] = snap
        return snap
    }

    // MARK: - Scan

    private func scan() {
        for pid in Self.allPIDs() where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            bsdInfo[pid] = info
            parents[pid] = Int32(info.pbi_ppid)
            sockets.append(contentsOf: Self.listeningSockets(of: pid))
        }
    }

    static func allPIDs() -> [pid_t] {
        // Ask for the count first, then over-allocate in case processes appear in between.
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n)))
    }

    static func listeningSockets(of pid: pid_t) -> [ListeningSocket] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for a few more descriptors opened since the size query.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }

        var result: [ListeningSocket] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let siSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, siSize) == siSize else { continue }
            guard si.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let ini = tcp.tcpsi_ini
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            result.append(ListeningSocket(pid: pid, port: port, address: Self.address(ini),
                                          pcb: si.psi.soi_pcb))
        }
        return result
    }

    static func address(_ ini: in_sockinfo) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
            var addr = ini.insi_laddr.ina_6
            // A v6 socket that also accepts v4 still reports "::" for the wildcard.
            inet_ntop(AF_INET6, &addr, &buffer, socklen_t(buffer.count))
        } else {
            var addr = ini.insi_laddr.ina_46.i46a_addr4
            inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count))
        }
        return string(fromNulTerminated: buffer)
    }

    // MARK: - Per-process details

    private func buildSnapshot(_ pid: Int32) -> ProcessSnapshot? {
        guard let info = bsdInfo[pid] else { return nil }
        let path = Self.executablePath(pid) ?? Self.cString(info.pbi_comm)
        let args = Self.arguments(pid) ?? [path]
        let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        return ProcessSnapshot(pid: pid, ppid: Int32(info.pbi_ppid), pgid: Int32(info.pbi_pgid),
                               uid: info.pbi_uid, startTime: start, executablePath: path,
                               arguments: args, cwd: Self.workingDirectory(pid))
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return string(fromNulTerminated: buffer)
    }

    static func string(fromNulTerminated buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func workingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = cString(info.pvi_cdir.vip_path)
        return path.isEmpty ? nil : path
    }

    /// argv via KERN_PROCARGS2. Layout: Int32 argc, exec path, NUL padding, then argc strings.
    static func arguments(_ pid: pid_t) -> [String]? {
        var argMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argMax, &size, nil, 0) == 0, argMax > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var length = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0, length > MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        // Skip the exec path and the NUL padding after it.
        while i < length, buffer[i] != 0 { i += 1 }
        while i < length, buffer[i] == 0 { i += 1 }

        var args: [String] = []
        while args.count < argc, i < length {
            let start = i
            while i < length, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args.isEmpty ? nil : normalizeRetitled(args)
    }

    /// `process.title = "npm run dev"` (Node/libuv) writes the title over argv[0] and blanks
    /// the remaining arguments, so the kernel reports ["npm run dev", "", ""]. Split such a title
    /// back into words so wrapper rules can match "npm". Real argv[0] paths with spaces keep
    /// their other arguments, so they're left alone.
    static func normalizeRetitled(_ args: [String]) -> [String] {
        var trimmed = args
        while trimmed.count > 1, trimmed.last?.isEmpty == true { trimmed.removeLast() }
        guard trimmed.count == 1, let title = trimmed.first, title.contains(" "),
              !FileManager.default.fileExists(atPath: title) else { return trimmed }
        return title.split(separator: " ").map(String.init)
    }

    /// Converts a fixed-size C char tuple (imported as a Swift tuple) to a String.
    static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self)
        }
    }
}
