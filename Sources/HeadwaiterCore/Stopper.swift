import Darwin
import Foundation

/// A process that can't be confused with a later process that reuses its PID.
public struct ProcessIdentity: Hashable, Sendable, Codable, CustomStringConvertible {
    public var pid: Int32
    public var startTime: Double

    public init(pid: Int32, startTime: Double) {
        self.pid = pid
        self.startTime = startTime
    }

    public init(_ snapshot: ProcessSnapshot) {
        self.init(pid: snapshot.pid, startTime: snapshot.startTime)
    }

    /// True if `source` still shows this PID with the same start time.
    public func isAlive(in source: ProcessSource) -> Bool {
        guard let s = source.snapshot(of: pid) else { return false }
        return abs(s.startTime - startTime) < 0.01
    }

    public var description: String { "\(pid)" }
}

/// What Stop will signal: the server root and everything below it, deepest first.
/// Never the orchestrator, shell or agent above the root, and never its process group:
/// agent-launched servers share the agent's group.
public struct StopPlan: Sendable, Equatable {
    public var root: ProcessIdentity
    /// Deepest descendants first, root last, so children get the signal before the
    /// wrapper that would otherwise forward it (or exit and orphan them).
    public var targets: [ProcessIdentity]

    public init(root: ProcessIdentity, targets: [ProcessIdentity]) {
        self.root = root
        self.targets = targets
    }
}

public enum StopFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// The server root is gone (or its PID now belongs to another process).
    case alreadyExited
    /// The kernel refused, e.g. a process owned by another user.
    case permissionDenied(pid: Int32)
    case failed(pid: Int32, errno: Int32)

    public var description: String {
        switch self {
        case .alreadyExited: "Already stopped"
        case .permissionDenied(let pid): "Not allowed to stop process \(pid)"
        case .failed(let pid, let e): "Couldn't signal process \(pid): \(String(cString: strerror(e)))"
        }
    }
}

public protocol SignalSending: Sendable {
    /// Returns 0 on success, else errno.
    func send(_ signal: Int32, to pid: Int32) -> Int32
}

public struct SystemSignalSender: SignalSending {
    public init() {}
    public func send(_ signal: Int32, to pid: Int32) -> Int32 {
        kill(pid, signal) == 0 ? 0 : errno
    }
}

public enum Stopper {
    /// Plans a stop from the current process table. nil if the root already exited or its
    /// PID was reused (start time differs).
    public static func plan(root: ProcessIdentity, source: ProcessSource) -> StopPlan? {
        guard root.pid > 1, root.pid != getpid(), root.isAlive(in: source) else { return nil }

        var children: [Int32: [Int32]] = [:]
        for (pid, ppid) in source.parentMap() { children[ppid, default: []].append(pid) }

        // Breadth-first from the root, recording depth.
        var found: [(identity: ProcessIdentity, depth: Int)] = [(root, 0)]
        var queue: [(Int32, Int)] = [(root.pid, 0)]
        var seen: Set<Int32> = [root.pid]
        while !queue.isEmpty {
            let (pid, depth) = queue.removeFirst()
            for child in children[pid, default: []].sorted() where child > 1 && child != getpid() && !seen.contains(child) {
                seen.insert(child)
                guard let snap = source.snapshot(of: child) else { continue }
                found.append((ProcessIdentity(snap), depth + 1))
                queue.append((child, depth + 1))
            }
        }
        let ordered = found.sorted { ($0.depth, $0.identity.pid) > ($1.depth, $1.identity.pid) }.map(\.identity)
        return StopPlan(root: root, targets: ordered)
    }

    public static func plan(for server: Server, source: ProcessSource) -> StopPlan? {
        plan(root: ProcessIdentity(server.root), source: source)
    }

    /// Sends `signal` to every target that is still the same process. Targets that already
    /// exited are skipped. Fails only if nothing could be signalled for a reason other than exit.
    @discardableResult
    public static func signal(_ signal: Int32, _ plan: StopPlan, source: ProcessSource,
                              sender: SignalSending = SystemSignalSender()) -> Result<[ProcessIdentity], StopFailure> {
        var signalled: [ProcessIdentity] = []
        var firstFailure: StopFailure?
        for target in plan.targets where target.isAlive(in: source) {
            let err = sender.send(signal, to: target.pid)
            switch err {
            case 0: signalled.append(target)
            case ESRCH: continue // exited between the check and the signal
            case EPERM: firstFailure = firstFailure ?? .permissionDenied(pid: target.pid)
            default: firstFailure = firstFailure ?? .failed(pid: target.pid, errno: err)
            }
        }
        if signalled.isEmpty {
            return .failure(firstFailure ?? .alreadyExited)
        }
        return .success(signalled)
    }

    /// Targets of `plan` still alive, plus anything newly spawned under a live root
    /// (a wrapper that restarted its child). This is what force quit kills.
    public static func survivors(of plan: StopPlan, source: ProcessSource) -> StopPlan? {
        var targets = plan.targets.filter { $0.isAlive(in: source) }
        if let fresh = Self.plan(root: plan.root, source: source) {
            for t in fresh.targets where !targets.contains(t) { targets.insert(t, at: 0) }
        }
        return targets.isEmpty ? nil : StopPlan(root: plan.root, targets: targets)
    }
}
