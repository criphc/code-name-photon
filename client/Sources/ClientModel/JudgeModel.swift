//
//  JudgeModel.swift
//  ClientModel
//
//  The judging half of the M3 client: the selected item's review (base image + recipe draft), the
//  judging aids, and the post/409/404/error flow. It reads the transport handle and the batch list
//  from `SessionModel` and never owns a connection; `SessionModel` calls the hooks installed in
//  `init` so a batch refresh keeps the selection in sync.
//
//  Phases: `idle → loading → judging → posting → posted / error`. `loading` covers prepare +
//  download + decode; the timer of a download is surfaced through `loadProgress` (nil while the
//  server is still preparing). `idle` is the "nothing selected / nothing to show" state that used
//  to be `SessionModel`'s `connected`.
//

import Foundation
import Observation
import ClientKit
import ContractKit

/// The selected item's review, judging aids and the post/error flow.
@MainActor
@Observable
public final class JudgeModel {

    // MARK: - Phase

    public enum Phase: Equatable {
        /// No base selected; the detail column shows guidance (the M3 `.connected`).
        case idle
        /// prepare → preview download → PNG decode for the selected item.
        case loading
        /// A base image and a draft are loaded; the canvas is live.
        case judging
        /// The recipe POST is in flight.
        case posting
        /// The last POST was accepted and the draft still matches it.
        case posted
        /// The last action failed and there is nothing to judge; the notice carries the message.
        case error
    }

    /// What `retry()` should repeat. Kept private: the UI only needs "there is something to retry".
    private enum FailureStep: Equatable {
        case select(String)
        case post
        case refresh
    }

    // MARK: - Review

    /// One prepared item, kept for the whole session. `draft` is per item, so switching back and
    /// forth between items keeps each edit (docs/reference/client.md, state and errors "Editor state").
    public struct Review {
        public var item: ItemSummary
        public let meta: PreviewMetadata
        public let image: LinearImage
        /// What the canvas must show before it uploads `image`. Stored with the decoded pixels, so
        /// restoring this review from the session cache is a full identity (item + decode), never a
        /// version that happens to be stale.
        public let baseIdentity: BaseIdentity
        public var draft: RecipeDraft
        /// The last accepted POST for this item; `nil` until the server holds a recipe.
        public var receipt: PostReceipt?
    }

    /// One accepted POST: the server's `renderKey` and the exact draft it was built from.
    ///
    /// Per item, this is the editor baseline after a post (docs/reference/client.md, state and errors
    /// "baseline = defaults or the last post"): the green banner may claim "recipe sent" only
    /// while the sliders still match this snapshot, and the 409 flow discards it together with
    /// the source it belongs to.
    public struct PostReceipt: Equatable, Sendable {
        public let renderKey: String
        public let draft: RecipeDraft
    }

    // MARK: - Inputs

    /// The same module owns both models, so the judge keeps a strong reference and the session
    /// only holds weakly-captured callback closures back. No retain cycle.
    public let session: SessionModel

    // MARK: - Selection

    public private(set) var phase: Phase = .idle
    public private(set) var selectedItemID: String?
    public private(set) var selectedItem: ItemSummary?

    public private(set) var review: Review?
    /// Session-only cache: item id → prepared review. No disk cache in M3.
    private(set) var reviews: [String: Review] = [:]
    /// Bumped for every decoded base. It is part of `BaseIdentity`, so a cached restore keeps the
    /// generation of the decode that produced its pixels instead of inventing a new one.
    private var decodeGeneration = 0
    /// Download progress 0…1; `nil` while the server is still preparing (indeterminate spinner).
    public private(set) var loadProgress: Double?

    // MARK: - Judging aids

    public private(set) var comparing = false
    public private(set) var overlayOn = false
    /// Current EDR headroom in linear light (1.0 = no HDR), reported by the renderer.
    public private(set) var displayHeadroom: Float = 1

    // MARK: - Banners

