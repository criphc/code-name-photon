import Foundation
import ContractKit

/// The transport surface the client state machines depend on.
///
/// `PhotonClient` is the real implementation; `ClientModelTests` injects a fake so the state
/// machines are testable without a network (R5: testable state machines live in the package).
public protocol PhotonClientProtocol: Sendable {
    func health() async throws -> HealthResponse
    func listItems() async throws -> [ItemSummary]
    func prepare(itemID: String) async throws -> PrepareResponse
    func previewPNG(itemID: String, progress: ((Double) -> Void)?) async throws -> Data
    /// The 512-high Display P3 HEIC the filmstrip shows (ADR-0013). Not a judging input.
    func thumbnailHEIC(itemID: String) async throws -> Data
    func postRecipe(itemID: String, recipe: Recipe) async throws -> RecipePostResponse
}

extension PhotonClient: PhotonClientProtocol {}
