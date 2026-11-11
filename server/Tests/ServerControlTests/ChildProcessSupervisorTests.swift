import Foundation
import ServerControl
import ServerTestSupport
import Testing

private let appctlExecutable = URL(fileURLWithPath: "/usr/bin/appctl")

/// One malformed/hostile pre-ready stdout line the supervisor must reject.
struct InvalidProtocolLine: Sendable, CustomStringConvertible {
    let name: String
    let line: String
    let expectedFragment: String

    var description: String { name }
}

@Suite("ChildProcessSupervisor")
struct ChildProcessSupervisorTests {
    // MARK: - Helpers

    private func makeSupervisor(
        policy: SupervisionPolicy = SupervisionPolicy(),
        terminationBehavior: FakeLaunchedProcess.TerminationBehavior = .exitOnTerminate(.exited(0))
    ) -> (supervisor: ChildProcessSupervisor, launcher: FakeProcessLauncher) {
        let launcher = FakeProcessLauncher(defaultTerminationBehavior: terminationBehavior)
        let supervisor = ChildProcessSupervisor(
            launch: LaunchConfiguration(
                executable: appctlExecutable,
                arguments: ["serve", "--port", "0"],
                environment: ["NO_COLOR": "1"]
            ),
            policy: policy,
            launcher: launcher
        )
        return (supervisor, launcher)
    }

    /// Starts the supervisor, waits for the fake launch, optionally emits the ready line, and
    /// returns once `start()` produced its `ReadyInfo`.
    private func startSupervisor(
        _ supervisor: ChildProcessSupervisor,
        launcher: FakeProcessLauncher,
        readyLine: String
    ) async throws -> (process: FakeLaunchedProcess, ready: ReadyInfo) {
        let start = Task { try await supervisor.start() }
        let process = await launcher.nextLaunched()
        process.emitStdoutLine(readyLine)
        let ready = try await start.value
        return (process, ready)
    }

    private func readyLine(port: Int, pid: Int? = nil) -> String {
        if let pid {
            return "{\"schema\":0,\"event\":\"ready\",\"port\":\(port),\"pid\":\(pid)}"
        }
        return "{\"schema\":0,\"event\":\"ready\",\"port\":\(port)}"
    }

    /// Awaits `start()` and returns its `SupervisorError` (or records an unexpected outcome).
    private func startError(_ task: Task<ReadyInfo, Error>) async -> SupervisorError? {
        do {
            _ = try await task.value
            Issue.record("start() was expected to throw")
            return nil
        } catch let error as SupervisorError {
            return error
        } catch {
            Issue.record("unexpected error: \(error)")
            return nil
        }
    }

    private func makeLargePayload() -> Data {
        // 1024 lines × 1024 bytes (1023 characters + newline) = exactly 1 MiB.
        let line = String(repeating: "x", count: 1_023) + "\n"
        return Data(String(repeating: line, count: 1_024).utf8)
    }

    // MARK: - Ready handshake

    @Test func readyLineIsParsedAndStatesAdvanceInOrder() async throws {
        let (supervisor, launcher) = makeSupervisor()
        let recorder = SupervisorEventRecorder(stream: supervisor.events)
        let start = Task { try await supervisor.start() }
        let process = await launcher.nextLaunched()
        let line = readyLine(port: 8787, pid: 42)
        process.emitStdoutLine(line)

        let info = try await start.value
        #expect(info == ReadyInfo(port: 8787, pid: 42, rawLine: line))

        await recorder.waitForStateChangeCount(3)
        #expect(recorder.states == [.starting, .ready(info), .running(info)])
        #expect(supervisor.snapshot.state == .running(info))
        #expect(supervisor.snapshot.pid == process.processIdentifier)

        let configuration = try #require(launcher.launchedConfigurations.first)
        #expect(configuration.executable == appctlExecutable)
        #expect(configuration.arguments == ["serve", "--port", "0"])
        #expect(configuration.environment == ["NO_COLOR": "1"])
    }

    @Test func readyTimeoutFailsWithoutRealWaiting() async throws {
        let policy = SupervisionPolicy(readyTimeout: .seconds(7), sleeper: ImmediateSleeper())
        let (supervisor, launcher) = makeSupervisor(policy: policy)
        let start = Task { try await supervisor.start() }
        _ = await launcher.nextLaunched()

        let error = await startError(start)
        #expect(error == .failure(.readyTimeout(.seconds(7))))
        #expect(supervisor.snapshot.state == .failed(.readyTimeout(.seconds(7))))
    }

    // MARK: - Exits