    /// The judge's own failure banner. Session-level refresh failures live in
    /// `session.notice`; `activeNotice` is what the judge screen should show.
    public private(set) var notice: Notice?
    private var failureStep: FailureStep?

    /// Guards stale loads: selecting another item while a download is in flight must not let the
    /// old download overwrite the new one.
    private var loadGeneration = 0

    /// The 409 re-judge is an automatic re-download; only one automatic attempt per selection, so
    /// a server that keeps answering 409 can never turn into a download loop.
    private var rejudgeAttempted = false

    // MARK: - Init

    public init(session: SessionModel) {
        self.session = session
        // Mirrors the M3 single-model behavior: a successful list refresh reconciles the
        // selection, a failed one moves the phase, and an invalidated session drops the review.
        session.onItemsRefreshed = { [weak self] items in
            self?.handleItemsRefreshed(items)
        }
        session.onRefreshFailed = { [weak self] in
            self?.handleRefreshFailed()
        }
        session.onInvalidated = { [weak self] in
            self?.reset()
        }
    }

    // MARK: - Derived state

    /// The base texture the canvas should show (nil while loading / before prepare).
    public var baseImage: LinearImage? { review?.image }

    /// The identity of `baseImage`. The canvas uploads the ~70 MB texture only when this changes,
    /// so restoring a cached decode re-uploads its own pixels instead of keeping another item's
    /// texture (docs/reference/client.md, architecture: the canvas samples the PNG the iPad received).
    public var baseIdentity: BaseIdentity? { review?.baseIdentity }

    public var draft: RecipeDraft? { review?.draft }

    /// The editor state of docs/reference/client.md, state and errors: a draft is clean when it equals its
    /// baseline, which is the last accepted POST for this item or — before any post — the server
    /// defaults.
    public var isDirty: Bool {
        guard let review else { return false }
        guard let receipt = review.receipt else { return review.draft.isDirty }
        return review.draft != receipt.draft
    }

    /// A draft is on screen even when the POST failed: Done must stay usable.
    public var canPost: Bool { review != nil && phase != .posting }

    /// Sliders stay live while judging; during the POST they are frozen so the posted snapshot
    /// cannot disagree with the sliders the user is looking at.
    public var isEditing: Bool { review != nil && phase != .posting }

    /// The detail column shows the judge whenever there are pixels or pixels are on the way. An
    /// error without a review stays in the guidance column, where the message and Retry live.
    public var isShowingJudge: Bool { review != nil || phase == .loading }

    /// The banner the judge screen should show: its own failure first, then a session-level
    /// (batch refresh) failure that happened while a base is on screen.
    public var activeNotice: Notice? { notice ?? session.notice }

    // MARK: - Uniforms / readouts

    /// Mode priority (docs/reference/client.md, control model): the overlay wins over compare; both off =
    /// authored HDR.
    public var renderMode: JudgeRenderMode {
        if overlayOn { return .overlay }
        if comparing { return .compare }
        return .authored
    }

    /// The uniforms for the current draft. Slider edits only change this value — no network, no
    /// decode, no texture upload — so the canvas redraws immediately.
    public var renderUniforms: HighlightUniforms {
        let mode = renderMode
        guard let draft = review?.draft else {
            return HighlightUniforms(displayHeadroom: displayHeadroom, mode: mode)
        }
        let hdr = Recipe.HDR(
            start: draft.start,
            liftStops: draft.liftStops,
            transition: draft.transition,
            headroomCap: draft.headroomCap
        )
        // The draft's fields are clamped to the schema ranges by the model, so this validates;
        // if it ever did not, render the documented defaults instead of crashing the judge.
        guard let shape = try? HighlightShape(recipe: hdr) else {
            return HighlightUniforms(displayHeadroom: displayHeadroom, mode: mode)
        }
        return HighlightUniforms(shape: shape, displayHeadroom: displayHeadroom, mode: mode)
    }

