import Foundation

/// `POST /api/items/{id}/prepare` — the item, its preview metadata, and whether the base was a
/// cache hit (warm `prepare` is ~0.1 s; cold is ~1.5 s, so the UI shows a spinner for the first).
public struct PrepareResponse: Codable, Equatable, Sendable {
    public let item: ItemSummary
    public let meta: PreviewMetadata
    public let cached: Bool

    public init(item: ItemSummary, meta: PreviewMetadata, cached: Bool) {
        self.item = item
        self.meta = meta
        self.cached = cached
    }
}

/// `POST /api/items/{id}/recipe` — the stored recipe plus the server-computed render key.
/// The client never computes `renderKey` itself (docs/reference/recipe.md, validation and determinism).
public struct RecipePostResponse: Codable, Equatable, Sendable {
    public let item: ItemSummary
    public let recipe: Recipe
    public let renderKey: String

    public init(item: ItemSummary, recipe: Recipe, renderKey: String) {
        self.item = item
        self.recipe = recipe
        self.renderKey = renderKey
    }
}
