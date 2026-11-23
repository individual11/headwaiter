import Darwin
import Dispatch

/// Calls back the moment a watched process exits, via kqueue (EVFILT_PROC / NOTE_EXIT,
/// through a dispatch process source). Works for any process this user can see, not just
/// children. It reports only *that* a process exited, not its exit status.
@MainActor
public final class ExitWatcher {
    private var sources: [Int32: DispatchSourceProcess] = [:]
    private let onExit: @MainActor (Int32) -> Void

    public init(onExit: @escaping @MainActor (Int32) -> Void) {
        self.onExit = onExit
    }

    public var watched: Set<Int32> { Set(sources.keys) }

    /// Makes the watched set exactly `pids`: stops watching the rest, starts on new ones.
    public func watch(_ pids: Set<Int32>) {
        for (pid, source) in sources where !pids.contains(pid) {
            source.cancel()
            sources[pid] = nil
        }
        for pid in pids where sources[pid] == nil && pid > 1 {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.fired(pid) }
            }
            sources[pid] = source
            source.resume()
            // A process that exited before the source was registered never fires.
            if kill(pid, 0) == -1 && errno == ESRCH {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.fired(pid) }
                }
            }
        }
    }

    public func cancelAll() { watch([]) }

    private func fired(_ pid: Int32) {
        guard let source = sources.removeValue(forKey: pid) else { return }
        source.cancel()
        onExit(pid)
    }
}