    // MARK: - Post result

    /// The green banner's claim: the Mac holds exactly the look on screen. Derived rather than
    /// stored, so an edit retracts it instead of leaving a stale "recipe sent" over a new draft.
    public var postedMessage: String? {
        guard phase == .posted, !isDirty else { return nil }
        return "recipe sent to the Mac; M4 writes the HEIC"
    }

    /// The server-issued key of the recipe the Mac holds; only meaningful while the banner claims
    /// the look was sent, never after the draft moved on. Never computed client-side.
    public var lastRenderKey: String? {
        guard postedMessage != nil else { return nil }
        return review?.receipt?.renderKey
    }

    /// The neutral replacement for the green banner once the draft leaves the last POST
    /// (docs/reference/client.md, state and errors `isDirty`): the edit has not been sent, so nothing
    /// claims that it was.
    public var editedMessage: String? {
        guard isDirty, phase != .posting, review?.receipt != nil else { return nil }
        return "edited — not sent"
    }

    // MARK: - Selection / base load

    /// Select an item: restore the in-session review immediately if it is cached, otherwise
    /// prepare + download + decode it.
    public func select(itemID: String) async {
        guard phase != .posting else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        rejudgeAttempted = false

        selectedItemID = itemID
        selectedItem = session.items.first(where: { $0.id == itemID })
        notice = nil
        session.clearNotice()
        failureStep = nil

        if let cached = reviews[itemID] {
            review = cached
            loadProgress = nil
            setPhase(.judging)
            return
        }
        await loadReview(itemID: itemID, generation: generation)
    }

    /// Force a reload, bypassing the session cache: used by the 409 re-judge flow, where the old
    /// base bytes and the old draft belong to a source that no longer exists.
    private func reload(itemID: String) async {
        loadGeneration &+= 1
        let generation = loadGeneration
        selectedItemID = itemID
        selectedItem = session.items.first(where: { $0.id == itemID })
        reviews[itemID] = nil
        await loadReview(itemID: itemID, generation: generation)
    }

    /// prepare → `previewPNG(progress:)` → `BasePNG.load` → cache → `.judging`.
    private func loadReview(itemID: String, generation: Int) async {
        guard let client = session.client else {
            session.markUnconfigured()
            return
        }
        setPhase(.loading)
        loadProgress = nil
        review = nil
        failureStep = nil

        do {
            let prepared = try await client.prepare(itemID: itemID)
            guard generation == loadGeneration else { return }
            updateItem(prepared.item)

            loadProgress = 0
            let pngData = try await client.previewPNG(itemID: itemID) { [weak self] progress in
                Task { @MainActor in
                    guard let self, generation == self.loadGeneration else { return }
                    self.loadProgress = progress
                }
            }
            guard generation == loadGeneration else { return }

            let image = try BasePNG.load(data: pngData, expected: prepared.meta.base)
            guard generation == loadGeneration else { return }

            // A new decode gets a new generation; the cached review keeps it, so reselecting a
            // cached item is a distinct base identity for the canvas (P0: A → B → A must upload
            // A's pixels again).
            decodeGeneration &+= 1
            let fresh = Review(
                item: prepared.item,
                meta: prepared.meta,
                image: image,
                baseIdentity: BaseIdentity(itemID: itemID, generation: decodeGeneration),
                draft: RecipeDraft(defaults: prepared.meta.recipeDefaults),
                receipt: nil
            )
            reviews[itemID] = fresh
            review = fresh
            selectedItem = prepared.item
            loadProgress = nil
            setPhase(.judging)
            rejudgeAttempted = false
            // A 409 banner has done its job once the fresh source is on screen.
            if notice?.sourceChanged == true {
                notice = nil
            }
        } catch {
            guard generation == loadGeneration else { return }
            loadProgress = nil
            handleError(error, during: .select(itemID))
        }
    }

