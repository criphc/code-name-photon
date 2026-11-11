import Foundation

/// One banner's worth of user-facing state.
///
/// Shared by `SessionModel` (connection / batch-list failures) and `JudgeModel` (prepare, load,
/// POST and 409 failures), so the app can show either banner with the same view. The wording and
/// the recovery flags are the M3 contract (docs/reference/client.md, state and errors) and are produced by
/// the models, never by the UI.
public struct Notice: Identifiable, Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        case info
        case warning
        case error
    }

    public let id = UUID()
    public var message: String
    public var severity: Severity = .info
    /// 409 `source_changed`: the banner is the re-judge instruction and cannot be dismissed.
    public var sourceChanged = false
    public var canDismiss = true
    /// `true` when the owning model's `retry()` knows which step to repeat.
    public var canRetry = false

    public init(
        message: String,
        severity: Severity = .info,
        sourceChanged: Bool = false,
        canDismiss: Bool = true,
        canRetry: Bool = false
    ) {
        self.message = message
        self.severity = severity
        self.sourceChanged = sourceChanged
        self.canDismiss = canDismiss
        self.canRetry = canRetry
    }
}
