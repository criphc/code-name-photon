//
//  SessionModel.swift
//  ClientModel
//
//  The connection half of the M3 judge client: connection settings, the transport handle, the
//  health probe and the batch list. It owns no judging state — see `JudgeModel` for the selected
//  item, the decoded base, the recipe draft and the POST flow.
//
//  State machine and wording are the M3 ones (docs/reference/client.md, state and errors). Every network
//  call, decode and shader input stays in `PhotonClient`/`BasePNG`; this model only decides which
//  one runs, when, and what the UI shows afterwards. Calls are `async` so the main actor is the
//  only writer.
//

import Foundation
import Observation
import ClientKit
import ContractKit

/// Connection settings, `/api/health`, the batch list and the connection/refresh error flow.
@MainActor
@Observable
public final class SessionModel {

    // MARK: - Phase

    /// The session-level screen state. The judge's own phases (`loading`/`judging`/…) are
    /// separate; when the judge is showing a base, it takes priority over `session.phase`
    /// (same rule as the M3 detail column).
    public enum Phase: Equatable {
        /// No usable client: the connection settings are the only thing on screen.
        case unconfigured
        /// `/api/health` probe in flight.
        case connecting
        /// Client accepted and the batch listed.
        case connected
        /// The last connection or batch-list request failed; the notice carries the message and
        /// `retry()` knows how to repeat the step. When the judge already holds a base its own
        /// phase takes priority (the M3 `isShowingJudge` rule), so this is the error screen only
        /// when there is nothing left to judge.
        case error
    }

    /// The transport constructor seam: production builds `PhotonClient`, tests return a fake.
    public typealias ClientFactory = (PhotonClient.Configuration) throws -> any PhotonClientProtocol

    // MARK: - Connection settings

    /// M3 default port (`appctl serve` default).
    public nonisolated static let defaultPort = "8787"

    public var host: String {
        didSet { persistSettings() }
    }

    public var port: String {
        didSet { persistSettings() }
    }

    public var token: String {
        didSet { persistSettings() }
    }

