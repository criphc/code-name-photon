import Foundation

/// Injectable sleep so every timeout path is deterministic in tests: pass `ImmediateSleeper`
/// and no test ever waits for wall-clock time (ADR-0010 §3).
public protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct WallClockSleeper: Sleeper {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Injectable time source used only to measure `ExitInfo.ranFor`. Tests can advance a fake
/// clock instead of sleeping.
public protocol SupervisionClock: Sendable {
    var now: ContinuousClock.Instant { get }
}

public struct SystemSupervisionClock: SupervisionClock {
    public init() {}

    public var now: ContinuousClock.Instant { ContinuousClock.now }
}

public struct SupervisionPolicy: Sendable {
    /// How long the child gets to print its ready line.
    public var readyTimeout: Duration
    /// Grace between SIGTERM and SIGKILL.
    public var terminationGracePeriod: Duration
    /// How long we wait for exit after SIGKILL (and for pipes to reach EOF).
    public var killWaitTimeout: Duration
    /// Ring-buffer size for the log tail handed to the UI.
    public var maxLogLines: Int
    /// Longest line kept verbatim; longer lines are clamped (byte counters stay exact).
    public var maxLineBytes: Int
    /// Ready timeout, termination grace, kill wait and the drain fallback all go through this.
    public var sleeper: any Sleeper
    /// Time source for `ExitInfo.ranFor`.
    public var clock: any SupervisionClock

    public init(
        readyTimeout: Duration = .seconds(10),
        terminationGracePeriod: Duration = .seconds(3),
        killWaitTimeout: Duration = .seconds(5),
        maxLogLines: Int = 2_000,
        maxLineBytes: Int = 64 * 1024,
        sleeper: any Sleeper = WallClockSleeper(),
        clock: any SupervisionClock = SystemSupervisionClock()
    ) {
        self.readyTimeout = readyTimeout
        self.terminationGracePeriod = terminationGracePeriod
        self.killWaitTimeout = killWaitTimeout
        self.maxLogLines = maxLogLines
        self.maxLineBytes = maxLineBytes
        self.sleeper = sleeper
        self.clock = clock
    }
}
