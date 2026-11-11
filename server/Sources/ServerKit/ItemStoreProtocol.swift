import Foundation
import ContractKit

/// Store-level failures the router maps onto HTTP statuses. Kept separate from PhotonError so the
/// HTTP layer never leaks engine internals into status-code decisions.
public enum ItemStoreError: Error, Equatable {
    case unknownItem(id: String)
    case invalidRecipe(message: String)
    case sourceChanged(expected: String, actual: String)
    case sourceUnreadable(message: String)
    case prepareFailed(message: String)
    case io(message: String)
}

/// Everything the router needs from the on-disk batch store. Implemented by `ItemStore`; faked in
/// router tests so routing/status/auth can be tested without files or the encoder.
public protocol ItemStoreProtocol: AnyObject {
    /// Cheap count for /api/health: counts source files without hashing them, so duplicate content
    /// can make it exceed the number of distinct items (the list is the authoritative view).
    func itemCount() throws -> Int
    func listItems() throws -> [ItemSummary]
    func item(id: String) throws -> ItemSummary
    /// Idempotent: renders the SDR base preview (16-bit P3 PNG) if the cache is cold; returns the
    /// item, the preview metadata and whether the cache was hit. No HDR work happens here.
    func prepare(id: String) throws -> PrepareResponse
    /// Raw `meta.json` bytes (pretty, sorted) for an already-prepared item.
    func metadataJSON(id: String) throws -> Data
    /// Raw 16-bit P3 PNG base bytes for an already-prepared item.
    func previewPNG(id: String) throws -> Data
    /// 512-high Display P3 HEIC bytes for the filmstrip (ADR-0013). Renders on a cold cache with
    /// ImageIO — never via `prepare` — and never changes the item state.
    func thumbnail(id: String) throws -> Data
    /// Stored recipe JSON, or nil.
    func recipeJSON(id: String) throws -> Data?
    /// Validates + persists a posted recipe; returns it with its render key.
    func storeRecipe(id: String, body: Data) throws -> RecipePostResponse
}
