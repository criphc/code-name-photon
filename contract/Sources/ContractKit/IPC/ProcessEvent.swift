import Foundation

/// The machine-readable readiness event `appctl serve` writes to stdout after it starts serving.
///
/// Exactly one line, line-delimited JSON; `stderr` is never parsed (ADR-0010):
/// `{"schema":0,"event":"ready","port":8787,"pid":123}`
public struct ReadyEvent: Codable, Equatable, Sendable {
    public static let currentSchema = 0
    public static let eventName = "ready"

    public let schema: Int
    public let event: String
    public let port: Int
    /// Informational; the supervisor uses `Process.processIdentifier` as the authority.
    public let pid: Int?

    public init(port: Int, pid: Int? = nil, schema: Int = ReadyEvent.currentSchema) {
        self.schema = schema
        self.event = ReadyEvent.eventName
        self.port = port
        self.pid = pid
    }

    /// True when the line is a ready event this version understands.
    public var isValid: Bool {
        schema == ReadyEvent.currentSchema
            && event == ReadyEvent.eventName
            && (1...65535).contains(port)
    }
}

/// The pre-ready failure event `appctl serve` may write to stdout:
/// `{"schema":0,"event":"error","message":"…"}`
public struct ErrorEvent: Codable, Equatable, Sendable {
    public static let currentSchema = 0
    public static let eventName = "error"

    public let schema: Int
    public let event: String
    public let message: String

    public init(message: String, schema: Int = ErrorEvent.currentSchema) {
        self.schema = schema
        self.event = ErrorEvent.eventName
        self.message = message
    }
}

/// The appctl↔GUI stdout protocol: either the readiness handshake or a pre-ready failure.
///
/// Any other stdout line is a log line (ADR-0010); this type only covers the events that change
/// the process state, so it stays small and versioned.
public enum ProcessEvent: Codable, Equatable, Sendable {
    case ready(ReadyEvent)
    case error(ErrorEvent)

    private enum CodingKeys: String, CodingKey {
        case event
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let event = try container.decode(String.self, forKey: .event)
        switch event {
        case ReadyEvent.eventName:
            self = .ready(try ReadyEvent(from: decoder))
        case ErrorEvent.eventName:
            self = .error(try ErrorEvent(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .event,
                in: container,
                debugDescription: "unknown appctl event '\(event)'"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .ready(let ready):
            try ready.encode(to: encoder)
        case .error(let error):
            try error.encode(to: encoder)
        }
    }
}
