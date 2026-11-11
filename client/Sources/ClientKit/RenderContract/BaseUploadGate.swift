import Foundation

/// Identity of the decoded SDR base the EDR canvas presents.
///
/// The canvas must sample exactly the PNG whose bytes the iPad received (docs/reference/client.md, architecture "BaseStore").
/// The session cache restores a previously decoded `LinearImage` without decoding it again, so a
/// bare "decode counter" cannot tell the renderer which pixels it is looking at: the identity must
/// name *which* item the pixels belong to as well as which decode produced them. The item switch
/// A → B → A then goes back to A's identity, which is a real change even though no new decode
/// happened.
public struct BaseIdentity: Equatable, Sendable {
    /// The server item id the base belongs to (`ItemSummary.id`).
    public let itemID: String
    /// Distinguishes two decodes of the same item, e.g. the re-prepare of the 409 flow.
    public let generation: Int

    public init(itemID: String, generation: Int) {
        self.itemID = itemID
        self.generation = generation
    }
}

/// Decides when the canvas must (re)upload the base texture.
///
/// The base is ~70 MB of CPU floats and a ~70 MB `rgba32Float` texture, so slider edits must never
/// touch it; but restoring a cached image, switching items and clearing the canvas all must. Keeping
/// the applied `BaseIdentity` (instead of a version that is only bumped after a successful decode)
/// is what separates those cases.
public struct BaseUploadGate: Equatable, Sendable {
    /// The identity currently on the GPU (`nil` = no base uploaded).
    public private(set) var appliedIdentity: BaseIdentity?

    public init() {}

    /// `true` when the GPU does not hold `identity` yet: the caller uploads those pixels (or
    /// clears the texture for `nil`) and then records it with `commitUpload(_:)`.
    public func needsUpload(for identity: BaseIdentity?) -> Bool {
        identity != appliedIdentity
    }

    /// Records the identity the caller just uploaded. Call it only after `setBase` succeeded.
    public mutating func commitUpload(_ identity: BaseIdentity?) {
        appliedIdentity = identity
    }
}