    @Test func nonzeroExitAfterReadyIsCaptured() async throws {
        let clock = FakeSupervisionClock()
        let (supervisor, launcher) = makeSupervisor(policy: SupervisionPolicy(clock: clock))
        let line = readyLine(port: 8787)
        let (process, _) = try await startSupervisor(supervisor, launcher: launcher, readyLine: line)

        clock.advance(by: .seconds(2))
        process.exit(.exited(3))

        guard case .failed(.exitedNonZero(let info)) = supervisor.snapshot.state else {
            Issue.record("expected failed(.exitedNonZero), got \(supervisor.snapshot.state)")
            return
        }
        #expect(info.terminationReason == .exited(3))
        #expect(info.requestedStop == false)
        #expect(info.escalatedToSIGKILL == false)
        #expect(info.ranFor == .seconds(2))
        #expect(info.capturedStdoutBytes == Data((line + "\n").utf8).count)
        #expect(info.capturedStderrBytes == 0)
    }

    @Test func exitBeforeReadyFailsWithExitedBeforeReady() async throws {
        let (supervisor, launcher) = makeSupervisor()
        let start = Task { try await supervisor.start() }
        let process = await launcher.nextLaunched()
        process.exit(.exited(1))

        let error = await startError(start)
        guard case .failure(.exitedBeforeReady(let info))? = error else {
            Issue.record("expected failed(.exitedBeforeReady), got \(String(describing: error))")
            return
        }
        #expect(info.terminationReason == .exited(1))
        #expect(info.requestedStop == false)
        #expect(supervisor.snapshot.state == .failed(.exitedBeforeReady(info)))
    }

    @Test func spawnFailureIsCaptured() async throws {
        let (supervisor, launcher) = makeSupervisor()
        launcher.failNextLaunch(with: "no such file")

        let start = Task { try await supervisor.start() }
        let error = await startError(start)
        guard case .failure(.spawnFailed(let message))? = error else {
            Issue.record("expected failed(.spawnFailed), got \(String(describing: error))")
            return
        }
        #expect(message.contains("no such file"))
        #expect(supervisor.snapshot.state == .failed(.spawnFailed(message)))
    }

    // MARK: - Stopping

    @Test func gracefulStopSendsSIGTERMAndStopsWithExitZero() async throws {
        let (supervisor, launcher) = makeSupervisor()
        let (process, _) = try await startSupervisor(
            supervisor,
            launcher: launcher,
            readyLine: readyLine(port: 8787)
        )

        let stopResult = await supervisor.stop()
        let info = try #require(stopResult)
        #expect(info.terminationReason == .exited(0))
        #expect(info.requestedStop)
        #expect(info.escalatedToSIGKILL == false)
        #expect(supervisor.snapshot.state == .stopped(info))
        #expect(supervisor.snapshot.isRunning == false)
        #expect(process.terminateCount == 1)
        #expect(process.forceKillCount == 0)
    }

    @Test func sigtermIgnoringChildIsEscalatedToSIGKILL() async throws {
        let sleeper = GateSleeper()
        let policy = SupervisionPolicy(
            terminationGracePeriod: .seconds(3),
            killWaitTimeout: .seconds(3),
            sleeper: sleeper
        )
        let (supervisor, launcher) = makeSupervisor(
            policy: policy,
            terminationBehavior: .ignoreTerminate
        )
        let (process, _) = try await startSupervisor(
            supervisor,
            launcher: launcher,
            readyLine: readyLine(port: 8787)
        )

        // Readiness is settled; now let every timeout elapse instantly so the grace period
        // escalates to SIGKILL without a wall-clock wait.
        sleeper.openGate()
        let stopResult = await supervisor.stop()
        let info = try #require(stopResult)
        #expect(info.terminationReason == .uncaughtSignal(9))
        #expect(info.escalatedToSIGKILL)
        #expect(info.requestedStop)
        #expect(supervisor.snapshot.state == .stopped(info))
        #expect(process.terminateCount == 1)
        #expect(process.forceKillCount == 1)
    }

    @Test func requestStopOnlySendsSIGTERMAndReturnsImmediately() async throws {
        let (supervisor, launcher) = makeSupervisor()
        let (process, _) = try await startSupervisor(
            supervisor,
            launcher: launcher,
            readyLine: readyLine(port: 8787)
        )

        let pid = supervisor.requestStop()
        #expect(pid == process.processIdentifier)
        #expect(process.receivedTerminate)
        #expect(process.receivedForceKill == false)

        let exitInfo = supervisor.snapshot.exitInfo
        let info = try #require(exitInfo)
        #expect(info.requestedStop)
        #expect(info.terminationReason == .exited(0))
        #expect(supervisor.snapshot.state == .stopped(info))
    }

    @Test func stopBeforeReadyEndsStoppedAndStartThrows() async throws {
        let (supervisor, launcher) = makeSupervisor()
        let start = Task { try await supervisor.start() }
        _ = await launcher.nextLaunched()

        let stopResult = await supervisor.stop()
        let info = try #require(stopResult)
        #expect(info.requestedStop)
        #expect(supervisor.snapshot.state == .stopped(info))

        let error = await startError(start)
        #expect(error == .stoppedBeforeReady)
    }

    // MARK: - Log capture and protocol hardening

