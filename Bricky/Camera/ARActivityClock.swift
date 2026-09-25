import Foundation

/// How long AR has been running continuously. Several views own their own
/// `ARCameraManager`, so the clock counts running sessions by token: the
/// continuous run starts when the first session starts and ends when the last
/// one stops. The benchmark protocol's sustained bucket is ≥ 30 minutes of it
/// — the thermal regime a user deep into a build is actually in.
final class ARActivityClock: @unchecked Sendable {
    static let shared = ARActivityClock()

    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var running: Set<UUID> = []
    private var runStartedAt: TimeInterval?
    private var accumulated: TimeInterval = 0

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func sessionStarted(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if running.isEmpty { runStartedAt = now() }
        running.insert(token)
    }

    /// Idempotent, so a manager may report its stop from both `stopSession`
    /// and `deinit`.
    func sessionStopped(_ token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard running.remove(token) != nil, running.isEmpty, let start = runStartedAt else { return }
        accumulated += now() - start
        runStartedAt = nil
    }

    /// Seconds of the current continuous run, or nil when no session runs.
    var secondsSinceStart: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return runStartedAt.map { now() - $0 }
    }

    /// Total AR running time this launch, the current run included.
    var activeSeconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return accumulated + (runStartedAt.map { now() - $0 } ?? 0)
    }
}
