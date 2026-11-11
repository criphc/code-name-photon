import Foundation
import ServerControl

/// Returns immediately for every sleep. Timeout tests use this so a ready timeout or a
/// SIGTERM→SIGKILL escalation never waits for wall-clock time (ADR-0010 §3).
public struct ImmediateSleeper: Sleeper {
    public init() {}

    public func sleep(for duration: Duration) async throws {}
}

/// Blocks every sleep until `openGate()` is called, then returns immediately. Use this when a
/// test must become ready first (the ready timeout must not win the race) and only then wants
/// the grace/kill timers to elapse instantly.
public final class GateSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(open: Bool = false) {
        self.isOpen = open
    }

    /// Releases every current and future sleep.
    public func openGate() {
        lock.lock()
        isOpen = true
        let waiters = self.waiters
        self.waiters = []
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    public func sleep(for duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// Deterministic clock for `ExitInfo.ranFor` assertions. Advance it by hand; nothing sleeps.
public final class FakeSupervisionClock: SupervisionClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: ContinuousClock.Instant

    public init(start: ContinuousClock.Instant = ContinuousClock.now) {
        self.current = start
    }

    public var now: ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        lock.unlock()
    }
}
