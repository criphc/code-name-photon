import Foundation

/// A started child, reduced to what the supervisor needs: identity, liveness and the two
/// stop signals. Implemented for `Process` by `SystemProcessLauncher` and for tests by
/// `ServerTestSupport.FakeLaunchedProcess`.
public protocol LaunchedChildProcess: AnyObject, Sendable {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }

    /// `SIGTERM` — a termination request, not an RPC shutdown (ADR-0010 §3).
    func terminate()
    /// `SIGKILL` — the escalation after `terminationGracePeriod` expired.
    func forceKill()
}

/// The injection point that makes `ChildProcessSupervisor` headless-testable: the supervisor
/// never touches `Process` or pipes itself.
///
/// Handler contract:
/// - `onStdout`/`onStderr` receive chunks on arbitrary threads; an empty `Data` means EOF.
/// - `onExit` fires at most once, possibly before the pipe EOFs (the supervisor tracks both).
/// - Handlers may fire concurrently and must not be assumed to run on the caller's thread.
public protocol ChildProcessLaunching: Sendable {
    func launch(
        configuration: LaunchConfiguration,
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (TerminationReason) -> Void
    ) throws -> any LaunchedChildProcess
}

/// The production launcher: `Process` + one pipe per stream, drained on their own queues.
public struct SystemProcessLauncher: ChildProcessLaunching {
    public init() {}

    public func launch(
        configuration: LaunchConfiguration,
        onStdout: @escaping @Sendable (Data) -> Void,
        onStderr: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (TerminationReason) -> Void
    ) throws -> any LaunchedChildProcess {
        let process = Process()
        process.executableURL = configuration.executable
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        if let directory = configuration.currentDirectory {
            process.currentDirectoryURL = directory
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Never let a child that reads stdin inherit the host app's terminal.
        process.standardInput = FileHandle.nullDevice

        process.terminationHandler = { finished in
            onExit(Self.terminationReason(for: finished))
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            onStdout(data)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            onStderr(data)
        }

        try process.run()
        return SystemLaunchedProcess(process: process)
    }

    private static func terminationReason(for process: Process) -> TerminationReason {
        switch process.terminationReason {
        case .exit:
            return .exited(process.terminationStatus)
        case .uncaughtSignal:
            return .uncaughtSignal(process.terminationStatus)
        @unknown default:
            return .unknown
        }
    }
}

private final class SystemLaunchedProcess: LaunchedChildProcess, @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var processIdentifier: Int32 { process.processIdentifier }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func forceKill() {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }
}