    @Test func stdoutAndStderrAreCapturedAndStderrIsNeverProtocol() async throws {
        let (supervisor, launcher) = makeSupervisor()
        let recorder = SupervisorEventRecorder(stream: supervisor.events)
        let start = Task { try await supervisor.start() }
        let process = await launcher.nextLaunched()
        // A ready-shaped stderr line must stay a log line; only stdout is the machine channel.
        let decoyReadyLine = readyLine(port: 1111)
        process.emitStderrLine(decoyReadyLine)
        let realReadyLine = readyLine(port: 8787)
        process.emitStdoutLine(realReadyLine)

        let info = try await start.value
        #expect(info.port == 8787)

        process.emitStdoutLine("serving")
        process.emitStderrLine("warning")
        await recorder.waitForLogCount(3)

        #expect(recorder.logs.map(\.stream) == [.stderr, .stdout, .stderr])
        #expect(recorder.logs.map(\.text) == [decoyReadyLine, "serving", "warning"])
        #expect(recorder.logs.map(\.sequence) == [1, 2, 3])
        #expect(recorder.states == [.starting, .ready(info), .running(info)])

        let snapshot = supervisor.snapshot
        #expect(
            snapshot.capturedStdoutBytes
                == Data((realReadyLine + "\nserving\n").utf8).count
        )
        #expect(snapshot.capturedStderrBytes == Data((decoyReadyLine + "\nwarning\n").utf8).count)
    }

    @Test(arguments: [
        InvalidProtocolLine(
            name: "unsupported schema",
            line: "{\"schema\":1,\"event\":\"ready\",\"port\":8787}",
            expectedFragment: "schema"
        ),
        InvalidProtocolLine(
            name: "invalid port",
            line: "{\"schema\":0,\"event\":\"ready\",\"port\":0}",
            expectedFragment: "port"
        ),
        InvalidProtocolLine(
            name: "unknown event",
            line: "{\"schema\":0,\"event\":\"status\"}",
            expectedFragment: "status"
        ),
        InvalidProtocolLine(
            name: "pre-ready error event",
            line: "{\"schema\":0,\"event\":\"error\",\"message\":\"boom\"}",
            expectedFragment: "boom"
        ),
    ])
    func invalidProtocolLineBeforeReadyFails(_ testCase: InvalidProtocolLine) async throws {
        let (supervisor, launcher) = makeSupervisor()
        let start = Task { try await supervisor.start() }
        let process = await launcher.nextLaunched()
        process.emitStdoutLine(testCase.line)

        let error = await startError(start)
        guard case .failure(.protocolViolation(let message))? = error else {
            Issue.record("expected failed(.protocolViolation), got \(String(describing: error))")
            return
        }
        #expect(message.contains(testCase.expectedFragment))
        #expect(supervisor.snapshot.state == .failed(.protocolViolation(message)))
    }

    @Test func largeStdoutAndStderrAreFullyCapturedWithoutDeadlock() async throws {
        let policy = SupervisionPolicy(maxLogLines: 4_096)
        let (supervisor, launcher) = makeSupervisor(policy: policy)
        let line = readyLine(port: 8787)
        let (process, _) = try await startSupervisor(supervisor, launcher: launcher, readyLine: line)

        let stdoutPayload = makeLargePayload()
        let stderrPayload = makeLargePayload()
        process.emitStdout(stdoutPayload)
        process.emitStderr(stderrPayload)
        process.exit(.exited(0))

        let snapshot = supervisor.snapshot
        #expect(snapshot.capturedStdoutBytes == Data((line + "\n").utf8).count + stdoutPayload.count)
        #expect(snapshot.capturedStderrBytes == stderrPayload.count)
        #expect(snapshot.droppedLogLines == 0)
        #expect(snapshot.logs.count == 2_048)
        #expect(snapshot.logs.first?.stream == .stdout)
        #expect(snapshot.logs.last?.stream == .stderr)
        #expect(snapshot.logs.last?.text.count == 1_023)
        #expect(snapshot.logs.map(\.sequence).first == 1)
        #expect(snapshot.logs.map(\.sequence).last == 2_048)
        guard case .stopped(let info) = snapshot.state else {
            Issue.record("expected stopped, got \(snapshot.state)")
            return
        }
        #expect(info.terminationReason == .exited(0))
    }

    // MARK: - Restart

    @Test func startIsRestartableAfterStop() async throws {
        let (supervisor, launcher) = makeSupervisor()
        let (firstProcess, _) = try await startSupervisor(
            supervisor,
            launcher: launcher,
            readyLine: readyLine(port: 1000)
        )
        _ = await supervisor.stop()
        #expect(firstProcess.isRunning == false)

        let secondLine = readyLine(port: 2000)
        let start = Task { try await supervisor.start() }
        let secondProcess = await launcher.nextLaunched()
        secondProcess.emitStdoutLine(secondLine)
        let info = try await start.value

        #expect(info.port == 2000)
        #expect(supervisor.snapshot.state == .running(info))
        #expect(supervisor.snapshot.capturedStdoutBytes == Data((secondLine + "\n").utf8).count)
        #expect(supervisor.snapshot.logs.isEmpty)
    }
}
