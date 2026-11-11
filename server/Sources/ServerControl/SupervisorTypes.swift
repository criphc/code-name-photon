import Foundation

/// Everything needed to spawn the `appctl serve` child. Deliberately dumb: no shell, no
/// implicit environment merging — `Process` replaces the inherited environment, so the
/// caller merges what the child may see (ADR-0010 §1).
public struct LaunchConfiguration: Sendable, Equatable {
    /// Absolute path; `Process` does not search `PATH`.
    public var executable: URL
    public var arguments: [String]
    /// Not inherited; the caller merges the environment explicitly.
    public var environment: [String: String]
    public var currentDirectory: URL?

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

/// The ready handshake accepted by the supervisor: the port the child reports it is serving
/// on and the informational PID from the ready line (the supervisor's own PID is authoritative).
public struct ReadyInfo: Sendable, Equatable {
    public var port: Int
    public var pid: Int32?
    /// The exact ready line, for diagnostics.
    public var rawLine: String

    public init(port: Int, pid: Int32?, rawLine: String) {
        self.port = port
        self.pid = pid
        self.rawLine = rawLine
    }
}

public enum LogStream: String, Sendable, Hashable {
    case stdout
    case stderr
}

public struct LogLine: Sendable, Equatable {
    public var sequence: Int
    public var stream: LogStream
    public var text: String
    /// The line was longer than `SupervisionPolicy.maxLineBytes` and got clamped.
    public var truncated: Bool

    public init(sequence: Int, stream: LogStream, text: String, truncated: Bool = false) {
        self.sequence = sequence
        self.stream = stream
        self.text = text
        self.truncated = truncated
    }
}

/// Why the child is gone. Exit code and signal stay separate so `128 + signal` guesses never
/// leak into the contract.
public enum TerminationReason: Sendable, Equatable {
    case exited(Int32)
    case uncaughtSignal(Int32)
    case unknown

    public var exitCode: Int32? {
        if case .exited(let code) = self { return code }
        return nil
    }

    public var signal: Int32? {
        if case .uncaughtSignal(let signal) = self { return signal }
        return nil
    }
}

/// Terminal facts about the child. `ranFor` is measured with the policy's injectable clock.
public struct ExitInfo: Sendable, Equatable {
    public var terminationReason: TerminationReason
    /// True when the supervisor asked the child to stop, so a nonzero status is expected.
    public var requestedStop: Bool
    /// SIGTERM was ignored and SIGKILL was required.
    public var escalatedToSIGKILL: Bool
    public var ranFor: Duration
    public var capturedStdoutBytes: Int
    public var capturedStderrBytes: Int

    public init(
        terminationReason: TerminationReason,
        requestedStop: Bool,
        escalatedToSIGKILL: Bool,
        ranFor: Duration,
        capturedStdoutBytes: Int,
        capturedStderrBytes: Int
    ) {
        self.terminationReason = terminationReason
        self.requestedStop = requestedStop
        self.escalatedToSIGKILL = escalatedToSIGKILL
        self.ranFor = ranFor
        self.capturedStdoutBytes = capturedStdoutBytes
        self.capturedStderrBytes = capturedStderrBytes
    }
}

/// Failure taxonomy. Failures that carry `ExitInfo` keep the exit code and reason.
public enum SupervisorFailure: Sendable, Equatable {
    case spawnFailed(String)
    case readyTimeout(Duration)
    case exitedBeforeReady(ExitInfo)
    case exitedNonZero(ExitInfo)
    case protocolViolation(String)
    case killTimedOut
}

/// The explicit process state machine (ADR-0010 §3):
/// `idle → starting → ready(ReadyInfo) → running(ReadyInfo) → stopping → stopped(ExitInfo)`,
/// with `failed(SupervisorFailure)` reachable from any state.
public enum SupervisorState: Sendable, Equatable {
    case idle
    case starting
    case ready(ReadyInfo)
    case running(ReadyInfo)
    case stopping
    case stopped(ExitInfo)
    case failed(SupervisorFailure)

    public var readyInfo: ReadyInfo? {
        switch self {
        case .ready(let info), .running(let info): return info
        default: return nil
        }
    }

    public var exitInfo: ExitInfo? {
        switch self {
        case .stopped(let info): return info
        case .failed(.exitedBeforeReady(let info)), .failed(.exitedNonZero(let info)): return info
        default: return nil
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .stopped, .failed: return true
        default: return false
        }
    }
}

public enum SupervisorEvent: Sendable, Equatable {
    case stateChanged(SupervisorState)
    case log(LogLine)
}

public enum SupervisorError: Error, Equatable {
    case failure(SupervisorFailure)
    case stoppedBeforeReady
    case alreadyStarted
}

extension SupervisorError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .failure(let failure): return "SupervisorError.failure(\(failure))"
        case .stoppedBeforeReady: return "SupervisorError.stoppedBeforeReady"
        case .alreadyStarted: return "SupervisorError.alreadyStarted"
        }
    }
}

/// Non-blocking view of the supervisor for UI code. `logs` is the bounded tail; the byte
/// counters are exact for the whole run.
public struct SupervisorSnapshot: Sendable, Equatable {
    public var state: SupervisorState
    public var pid: Int32?
    public var isRunning: Bool
    public var logs: [LogLine]
    public var capturedStdoutBytes: Int
    public var capturedStderrBytes: Int
    public var droppedLogLines: Int
    public var exitInfo: ExitInfo?

    public init(
        state: SupervisorState,
        pid: Int32?,
        isRunning: Bool,
        logs: [LogLine],
        capturedStdoutBytes: Int,
        capturedStderrBytes: Int,
        droppedLogLines: Int,
        exitInfo: ExitInfo?
    ) {
        self.state = state
        self.pid = pid
        self.isRunning = isRunning
        self.logs = logs
        self.capturedStdoutBytes = capturedStdoutBytes
        self.capturedStderrBytes = capturedStderrBytes
        self.droppedLogLines = droppedLogLines
        self.exitInfo = exitInfo
    }
}
