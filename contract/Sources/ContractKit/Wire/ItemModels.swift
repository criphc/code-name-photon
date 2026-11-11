import Foundation

/// Lifecycle of one batch item, as far as the wire is concerned.
/// (Stage 2 extends this with rendered/encoded/verified; that is a schema decision, not a P1 move.)
public enum ItemState: String, Codable, CaseIterable, Sendable, Equatable {
    /// The source exists in the batch directory; nothing has been rendered yet.
    case pending
    /// A preview + meta.json exist for the documented default recipe.
    case previewReady = "preview_ready"
    /// A recipe has been received and stored beside the item.
    case recipeReceived = "recipe_received"
    /// The last prepare attempt failed; `error` says why.
    case failed
}

/// The listing payload for one item (`GET /api/items`). This is the M2/M3 HTTP contract: the
/// server produces it, the client displays it, and neither side keeps a second definition.
public struct ItemSummary: Codable, Identifiable, Equatable, Sendable {
    /// Full lowercase SHA-256 of the source file; the stable identity across re-exports.
    public let id: String
    public let name: String
    /// Absolute path of the source on the Mac (informational; never resolved from client input).
    public let path: String
    public let state: ItemState
    public let previewReady: Bool
    public let hasRecipe: Bool
    /// Pixel size once known (after a prepare / from cached state).
    public let width: Int?
    public let height: Int?
    /// Last failure message when `state == .failed`.
    public let error: String?

    public init(
        id: String,
        name: String,
        path: String,
        state: ItemState,
        previewReady: Bool,
        hasRecipe: Bool,
        width: Int? = nil,
        height: Int? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.state = state
        self.previewReady = previewReady
        self.hasRecipe = hasRecipe
        self.width = width
        self.height = height
        self.error = error
    }
}

/// `GET /api/items` — the batch, sorted by name by the server.
public struct ItemListResponse: Codable, Equatable, Sendable {
    public let items: [ItemSummary]

    public init(items: [ItemSummary]) {
        self.items = items
    }
}