    /// Trimmed enough to build a client; the Connect button is disabled until this holds.
    public var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsedPort != nil
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var parsedPort: Int? {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...65535).contains(value) else { return nil }
        return value
    }

    // MARK: - Server / library

    public private(set) var client: (any PhotonClientProtocol)?
    public private(set) var health: HealthResponse?
    public private(set) var phase: Phase = .unconfigured
    public private(set) var isRefreshing = false
    public private(set) var items: [ItemSummary] = []

    /// 胶片条的缩略图缓存。由视图用 `.task(id:)` 驱动补齐，会话本身不主动下载。
    public let thumbnails = ThumbnailCache()

    /// The banner for a failed connect or batch refresh.
    public private(set) var notice: Notice?

    // MARK: - Retry

    private enum FailureStep: Equatable {
        case connect
        case refresh
    }

    private var failureStep: FailureStep?

    // MARK: - Hooks for the judge

    /// `JudgeModel` installs these in its initializer so a session-level refresh keeps the judge's
    /// selection in sync. They are internal: the app observes `items`/`phase` directly through
    /// Observation. All callbacks are invoked on the main actor and must not retain the judge.
    @ObservationIgnored
    internal var onItemsRefreshed: (([ItemSummary]) -> Void)?
    @ObservationIgnored
    internal var onRefreshFailed: (() -> Void)?
    /// The client is gone (disconnect, failed connect, 401): the judge must drop its review.
    @ObservationIgnored
    internal var onInvalidated: (() -> Void)?

    /// A base load or recipe POST is in flight; `connect()` must not tear the client down
    /// underneath it (the M3 guard also covered the judge's `loading`/`posting` phases).
    @ObservationIgnored
    internal var judgeIsBusy = false

    // MARK: - Stored collaborators

    @ObservationIgnored
    private let settingsStore: PhotonSettingsStore
    @ObservationIgnored
    private let makeClient: ClientFactory

    // MARK: - Init

    public init(
        settingsStore: PhotonSettingsStore = UserDefaultsSettingsStore(),
        makeClient: @escaping ClientFactory = { try PhotonClient(configuration: $0) }
    ) {
        self.settingsStore = settingsStore
        self.makeClient = makeClient
        let saved = settingsStore.load()
        // Property observers do not run during init, so this does not write the defaults back.
        host = saved?.host ?? ""
        port = saved?.port ?? Self.defaultPort
        token = saved?.token ?? ""
    }

    // MARK: - Derived state

    public var isConnected: Bool { client != nil }

    // MARK: - Connection

    /// App launch: reconnect silently when settings from a previous session exist.
    public func start() async {
        guard phase == .unconfigured, client == nil else { return }
        guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        await connect()
    }

    /// `unconfigured → connecting → connected`; a failed probe returns to the settings.
    public func connect() async {
        guard phase != .connecting, !judgeIsBusy else { return }

        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            notice = Notice(message: "Enter the Mac's LAN address first.", severity: .warning)
            phase = .unconfigured
            return
        }
        guard let portValue = parsedPort else {
            notice = Notice(message: "The port must be a number between 1 and 65535.", severity: .warning)
            phase = .unconfigured
            return
        }
        guard !trimmedToken.isEmpty else {
            notice = Notice(message: "Enter the bearer token printed by `appctl serve`.", severity: .warning)
            phase = .unconfigured
            return
        }

        phase = .connecting
        notice = nil
        failureStep = nil
        persistSettings()

        do {
            let configuration = PhotonClient.Configuration(
                host: trimmedHost,
                port: portValue,
                token: trimmedToken
            )
            let client = try makeClient(configuration)
            self.client = client
            let health = try await client.health()
            self.health = health
            phase = .connected
            await refreshItems()
        } catch {
            client = nil
            health = nil
            // A dead connection cannot POST, so a stale canvas would only offer a Done button that
            // silently does nothing; go back to the settings with the error on screen.
            phase = .unconfigured
            onInvalidated?()
            handleError(error, during: .connect)
        }
    }

    public func disconnect() {
        client = nil
        health = nil
        items = []
        phase = .unconfigured
        notice = nil
        isRefreshing = false
        failureStep = nil
        onInvalidated?()
    }

    // MARK: - Library

    /// `GET /api/items`; keeps the selection when the item is still in the batch (the judge
    /// installs the reconciliation hook). Returns `false` when the list request failed.
    @discardableResult
    public func refreshItems() async -> Bool {
        guard let client else {
            phase = .unconfigured
            return false
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fetched = try await client.listItems()
            items = fetched
            phase = .connected
            onItemsRefreshed?(fetched)
            return true
        } catch {
            handleError(error, during: .refresh)
            // A 401 already invalidated the client and reset the judge; do not push a judge phase
            // on top of the freshly reset judge.
            if self.client != nil {
                onRefreshFailed?()
            }
            return false
        }
    }

    // MARK: - Retry

    /// Repeat the last failed session step. The judge keeps its own `retry()` for its steps.
    public func retry() async {
        let step = failureStep
        failureStep = nil
        notice = nil
        switch step {
        case .connect:
            await connect()
        case .refresh:
            await refreshItems()
        case .none:
            if client == nil {
                await connect()
            } else {
                await refreshItems()
            }
        }
    }

    // MARK: - Banners

    public func dismissNotice() {
        guard notice?.canDismiss == true else { return }
        notice = nil
    }

    // MARK: - Internal operations used by `JudgeModel`

    /// Replaces an item in the batch after `prepare`/`POST` returned a fresher server state.
    internal func updateItem(_ item: ItemSummary) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        }
    }

    /// Clears the banner without the `canDismiss` guard: the judge clears the whole screen on
    /// select/post/retry, which is what the unified M3 notice did.
    internal func clearNotice() {
        notice = nil
    }

    /// A judge operation was attempted with no client (the M3 model went back to the settings).
    internal func markUnconfigured() {
        phase = .unconfigured
    }

    /// 401 from any judge step: back to the settings, re-enter the token, drop everything the
    /// judge held. Called by `JudgeModel`; the judge itself is reset through `onInvalidated`.
    internal func handleUnauthorized(message: String) {
        client = nil
        health = nil
        items = []
        phase = .unconfigured
        failureStep = nil
        onInvalidated?()
        notice = Notice(message: message, severity: .error, canDismiss: true)
    }

    internal func setJudgeBusy(_ busy: Bool) {
        judgeIsBusy = busy
    }

    // MARK: - Error mapping (docs/reference/client.md, state and errors)

    private func handleError(_ error: Error, during step: FailureStep) {
        failureStep = step

        if let clientError = error as? ClientError {
            // 401: back to the settings; the token is the thing that must change.
            if clientError.needsReconnect {
                handleUnauthorized(message: clientError.userMessage)
                return
            }

            // 404: the item left the batch. The batch refresh itself is the recovery step.
            if clientError.shouldRefreshList {
                phase = .error
                notice = Notice(
                    message: clientError.userMessage,
                    severity: .warning,
                    canDismiss: true,
                    canRetry: true
                )
                failureStep = .refresh
                return
            }

            // 422 / invalid_recipe / bad_request / prepare_failed / internal_error / network.
            notice = Notice(
                message: clientError.userMessage,
                severity: .error,
                canDismiss: true,
                canRetry: true
            )
            applyFailurePhase(for: step)
            return
        }

        // Non-transport errors (client construction).
        notice = Notice(
            message: Self.message(for: error),
            severity: .error,
            canDismiss: true,
            canRetry: true
        )
        applyFailurePhase(for: step)
    }

    private func applyFailurePhase(for step: FailureStep) {
        // The judge decides whether its review survives a failed refresh; at the session level a
        // failed request means there is no connected batch to show.
        switch step {
        case .connect, .refresh:
            phase = .error
        }
    }

    // MARK: - Settings persistence

    private func persistSettings() {
        settingsStore.save(PhotonConnectionSettings(host: host, port: port, token: token))
    }

    // MARK: - Messages

    private static func message(for error: Error) -> String {
        if let clientError = error as? ClientError {
            return clientError.userMessage
        }
        if let photonError = error as? PhotonError {
            return photonError.description
        }
        return (error as NSError).localizedDescription
    }
}
