import ContractKit
import Foundation

/// Supervises one `appctl serve` child through the ADR-0010 process contract.
///
/// The state machine is explicit: `idle → starting → ready → running → stopping → stopped`,
/// with `failed` reachable from any state. The class is headless-testable: the process
/// launcher, the sleeper and the clock are injected, and the only observable surface is the
/// event stream plus the non-blocking `snapshot`.
///
/// Threading model: one `NSLock` guards all mutable state. Pipe callbacks and public methods
/// funnel through it; continuations and stream events are always resumed/yielded after
/// unlocking. Pipes are drained on their own threads (the launcher's), both streams
/// concurrently, so neither 1 MB of stderr nor a SIGTERM-ignoring child can deadlock. There
/// is no `waitUntilExit` anywhere and no task group racing exit against a timeout (a losing
/// group child would keep the group alive and deadlock the escalation path).
public final class ChildProcessSupervisor: @unchecked Sendable {
    public let launch: LaunchConfiguration
    public let policy: SupervisionPolicy
    public let launcher: any ChildProcessLaunching

    /// State changes and captured log lines. Single subscription: the owner (GUI/ServerControl
    /// façade) consumes it; `snapshot.logs` is an independent bounded tail.
    public let events: AsyncStream<SupervisorEvent>
    private let eventsContinuation: AsyncStream<SupervisorEvent>.Continuation

    private let lock = NSLock()
    private var state: SupervisorState = .idle
    private var child: (any LaunchedChildProcess)?
    private var childPID: Int32?
    private var logs: [LogLine] = []
    private var logSequence = 0
    private var droppedLogLines = 0
    private var stdoutBytes = 0
    private var stderrBytes = 0
    private var stdoutRemainder = Data()
    private var stderrRemainder = Data()
    private var readySeen = false
    private var readyInfo: ReadyInfo?
    private var requestedStop = false
    private var escalated = false
    private var startedAt: ContinuousClock.Instant?
    private var exitInfo: ExitInfo?
    private var pendingTermination: TerminationReason?
    private var eofStreams: Set<LogStream> = []
    private var finalized = false
    private var launchInFlight = false
    private var launchSettledWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiter: CheckedContinuation<ReadyInfo, Error>?
    private var exitWaiters: [ExitWaiter] = []