    private func updateItem(_ item: ItemSummary) {
        session.updateItem(item)
        if selectedItemID == item.id {
            selectedItem = item
        }
        if var current = review, current.item.id == item.id {
            current.item = item
            review = current
            reviews[item.id] = current
        }
    }

    // MARK: - Session callbacks

    private func handleItemsRefreshed(_ fetched: [ItemSummary]) {
        reconcileSelection(with: fetched)
        // The M3 model moved a bare `.error` back to `.connected` after a successful refresh;
        // the judge's equivalent is `.idle` (nothing selected). An active review keeps its phase.
        if phase == .error, review == nil {
            setPhase(.idle)
        }
    }

    private func handleRefreshFailed() {
        failureStep = .refresh
        setPhase(review == nil ? .error : .judging)
    }

    private func reconcileSelection(with fetched: [ItemSummary]) {
        guard let id = selectedItemID else { return }
        if let match = fetched.first(where: { $0.id == id }) {
            selectedItem = match
            if var current = review {
                current.item = match
                review = current
                reviews[id] = current
            }
        } else {
            // The item left the batch: the selection is no longer real. The cached draft stays in
            // `reviews` for this session, but the judge must not pretend the item is there.
            selectedItemID = nil
            selectedItem = nil
            review = nil
            if phase != .posting, phase != .loading {
                setPhase(.idle)
            }
        }
    }

    // MARK: - Controls (uniforms only; no network, no decode, no texture upload)

    // The ranges are the recipe schema's own (`RecipeDraft`), so the UI never carries a second
    // hard-coded list; the defaults come from `PreviewMetadata.recipeDefaults`.

    public func setStart(_ value: Double) {
        mutateDraft { $0.start = Self.clamp(value, to: RecipeDraft.startRange) }
    }

    public func setLiftStops(_ value: Double) {
        mutateDraft { $0.liftStops = Self.clamp(value, to: RecipeDraft.liftStopsRange) }
    }

    public func setTransition(_ value: Double) {
        mutateDraft { $0.transition = Self.clamp(value, to: RecipeDraft.transitionRange) }
    }

    /// Sets the delivery ceiling from the UI's stops picker; the draft stores the schema's linear
    /// multiplier (docs/reference/client.md, control model).
    public func setHeadroomCap(_ value: Double) {
        mutateDraft { $0.headroomCap = Self.clamp(value, to: RecipeDraft.headroomCapRange) }
    }

    private func mutateDraft(_ mutate: (inout RecipeDraft) -> Void) {
        mutateCurrentReview { mutate(&$0.draft) }
        // The banner belongs to the previous POST; the draft has moved on, so `isDirty` now
        // retracts the green banner.
        if phase == .posted, isDirty {
            setPhase(.judging)
        }
    }

