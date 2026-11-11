import ContractKit
import Foundation

/// One HEIC output profile (docs/plans/v2-plan.md, "输出 profile").
///
/// The delivery can request several profiles in one run; they share the decoded source, the SDR
/// base, the HDR rendition and the gain map, and differ only in the base bit depth, the gain-map
/// resolution/kind and the encode quality. The recipe's `encoder` block is the default profile;
/// the CLI can pass a list of profiles for "simultaneous" delivery.
public struct HEICEncodeOptions: Codable, Equatable, Sendable {
    public enum BitDepth: Int, Codable, Equatable, Sendable, CaseIterable {
        case eight = 8
        case ten = 10
    }

    public enum MapResolution: String, Codable, Equatable, Sendable, CaseIterable {
        case full
        case half
    }

    public enum MapKind: String, Codable, Equatable, Sendable, CaseIterable {
        case isoRGB = "iso-rgb"
        case isoMono = "iso-mono"
    }

    public var bitDepth: BitDepth
    public var quality: Double
    public var mapResolution: MapResolution
    public var mapKind: MapKind

    public init(
        bitDepth: BitDepth = .ten,
        quality: Double = 0.85,
        mapResolution: MapResolution = .half,
        mapKind: MapKind = .isoRGB
    ) throws {
        guard quality.isFinite, (0...1).contains(quality) else {
            throw PhotonError.invalidRecipe(
                field: "encoder.quality",
                reason: "must be in 0...1, got \(quality)"
            )
        }
        self.bitDepth = bitDepth
        self.quality = quality
        self.mapResolution = mapResolution
        self.mapKind = mapKind
    }

    /// The recipe's `encoder` block as a profile. `subsample` is the half-resolution flag.
    public init(recipe: Recipe) throws {
        guard let depth = BitDepth(rawValue: recipe.encoder.depth) else {
            throw PhotonError.invalidRecipe(
                field: "encoder.depth",
                reason: "must be 8 or 10, got \(recipe.encoder.depth)"
            )
        }
        let resolution: MapResolution = recipe.encoder.subsample ? .half : .full
        let kind: MapKind = recipe.encoder.map == MapKind.isoMono.rawValue ? .isoMono : .isoRGB
        try self.init(
            bitDepth: depth,
            quality: recipe.encoder.quality,
            mapResolution: resolution,
            mapKind: kind
        )
    }

    /// `"10/half/rgb"`, `"8/full/mono"` — the CLI's `--profile` syntax.
    public init?(profileString: String) {
        let parts = profileString.split(separator: "/").map(String.init)
        guard parts.count == 3,
              let depth = Int(parts[0]),
              let bitDepth = BitDepth(rawValue: depth),
              let resolution = MapResolution(rawValue: parts[1])
        else { return nil }
        let kind: MapKind
        switch parts[2] {
        case "rgb", MapKind.isoRGB.rawValue: kind = .isoRGB
        case "mono", MapKind.isoMono.rawValue: kind = .isoMono
        default: return nil
        }
        guard let options = try? HEICEncodeOptions(
            bitDepth: bitDepth,
            quality: 0.85,
            mapResolution: resolution,
            mapKind: kind
        ) else { return nil }
        self = options
    }

    /// Stable identifier for the report's `profiles` keys and the artifact names.
    public var profileName: String {
        "\(bitDepth.rawValue)-\(mapResolution.rawValue)-\(mapKind == .isoRGB ? "rgb" : "mono")"
    }
}