    public init(
        launch: LaunchConfiguration,
        policy: SupervisionPolicy = SupervisionPolicy(),
        launcher: any ChildProcessLaunching = SystemProcessLauncher()
    ) {
        self.launch = launch
        self.policy = policy
        self.launcher = launcher
        let (stream, continuation) = AsyncStream<SupervisorEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(4_096)
        )
        self.events = stream
        self.eventsContinuation = continuation
    }

    deinit {
        eventsContinuation.finish()
        // Best effort only: the supported path is `await stop()`. This covers ownership being
        // dropped while the child is still alive.
        lock.lock()
        let child = self.child
        let running = child?.isRunning ?? false
        lock.unlock()
        if running {
            child?.forceKill()
        }
    }

    // MARK: - Observable state

    public var currentState: SupervisorState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public var snapshot: SupervisorSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return SupervisorSnapshot(
            state: state,
            pid: childPID,
            isRunning: child?.isRunning ?? false,
            logs: logs,
            capturedStdoutBytes: stdoutBytes,
            capturedStderrBytes: stderrBytes,
            droppedLogLines: droppedLogLines,
            exitInfo: exitInfo
        )
    }

    // MARK: - Lifecycle

    /// Launches the child and waits for its readiness line.
    ///
    /// Restartable after `stopped`/`failed`; the log tail and byte counters restart with it.
    ///
    /// - Throws: `SupervisorError.failure` for spawn failures, ready timeout, pre-ready exit,
    ///   protocol violations and nonzero exits; `.stoppedBeforeReady` when stopped too early;
    ///   `.alreadyStarted` when the child is still starting/running.
    @discardableResult
    public func start() async throws -> ReadyInfo {
        let accepted = lock.withLock { () -> Bool in
            switch state {
            case .idle:
                break
            case .stopped, .failed:
                resetForRestartLocked()
            default:
                return false
            }
            state = .starting
            startedAt = policy.clock.now
            launchInFlight = true
            return true
        }
        guard accepted else { throw SupervisorError.alreadyStarted }
        eventsContinuation.yield(.stateChanged(.starting))

        do {
            try launchChild()
        } catch {
            settleLaunch()
            let message = "spawn failed: \(error)"
            fail(.spawnFailed(message))
            throw SupervisorError.failure(.spawnFailed(message))
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if readySeen, let info = readyInfo {
                lock.unlock()
                continuation.resume(returning: info)
                return
            }
            switch state {
            case .failed(let failure):
                lock.unlock()
                continuation.resume(throwing: SupervisorError.failure(failure))
                return
            case .stopped, .stopping:
                lock.unlock()
                continuation.resume(throwing: SupervisorError.stoppedBeforeReady)
                return
            default:
                break
            }
            startWaiter = continuation
            lock.unlock()
            scheduleReadyTimeout()
        }
    }

    /// Sends SIGTERM immediately and returns; never waits for the exit.
    ///
    /// For app-termination hooks: AppKit's nested event loop cannot drain the main queue, so
    /// the GUI sends the signal synchronously and returns `.terminateNow` (ADR-0010 §4).
    @discardableResult
    public func requestStop() -> Int32? {
        lock.lock()
        guard let child, child.isRunning, !requestedStop else {
            lock.unlock()
            return nil
        }
        requestedStop = true
        var changed = false
        switch state {
        case .starting, .ready, .running:
            state = .stopping
            changed = true
        default:
            break
        }
        let pid = child.processIdentifier
        lock.unlock()

        if changed {
            eventsContinuation.yield(.stateChanged(.stopping))
        }
        child.terminate() // SIGTERM, not a polite shutdown request
        return pid
    }

    /// SIGTERM → `terminationGracePeriod` → SIGKILL → bounded wait. Idempotent; returns the
    /// exit facts when the child is already gone.
    @discardableResult
    public func stop() async -> ExitInfo? {
        let disposition = lock.withLock { () -> StopDisposition in
            switch state {
            case .idle:
                return .idle
            case .stopped, .failed:
                return .terminal(exitInfo)
            case .starting, .ready, .running:
                requestedStop = true
                state = .stopping
                return .proceed(yieldStopping: true)
            case .stopping:
                return .proceed(yieldStopping: false)
            }
        }
        switch disposition {
        case .idle:
            return nil
        case .terminal(let info):
            return info
        case .proceed(let yieldStopping):
            if yieldStopping {
                eventsContinuation.yield(.stateChanged(.stopping))
            }
        }
        // If stop() wins the race against a slow `launch`, wait until the handle exists so the
        // SIGTERM is actually delivered instead of silently doing nothing.
        await waitForLaunchToSettle()
        return await terminateChild(graceful: true)
    }

    private enum StopDisposition {
        case idle
        case terminal(ExitInfo?)
        case proceed(yieldStopping: Bool)
    }

    // MARK: - Spawn

    private func launchChild() throws {
        let handle = try launcher.launch(
            configuration: launch,
            onStdout: { [weak self] data in self?.receive(data, stream: .stdout) },
            onStderr: { [weak self] data in self?.receive(data, stream: .stderr) },
            onExit: { [weak self] reason in self?.processDidTerminate(reason) }
        )
        lock.lock()
        childPID = handle.processIdentifier
        // An instantly-exiting child may already have finalized inside `launch`; don't
        // resurrect a dead handle into the snapshot.
        if !finalized {
            child = handle
        }
        lock.unlock()
        settleLaunch()
    }

    private func settleLaunch() {
        lock.lock()
        launchInFlight = false
        let waiters = launchSettledWaiters
        launchSettledWaiters = []
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForLaunchToSettle() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !launchInFlight {
                lock.unlock()
                continuation.resume()
                return
            }
            launchSettledWaiters.append(continuation)
            lock.unlock()
        }
    }

    private func scheduleReadyTimeout() {
        let timeout = policy.readyTimeout
        Task { [weak self] in
            guard let self else { return }
            try? await self.policy.sleeper.sleep(for: timeout)
            self.readyTimedOut(timeout)
        }
    }

    private func readyTimedOut(_ timeout: Duration) {
        lock.lock()
        guard case .starting = state, let waiter = startWaiter else {
            lock.unlock()
            return
        }
        startWaiter = nil
        state = .failed(.readyTimeout(timeout))
        lock.unlock()

        eventsContinuation.yield(.stateChanged(.failed(.readyTimeout(timeout))))
        waiter.resume(throwing: SupervisorError.failure(.readyTimeout(timeout)))
        // Clean the child up without flipping the state away from `.failed`.
        Task { _ = await self.terminateChild(graceful: true) }
    }

    // MARK: - Pipe reading

    private func receive(_ data: Data, stream: LogStream) {
        if data.isEmpty {
            streamReachedEOF(stream)
        } else {
            ingest(data, stream: stream)
        }
    }

    private func ingest(_ data: Data, stream: LogStream) {
        lock.lock()
        if stream == .stdout {
            stdoutBytes += data.count
        } else {
            stderrBytes += data.count
        }
        let maxLineBytes = policy.maxLineBytes
        let maxLogLines = policy.maxLogLines

        var emitted: [LogLine] = []
        var readyAction: ReadyInfo?
        var violation: String?
        var parseProtocol = false
        if case .starting = state {
            parseProtocol = !readySeen
        }

        switch stream {
        case .stdout:
            stdoutRemainder.append(data)
            let split = Self.splitLines(stdoutRemainder, maxLineBytes: maxLineBytes)
            stdoutRemainder = split.remainder
            for line in split.lines {
                if parseProtocol, violation == nil {
                    switch Self.decodeProtocolLine(line.text) {
                    case .ready(let info):
                        readySeen = true
                        readyInfo = info
                        state = .ready(info)
                        readyAction = info
                        parseProtocol = false
                        continue
                    case .violation(let message):
                        violation = message
                        parseProtocol = false
                        emitted.append(makeLogLine(stream: stream, text: line.text, truncated: line.truncated))
                        continue
                    case .notProtocol:
                        break
                    }
                }
                emitted.append(makeLogLine(stream: stream, text: line.text, truncated: line.truncated))
            }
        case .stderr:
            // stderr is human diagnostics only; it is never parsed as protocol.
            stderrRemainder.append(data)
            let split = Self.splitLines(stderrRemainder, maxLineBytes: maxLineBytes)
            stderrRemainder = split.remainder
            for line in split.lines {
                emitted.append(makeLogLine(stream: stream, text: line.text, truncated: line.truncated))
            }
        }

        appendAndTrimLocked(emitted, maxLogLines: maxLogLines)
        lock.unlock()

        for line in emitted {
            eventsContinuation.yield(.log(line))
        }

        if let violation {
            handleProtocolViolation(violation)
        } else if let info = readyAction {
            eventsContinuation.yield(.stateChanged(.ready(info)))
            commitRunning(info)
        }
    }

    /// Flushes a trailing partial line at EOF, then waits for both EOFs before finalizing.
    private func streamReachedEOF(_ stream: LogStream) {
        lock.lock()
        var emitted: [LogLine] = []
        let remainder: Data
        if stream == .stdout {
            remainder = stdoutRemainder
            stdoutRemainder = Data()
        } else {
            remainder = stderrRemainder
            stderrRemainder = Data()
        }
        if !remainder.isEmpty {
            emitted.append(makeLogLine(stream: stream, text: String(decoding: remainder, as: UTF8.self)))
        }
        eofStreams.insert(stream)
        appendAndTrimLocked(emitted, maxLogLines: policy.maxLogLines)
        let drained = eofStreams.count >= 2
        let terminated = pendingTermination != nil
        lock.unlock()

        for line in emitted {
            eventsContinuation.yield(.log(line))
        }
        if terminated, drained {
            finalizeIfPossible(force: false)
        }
    }

    private func makeLogLine(stream: LogStream, text: String, truncated: Bool = false) -> LogLine {
        logSequence += 1
        return LogLine(sequence: logSequence, stream: stream, text: text, truncated: truncated)
    }

    private func appendAndTrimLocked(_ lines: [LogLine], maxLogLines: Int) {
        logs.append(contentsOf: lines)
        if logs.count > maxLogLines {
            let overflow = logs.count - maxLogLines
            logs.removeFirst(overflow)
            droppedLogLines += overflow
        }
    }

    private func commitRunning(_ info: ReadyInfo) {
        lock.lock()
        guard case .ready = state else {
            lock.unlock()
            return
        }
        state = .running(info)
        let waiter = startWaiter
        startWaiter = nil
        lock.unlock()
        eventsContinuation.yield(.stateChanged(.running(info)))
        waiter?.resume(returning: info)
    }

    private func handleProtocolViolation(_ message: String) {
        lock.lock()
        guard case .starting = state else {
            lock.unlock()
            return
        }
        state = .failed(.protocolViolation(message))
        let waiter = startWaiter
        startWaiter = nil
        lock.unlock()
        eventsContinuation.yield(.stateChanged(.failed(.protocolViolation(message))))
        waiter?.resume(throwing: SupervisorError.failure(.protocolViolation(message)))
        Task { _ = await self.terminateChild(graceful: true) }
    }

    // MARK: - Termination

    private func processDidTerminate(_ reason: TerminationReason) {
        lock.lock()
        pendingTermination = reason
        let drained = eofStreams.count >= 2
        lock.unlock()

        if drained {
            finalizeIfPossible(force: false)
        } else {
            // Never leave the UI in `.running` because a pipe handler missed EOF; the normal
            // path is still "wait for both pipe EOFs", this is the bounded fallback.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.finalizeIfPossible(force: true)
            }
        }
    }

    private func finalizeIfPossible(force: Bool) {
        lock.lock()
        guard !finalized, pendingTermination != nil else {
            lock.unlock()
            return
        }
        if !force, eofStreams.count < 2 {
            lock.unlock()
            return
        }
        finalized = true

        let reason = pendingTermination ?? .unknown
        let ranFor = startedAt.map { policy.clock.now - $0 } ?? .zero
        let info = ExitInfo(
            terminationReason: reason,
            requestedStop: requestedStop,
            escalatedToSIGKILL: escalated,
            ranFor: ranFor,
            capturedStdoutBytes: stdoutBytes,
            capturedStderrBytes: stderrBytes
        )
        exitInfo = info
        child = nil

        let waiter = startWaiter
        startWaiter = nil
        let waiters = exitWaiters
        exitWaiters = []

        let previousState = state
        var newState = state
        switch state {
        case .starting:
            newState = requestedStop ? .stopped(info) : .failed(.exitedBeforeReady(info))
        case .ready, .running, .stopping:
            if requestedStop {
                newState = .stopped(info)
            } else if reason == .exited(0) {
                newState = .stopped(info)
            } else {
                newState = .failed(.exitedNonZero(info))
            }
        case .idle, .stopped, .failed:
            break
        }
        state = newState
        lock.unlock()

        if newState != previousState {
            eventsContinuation.yield(.stateChanged(newState))
        }

        if let waiter {
            switch newState {
            case .failed(let failure):
                waiter.resume(throwing: SupervisorError.failure(failure))
            case .stopped:
                waiter.resume(throwing: SupervisorError.stoppedBeforeReady)
            default:
                waiter.resume(throwing: SupervisorError.failure(.exitedBeforeReady(info)))
            }
        }
        for exitWaiter in waiters {
            exitWaiter.resume(info)
        }
    }

    /// SIGTERM → grace → SIGKILL → bounded wait. Never blocks the caller's actor.
    private func terminateChild(graceful: Bool) async -> ExitInfo? {
        let current = lock.withLock { () -> (info: ExitInfo?, child: (any LaunchedChildProcess)?) in
            (exitInfo, child)
        }
        if let info = current.info {
            return info
        }
        guard let child = current.child else {
            return nil
        }
        let running = child.isRunning

        if running {
            if graceful {
                child.terminate()
            } else {
                child.forceKill()
            }
        }

        if let info = await waitForExit(timeout: policy.terminationGracePeriod, escalate: graceful) {
            return info
        }
        if let info = currentExitInfo() {
            return info
        }
        // SIGKILL was delivered but the exit never arrived within the policy. Report the
        // truth rather than claiming a clean stop.
        let outcome = lock.withLock {
            () -> (waiter: CheckedContinuation<ReadyInfo, Error>?, waiters: [ExitWaiter], didFail: Bool) in
            guard !finalized else { return (nil, [], false) }
            finalized = true
            state = .failed(.killTimedOut)
            let waiter = startWaiter
            startWaiter = nil
            let waiters = exitWaiters
            exitWaiters = []
            return (waiter, waiters, true)
        }
        if outcome.didFail {
            eventsContinuation.yield(.stateChanged(.failed(.killTimedOut)))
            outcome.waiter?.resume(throwing: SupervisorError.failure(.killTimedOut))
            for exitWaiter in outcome.waiters {
                exitWaiter.resume(nil)
            }
        }
        return nil
    }

    private func waitForExit(timeout: Duration, escalate: Bool) async -> ExitInfo? {
        if let info = await raceExitWithTimeout(timeout) { return info }
        guard escalate else { return nil }
        let child = lock.withLock { () -> (any LaunchedChildProcess)? in
            escalated = true
            return self.child
        }
        child?.forceKill()
        return await raceExitWithTimeout(policy.killWaitTimeout)
    }

    /// Races "child exited" against a timeout without a task group. A task group waits for its
    /// losing child, and the exit waiter only completes when the process dies — a
    /// SIGTERM-ignoring child would deadlock the escalation path. A resume-once box avoids it.
    private func raceExitWithTimeout(_ timeout: Duration) async -> ExitInfo? {
        if let info = currentExitInfo() { return info }
        let waiter = ExitWaiter()
        return await withCheckedContinuation { (continuation: CheckedContinuation<ExitInfo?, Never>) in
            waiter.attach(continuation)
            lock.lock()
            if let existing = exitInfo {
                lock.unlock()
                waiter.resume(existing)
                return
            }
            exitWaiters.append(waiter)
            lock.unlock()
            Task { [policy] in
                try? await policy.sleeper.sleep(for: timeout)
                waiter.resume(nil)
            }
        }
    }

    private func currentExitInfo() -> ExitInfo? {
        lock.lock()
        defer { lock.unlock() }
        return exitInfo
    }

    private func fail(_ failure: SupervisorFailure) {
        lock.lock()
        if !finalized {
            finalized = true
            state = .failed(failure)
        }
        let waiter = startWaiter
        startWaiter = nil
        lock.unlock()
        eventsContinuation.yield(.stateChanged(.failed(failure)))
        waiter?.resume(throwing: SupervisorError.failure(failure))
    }

    private func resetForRestartLocked() {
        child = nil
        childPID = nil
        logs = []
        logSequence = 0
        droppedLogLines = 0
        stdoutBytes = 0
        stderrBytes = 0
        stdoutRemainder = Data()
        stderrRemainder = Data()
        readySeen = false
        readyInfo = nil
        requestedStop = false
        escalated = false
        startedAt = nil
        exitInfo = nil
        pendingTermination = nil
        eofStreams = []
        finalized = false
        launchInFlight = false
        launchSettledWaiters = []
        startWaiter = nil
        exitWaiters = []
    }

    // MARK: - Protocol decoding

    private enum ProtocolLineResult {
        case ready(ReadyInfo)
        case violation(String)
        case notProtocol
    }

    /// Only stdout lines with an `event` key are protocol; everything else stays a log line.
    /// A decoded `ReadyEvent` is honoured only when `ReadyEvent.isValid` (schema 0, event
    /// `ready`, port 1…65535). A pre-ready `ErrorEvent` and any unknown event are failures.
    private static func decodeProtocolLine(_ text: String) -> ProtocolLineResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else {
            return .notProtocol
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["event"] is String else {
            return .notProtocol
        }
        do {
            switch try JSONDecoder().decode(ProcessEvent.self, from: data) {
            case .ready(let ready):
                guard ready.isValid else {
                    if ready.schema != ReadyEvent.currentSchema {
                        return .violation("ready line has unsupported schema \(ready.schema)")
                    }
                    return .violation("ready line has invalid port \(ready.port)")
                }
                return .ready(
                    ReadyInfo(
                        port: ready.port,
                        pid: ready.pid.flatMap { Int32(exactly: $0) },
                        rawLine: trimmed
                    )
                )
            case .error(let error):
                return .violation(error.message)
            }
        } catch {
            return .violation("cannot decode appctl event: \(error); line: \(trimmed)")
        }
    }

    // MARK: - Line splitting (pure)

    private struct SplitResult {
        var lines: [(text: String, truncated: Bool)]
        var remainder: Data
    }

    private static func splitLines(_ buffer: Data, maxLineBytes: Int) -> SplitResult {
        var lines: [(text: String, truncated: Bool)] = []
        var remainder = buffer
        while let newlineIndex = remainder.firstIndex(of: 0x0A) {
            var lineData = remainder[remainder.startIndex..<newlineIndex]
            remainder = remainder[remainder.index(after: newlineIndex)...]
            if lineData.last == 0x0D {
                lineData = lineData.dropLast()
            }
            var truncated = false
            if lineData.count > maxLineBytes {
                lineData = lineData.prefix(maxLineBytes)
                truncated = true
            }
            lines.append((String(decoding: lineData, as: UTF8.self), truncated))
        }
        // A line that never ends must not grow the buffer without bound.
        if remainder.count > maxLineBytes {
            let prefix = remainder.prefix(maxLineBytes)
            lines.append((String(decoding: prefix, as: UTF8.self), true))
            remainder = Data()
        }
        return SplitResult(lines: lines, remainder: Data(remainder))
    }

    /// Resume-once box so the exit path and the timeout path can race safely.
    private final class ExitWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ExitInfo?, Never>?

        func attach(_ continuation: CheckedContinuation<ExitInfo?, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ info: ExitInfo?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: info)
        }
    }
}