    /// Mutates the selected review and its session-cache copy together, so a cached switch-back
    /// never resurrects an older draft or receipt.
    private func mutateCurrentReview(_ mutate: (inout Review) -> Void) {
        guard var current = review else { return }
        mutate(&current)
        review = current
        reviews[current.item.id] = current
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Judging aids

    /// Hold-to-compare: press → the SDR base (gain = 1), release → the authored HDR view.
    public func beginCompare() {
        guard !comparing else { return }
        comparing = true
    }

    public func endCompare() {
        guard comparing else { return }
        comparing = false
    }

    public func toggleOverlay() {
        overlayOn.toggle()
    }

    /// Called by the canvas when the display's EDR headroom changes (presentation only; the shader
    /// maths never uses it). `UIScreen.currentEDRHeadroom` can read 0 with no HDR content on
    /// screen; the uniforms contract expects a linear multiplier `>= 1`.
    public func updateHeadroom(current: Float) {
        guard current.isFinite else { return }
        let displayed = max(1, current)
        if displayHeadroom != displayed { displayHeadroom = displayed }
    }

    // MARK: - Done / POST (docs/reference/client.md, state and errors write guards)

    public func postRecipe() async {
        guard let client = session.client, let current = review, phase != .posting else { return }

        let recipe: Recipe
        do {
            recipe = try buildRecipe(from: current.draft, item: current.item)
        } catch {
            // Local validation failed: nothing was sent, and the draft is untouched.
            notice = Notice(
                message: "Not posted — \(Self.message(for: error))",
                severity: .error,
                canDismiss: true,
                canRetry: false
            )
            return
        }

        setPhase(.posting)
        notice = nil
        session.clearNotice()
        failureStep = nil

        do {
            let response = try await client.postRecipe(itemID: current.item.id, recipe: recipe)
            // The server is the only source of `renderKey`; never computed client-side. The receipt
            // remembers *which* draft produced it, so editing the sliders afterwards invalidates the
            // banner and the renderKey instead of claiming the new look was delivered (P1).
            updateItem(response.item)
            guard phase == .posting, review?.item.id == current.item.id else {
                // A refresh can drop the selected item while the POST is in flight. The server
                // accepted the recipe, but there is no review left to carry the receipt — and the
                // model must not stay in `.posting`, where no action could ever leave it.
                if phase == .posting {
                    setPhase(review == nil ? .idle : .judging)
                }
                return
            }
            mutateCurrentReview {
                $0.receipt = PostReceipt(renderKey: response.renderKey, draft: current.draft)
            }
            setPhase(.posted)
        } catch {
            setPhase(.judging) // keep the draft and the canvas; the notice offers a retry
            handleError(error, during: .post)
        }
    }

    /// Build only `hdr` + `created` on top of the item's defaults; validate locally first.
    private func buildRecipe(from draft: RecipeDraft, item: ItemSummary) throws -> Recipe {
        let recipe = try draft.recipe(created: Recipe.currentTimestamp())
        try recipe.validate()
        guard recipe.source.sha256 == item.id else {
            throw PhotonError.invalidRecipe(
                field: "source.sha256",
                reason: "the draft was built for a different source than the selected item"
            )
        }
        return recipe
    }

    /// Hides the green banner without changing the receipt: the claim that the Mac holds this look
    /// is still true, the user just does not need the confirmation on screen any more.
    public func dismissPosted() {
        if phase == .posted { setPhase(.judging) }
    }

    // MARK: - Banners

    /// Dismisses whichever banner the judge screen is showing. `canDismiss` is honored, so the
    /// 409 re-judge banner can only leave through a successful re-download or a retry.
    public func dismissNotice() {
        guard activeNotice?.canDismiss == true else { return }
        notice = nil
        session.dismissNotice()
    }

    // MARK: - Retry

    /// Repeat the last failed step. The draft/cache are never discarded. A session-level failure
    /// with no judge step recorded (for example a batch refresh initiated from the library) is
    /// repeated on `SessionModel`.
    public func retry() async {
        let step = failureStep
        failureStep = nil
        notice = nil
        session.clearNotice()
        switch step {
        case .select(let itemID):
            await reload(itemID: itemID)
        case .post:
            await postRecipe()
        case .refresh:
            await session.refreshItems()
        case .none:
            if session.client == nil {
                await session.connect()
            } else if let itemID = selectedItemID {
                await reload(itemID: itemID)
            } else {
                await session.refreshItems()
            }
        }
    }

    // MARK: - Error mapping (docs/reference/client.md, state and errors)

    private func handleError(_ error: Error, during step: FailureStep) {
        failureStep = step

        if let clientError = error as? ClientError {
            // 401: back to the settings; the token is the thing that must change. The session
            // invalidates the client and resets this model through `onInvalidated`.
            if clientError.needsReconnect {
                session.handleUnauthorized(message: clientError.userMessage)
                return
            }

            // 409 source_changed: never a silent success. Banner stays, the item is re-judged.
            if clientError.requiresRejudge {
                // The source the recipe was authored for is gone (the item may even be re-exported
                // under a new id), so the last receipt is not a valid claim any more.
                mutateCurrentReview { $0.receipt = nil }
                guard !rejudgeAttempted else {
                    // The automatic re-prepare came back 409 too: stop and hand it back to the
                    // user (a second 22 MB download attempt would be a loop, not a recovery).
                    setPhase(review == nil ? .error : .judging)
                    failureStep = .refresh
                    notice = Notice(
                        message: "the source keeps changing; refresh the batch and judge it again",
                        severity: .warning,
                        sourceChanged: true,
                        canDismiss: false,
                        canRetry: true
                    )
                    return
                }
                rejudgeAttempted = true
                notice = Notice(
                    message: "the source was re-exported; judge it again",
                    severity: .warning,
                    sourceChanged: true,
                    canDismiss: false
                )
                setPhase(review == nil ? .loading : .judging)
                Task { await rejudgeAfterSourceChange() }
                return
            }

            // 404: the item left the batch. Refresh the list and let the notice explain.
            if clientError.shouldRefreshList {
                if step != .post {
                    review = nil
                }
                setPhase(review == nil ? .error : .judging)
                notice = Notice(
                    message: clientError.userMessage,
                    severity: .warning,
                    canDismiss: true,
                    canRetry: true
                )
                // Retry means "refresh the batch", not "prepare the item that is gone".
                failureStep = .refresh
                Task { await session.refreshItems() }
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

        // Non-transport errors (PNG validation, local recipe validation).
        notice = Notice(
            message: Self.message(for: error),
            severity: .error,
            canDismiss: true,
            canRetry: true
        )
        applyFailurePhase(for: step)
    }

    /// A failed step only hides the judge when there is nothing left to judge; a failed POST or a
    /// failed list refresh keeps the base and the draft on screen.
    private func applyFailurePhase(for step: FailureStep) {
        switch step {
        case .post:
            setPhase(.judging)
        case .refresh:
            setPhase(review == nil ? .error : .judging)
        case .select:
            setPhase(.error)
        }
    }

    /// Plan B for the 409 flow: the re-export is a new id, so refresh the batch and pick the
    /// current incarnation of the same source, then re-prepare and re-download it.
    private func rejudgeAfterSourceChange() async {
        guard session.client != nil else { return }
        let previous = selectedItem

        await session.refreshItems()

        let target: ItemSummary?
        if let previous {
            target = session.items.first(where: { $0.id == previous.id })
                ?? session.items.first(where: { $0.path == previous.path })
                ?? session.items.first(where: { $0.name == previous.name })
        } else {
            target = nil
        }

        guard let target else {
            setPhase(.error)
            failureStep = .refresh
            notice = Notice(
                message: "the source was re-exported; refresh the batch to find the new item and judge it again",
                severity: .warning,
                sourceChanged: true,
                canDismiss: false,
                canRetry: true
            )
            return
        }

        notice = Notice(
            message: "the source was re-exported; judging the new version…",
            severity: .warning,
            sourceChanged: true,
            canDismiss: false
        )
        await reload(itemID: target.id)
    }

    // MARK: - Reset

    /// Drops the whole judge state for a disconnect or a coordinator reset: selection, review,
    /// the session cache, download progress, the judging aids and every banner/failure.
    /// `displayHeadroom` is left as reported by the renderer (presentation only).
    public func reset() {
        loadGeneration &+= 1 // discard any in-flight download
        review = nil
        reviews = [:]
        selectedItemID = nil
        selectedItem = nil
        loadProgress = nil
        comparing = false
        overlayOn = false
        notice = nil
        failureStep = nil
        rejudgeAttempted = false
        setPhase(.idle)
    }

    // MARK: - Phase plumbing

    /// Every phase write goes through here so `SessionModel.connect()` can keep the M3 guard that
    /// refused to reconnect underneath a base load or a POST.
    private func setPhase(_ new: Phase) {
        phase = new
        session.setJudgeBusy(new == .loading || new == .posting)
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
