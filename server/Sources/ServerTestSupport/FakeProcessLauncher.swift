import Foundation
import ServerControl

/// A scriptable, in-memory child. Tests drive its stdout/stderr and exit synchronously; no
/// real process is spawned, so there is nothing to leak.
public final class FakeLaunchedProcess: LaunchedChildProcess, @unchecked Sendable {
    /// What SIGTERM does. `.ignoreTerminate` is the child that forces SIGKILL escalation.
    public enum TerminationBehavior: Sendable, Equatable {
        case exitOnTerminate(TerminationReason)
        case ignoreTerminate
    }

    public let processIdentifier: Int32

    private let lock = NSLock()
    private var stdoutHandler: (@Sendable (Data) -> Void)?
    private var stderrHandler: (@Sendable (Data) -> Void)?
    private var exitHandler: (@Sendable (TerminationReason) -> Void)?
    private var running = true
    private var didExit = false
    private var behavior: TerminationBehavior
    private var terminateCountStorage = 0
    private var forceKillCountStorage = 0
    private var exitReasonStorage: TerminationReason?

    init(processIdentifier: Int32, terminationBehavior: TerminationBehavior) {
        self.processIdentifier = processIdentifier
        self.behavior = terminationBehavior
    }

    // MARK: - Observations

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public var terminationBehavior: TerminationBehavior {
        get {
            lock.lock()
            defer { lock.unlock() }
            return behavior
        }
        set {
            lock.lock()
            behavior = newValue
            lock.unlock()
        }
    }

    public var terminateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminateCountStorage
    }

    public var forceKillCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return forceKillCountStorage
    }

    public var receivedTerminate: Bool { terminateCount > 0 }
    public var receivedForceKill: Bool { forceKillCount > 0 }

    public var deliveredExitReason: TerminationReason? {
        lock.lock()
        defer { lock.unlock() }
        return exitReasonStorage
    }

    // MARK: - Lifecycle

    public func terminate() {
        lock.lock()
        terminateCountStorage += 1
        let behavior = self.behavior
        let alreadyExited = didExit
        lock.unlock()
        guard !alreadyExited else { return }
        if case .exitOnTerminate(let reason) = behavior {
            exit(reason)
        }
    }

    public func forceKill() {
        lock.lock()
        forceKillCountStorage += 1
        let alreadyExited = didExit
        lock.unlock()
        guard !alreadyExited else { return }
        exit(.uncaughtSignal(9))
    }

    /// Emits an exit exactly once: EOFs for both pipes first, then the termination callback.
    /// Use `deliveringEOF: false` only to exercise the supervisor's drain fallback.
    public func exit(_ reason: TerminationReason, deliveringEOF: Bool = true) {
        lock.lock()
        guard !didExit else {
            lock.unlock()
            return
        }
        didExit = true
        running = false
        exitReasonStorage = reason
        let stdoutHandler = self.stdoutHandler
        let stderrHandler = self.stderrHandler
        let exitHandler = self.exitHandler
        lock.unlock()

        if deliveringEOF {
            stdoutHandler?(Data())
            stderrHandler?(Data())
        }
        exitHandler?(reason)
    }

    // MARK: - Output scripting

    public func emitStdout(_ data: Data) {
        lock.lock()
        let handler = stdoutHandler
        let alreadyExited = didExit
        lock.unlock()
        guard !alreadyExited else { return }
        handler?(data)
    }

    public func emitStdout(_ text: String) {
        emitStdout(Data(text.utf8))
    }

    /// Appends the newline that makes this a line for the supervisor's parser.
    public func emitStdoutLine(_ text: String) {
        emitStdout(Data((text + "\n").utf8))
    }

    public func emitStderr(_ data: Data) {
        lock.lock()
        let handler = stderrHandler
        let alreadyExited = didExit
        lock.unlock()
        guard !alreadyExited else { return }
        handler?(data)
    }

    public func emitStderr(_ text: String) {
        emitStderr(Data(text.utf8))
    }

    public func emitStderrLine(_ text: String) {
        emitStderr(Data((text + "\n").utf8))
    }

    public func endStdout() {
        emitStdout(Data())
    }

    public func endStderr() {
        emitStderr(Data())
    }

    // MARK: - Launcher wiring

    func attach(
        stdout: @escaping @Sendable (Data) -> Void,
        stderr: @escaping @Sendable (Data) -> Void,
        exit: @escaping @Sendable (TerminationReason) -> Void
    ) {
        lock.lock()
        stdoutHandler = stdout
        stderrHandler = stderr
        exitHandler = exit
        lock.unlock()
    }
}

/// Creates `FakeLaunchedProcess` handles instead of spawning anything. `nextLaunched()` is the
/// deterministic handshake with the supervisor's `start()`: it returns as soon as the launch
/// happened, without polling or sleeping.
public final class FakeProcessLauncher: ChildProcessLaunching, @unchecked Sendable {
    public struct LaunchFailure: Error, Sendable, Equatable {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }
    }

    public let defaultTerminationBehavior: FakeLaunchedProcess.TerminationBehavior

    private let lock = NSLock()
    private var configurationsStorage: [LaunchConfiguration] = []
    private var processesStorage: [FakeLaunchedProcess] = []
    private var pending: [FakeLaunchedProcess] = []
    private var waiters: [CheckedContinuation<FakeLaunchedProcess, Never>] = []
    private var nextFailure: LaunchFailure?
    private var nextPID: Int32

    public init(
        defaultTerminationBehavior: FakeLaunchedProcess.TerminationBehavior = .exitOnTerminate(.exited(0)),
        firstProcessIdentifier: Int32 = 4_242
    ) {
        self.defaultTerminationBehavior = defaultTerminationBehavior
        self.nextPID = firstProcessIdentifier
    }

    public var launchedConfigurations: [LaunchConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return configurationsStorage
    }

    public var launchedProcesses: [FakeLaunchedProcess] {
        lock.lock()
        defer { lock.unlock() }
        return processesStorage
    }

    public var launchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return configurationsStorage.count
    }

    /// Makes the next `launch` throw instead of returning a handle.
    public func failNextLaunch(with message: String) {
        lock.lock()
        nextFailure = LaunchFailure(message)
        lock.unlock()
    }

    /// Suspends until the supervisor launched a child, then returns that fake.
    public func nextLaunched() async -> FakeLaunchedProcess {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !pending.isEmpty {
                let process = pending.removeFirst()
                lock.unlock()
                continuation.resume(returning: process)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    public func launch(
        configuration: LaunchConfiguration,
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (TerminationReason) -> Void
    ) throws -> any LaunchedChildProcess {
        lock.lock()
        configurationsStorage.append(configuration)
        if let failure = nextFailure {
            nextFailure = nil
            lock.unlock()
            throw failure
        }
        let processIdentifier = nextPID
        nextPID += 1
        let process = FakeLaunchedProcess(
            processIdentifier: processIdentifier,
            terminationBehavior: defaultTerminationBehavior
        )
        process.attach(stdout: onStdout, stderr: onStderr, exit: onExit)
        processesStorage.append(process)
        let waiter: CheckedContinuation<FakeLaunchedProcess, Never>?
        if waiters.isEmpty {
            pending.append(process)
            waiter = nil
        } else {
            waiter = waiters.removeFirst()
        }
        lock.unlock()
        waiter?.resume(returning: process)
        return process
    }
}
