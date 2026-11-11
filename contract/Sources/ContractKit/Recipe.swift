import CryptoKit
import Foundation

/// The versioned recipe: the only thing the iPad sends back to the Mac.
///
/// Field contract and validation ranges: docs/reference/recipe.md "Recipe schema 0 — field contract".
/// The JSON keys are snake_case exactly as documented there; do not rename them.
///
/// Invariants (enforced by `validate()`):
/// - `schema == currentSchema`; unknown schemas are refused, never reinterpreted
/// - recipe fields only *select* rendering; nothing here may modify the SDR base pixels
/// - `created` is metadata: it is excluded from `renderKey()`, so two identical recipes
///   made at different times resolve to the same render.
///
/// `renderKey()` covers exactly the fields that can change the rendered pixels or select how they
/// are rendered: `schema`, the source *identity* (`sha256` + `width`/`height`), `base`, `hdr`,
/// `encoder`, `versions`. It deliberately excludes `created` and `source.path` — both are metadata,
/// so moving the repository or the same bytes to another folder must not miss the cache
/// (review P1-6, docs/reference/wire.md, M2.1 wire contract, cache).
public struct Recipe: Codable, Equatable, Sendable {
    public static let currentSchema = 0

    public struct Source: Codable, Equatable, Sendable {
        /// Provenance only: where the export lived when the recipe was written (repo-relative when
        /// possible). Never resolved blindly from JSON, and never part of `renderKey()` — the same
        /// bytes at a different path are the same render. Kept for humans and re-export diagnosis.
        public let path: String
        public let sha256: String
        public let width: Int
        public let height: Int

        public init(path: String, sha256: String, width: Int, height: Int) {
            self.path = path
            self.sha256 = sha256
            self.width = width
            self.height = height
        }
    }

    public struct Base: Codable, Equatable, Sendable {
        public static let displayP3Profile = "DisplayP3"
        public static let c1MatchV1 = "c1_match_v1"

        public let profile: String
        public let toneMap: String

        public init(profile: String = Self.displayP3Profile, toneMap: String = Self.c1MatchV1) {
            self.profile = profile
            self.toneMap = toneMap
        }

        private enum CodingKeys: String, CodingKey {
            case profile
            case toneMap = "tone_map"
        }
    }

    public struct HDR: Codable, Equatable, Sendable {
        public static let defaultStart = 0.62
        public static let defaultLiftStops = 1.4
        public static let defaultTransition = 0.28
        /// 2 stops, expressed as the schema's linear multiplier (the iPad's stops picker default).
        public static let defaultHeadroomCap = pow(2.0, 2.0)

        /// Mask threshold as a fraction of SDR white, on Rec.709 luma of the linear working buffer.
        public let start: Double
        /// Gain at full mask, in stops above SDR white.
        public let liftStops: Double
        /// Roll-off width above `start`: `smoothstep(start, start + transition, luma)`.
        public let transition: Double
        /// Absolute linear clamp on the HDR rendition (default 2^2 = 4 = 2 stops; range 1…8).
        public let headroomCap: Double

        public init(
            start: Double = Self.defaultStart,
            liftStops: Double = Self.defaultLiftStops,
            transition: Double = Self.defaultTransition,
            headroomCap: Double = Self.defaultHeadroomCap
        ) {
            self.start = start
            self.liftStops = liftStops
            self.transition = transition
            self.headroomCap = headroomCap
        }

        private enum CodingKeys: String, CodingKey {
            case start
            case liftStops = "lift_stops"
            case transition
            case headroomCap = "headroom_cap"
        }
    }

    public struct EncoderParams: Codable, Equatable, Sendable {
        /// The legacy external tool; still accepted so pre-v2 recipes decode unchanged.
        public static let toolName = "toGainMapHDR"
        /// The v2 in-process Core Image writer.
        public static let coreImageToolName = "coreimage"
        public static let isoRGBMap = "iso-rgb"
        public static let isoMonoMap = "iso-mono"

        public let tool: String
        /// `-q`, 0…1.
        public let quality: Double
        /// 8 or 10.
        public let depth: Int
        /// `true` = half-resolution gain map (the Apple shape); `false` = full resolution.
        public let subsample: Bool
        public let map: String

        /// The v2 default profile: `coreimage`, 10-bit base, half-resolution ISO RGB map
        /// (docs/reference/recipe.md field contract; `encoder.tool` accepts the legacy
        /// `"toGainMapHDR"` so pre-v2 recipes decode unchanged).
        public init(
            tool: String = Self.coreImageToolName,
            quality: Double = 0.85,
            depth: Int = 10,
            subsample: Bool = true,
            map: String = Self.isoRGBMap
        ) {
            self.tool = tool
            self.quality = quality
            self.depth = depth
            self.subsample = subsample
            self.map = map
        }

        private enum CodingKeys: String, CodingKey {
            case tool, quality, depth, subsample, map
        }
    }

    public struct Versions: Codable, Equatable, Sendable {
        public static let currentRecipe = 0
        public static let currentToneMap = 1

        public let recipe: Int
        public let toneMap: Int
        /// Encoder git short sha (the tool's commit — not libheif's version).
        public let encoder: String

        public init(recipe: Int = Self.currentRecipe, toneMap: Int = Self.currentToneMap, encoder: String) {
            self.recipe = recipe
            self.toneMap = toneMap
            self.encoder = encoder
        }

        private enum CodingKeys: String, CodingKey {
            case recipe
            case toneMap = "tone_map"
            case encoder
        }
    }

    public let schema: Int
    public let source: Source
    public let base: Base
    public let hdr: HDR
    public let encoder: EncoderParams
    public let versions: Versions
    public let created: String

    public init(
        schema: Int = Self.currentSchema,
        source: Source,
        base: Base = Base(),
        hdr: HDR = HDR(),
        encoder: EncoderParams = EncoderParams(),
        versions: Versions,
        created: String
    ) {
        self.schema = schema
        self.source = source
        self.base = base
        self.hdr = hdr
        self.encoder = encoder
        self.versions = versions
        self.created = created
    }

    /// The recipe M1 uses for a freshly decoded source: documented defaults, identity SDR tone map.
    ///
    /// - Parameter sourcePath: provenance only; callers should pass a stable, cwd-relative path
    ///   when possible (`Pipeline.provenancePath(for:)` does that). It never enters `renderKey()`.
    public static func defaults(
        sourcePath: String,
        sourceSHA256: String,
        width: Int,
        height: Int,
        encoderVersion: String,
        encoder: EncoderParams = EncoderParams(),
        created: String = Recipe.currentTimestamp()
    ) -> Recipe {
        Recipe(
            source: Source(path: sourcePath, sha256: sourceSHA256, width: width, height: height),
            encoder: encoder,
            versions: Versions(encoder: encoderVersion),
            created: created
        )
    }

    /// RFC 3339 timestamp in the local time zone, e.g. `2026-11-02T20:52:00+08:00`.
    public static func currentTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // Local offset, matching the documented example (`…+08:00`), not UTC `Z`.
        // `created` is metadata only and is excluded from renderKey().
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }
}

// MARK: - Validation

extension Recipe {
    /// Validates every field against docs/reference/recipe.md (recipe schema 0).
    /// - Throws: `PhotonError.invalidRecipe` with the offending field and reason.
    public func validate() throws {
        guard schema == Self.currentSchema else {
            throw PhotonError.invalidRecipe(
                field: "schema",
                reason: "unsupported schema \(schema); this build understands \(Self.currentSchema) only"
            )
        }
        guard versions.recipe == schema else {
            throw PhotonError.invalidRecipe(
                field: "versions.recipe",
                reason: "\(versions.recipe) disagrees with schema \(schema)"
            )
        }
        guard versions.toneMap == Versions.currentToneMap else {
            throw PhotonError.invalidRecipe(
                field: "versions.tone_map",
                reason: "unsupported tone-map version \(versions.toneMap)"
            )
        }
        guard !versions.encoder.isEmpty else {
            throw PhotonError.invalidRecipe(field: "versions.encoder", reason: "must record the encoder commit")
        }
        guard !source.path.isEmpty else {
            throw PhotonError.invalidRecipe(field: "source.path", reason: "must not be empty")
        }
        guard Self.isHexDigest(source.sha256) else {
            throw PhotonError.invalidRecipe(field: "source.sha256", reason: "must be 64 hex characters")
        }
        guard source.width > 0, source.height > 0 else {
            throw PhotonError.invalidRecipe(
                field: "source.width/height",
                reason: "must be positive, got \(source.width)x\(source.height)"
            )
        }
        guard base.profile == Base.displayP3Profile else {
            throw PhotonError.invalidRecipe(
                field: "base.profile",
                reason: "stage 1 delivers \(Base.displayP3Profile) only, got '\(base.profile)'"
            )
        }
        guard base.toneMap == Base.c1MatchV1 else {
            throw PhotonError.invalidRecipe(
                field: "base.tone_map",
                reason: "unknown tone map '\(base.toneMap)' (stage 1 knows '\(Base.c1MatchV1)')"
            )
        }
        try Self.require(hdr.start, in: 0...1, field: "hdr.start")
        try Self.require(hdr.liftStops, in: 0...4, field: "hdr.lift_stops")
        try Self.require(hdr.transition, in: 0.001...1, field: "hdr.transition")
        try Self.require(hdr.headroomCap, in: 1...8, field: "hdr.headroom_cap")
        guard encoder.tool == EncoderParams.toolName || encoder.tool == EncoderParams.coreImageToolName else {
            throw PhotonError.invalidRecipe(
                field: "encoder.tool",
                reason: "must be '\(EncoderParams.coreImageToolName)' or the legacy '\(EncoderParams.toolName)', got '\(encoder.tool)'"
            )
        }
        try Self.require(encoder.quality, in: 0...1, field: "encoder.quality")
        guard encoder.depth == 8 || encoder.depth == 10 else {
            throw PhotonError.invalidRecipe(field: "encoder.depth", reason: "must be 8 or 10, got \(encoder.depth)")
        }
        guard encoder.map == EncoderParams.isoRGBMap || encoder.map == EncoderParams.isoMonoMap else {
            throw PhotonError.invalidRecipe(
                field: "encoder.map",
                reason: "must be '\(EncoderParams.isoRGBMap)' or '\(EncoderParams.isoMonoMap)', got '\(encoder.map)'"
            )
        }
        guard !created.isEmpty else {
            throw PhotonError.invalidRecipe(field: "created", reason: "must be an RFC 3339 timestamp")
        }
    }

    private static func require(_ value: Double, in range: ClosedRange<Double>, field: String) throws {
        guard value.isFinite, range.contains(value) else {
            throw PhotonError.invalidRecipe(
                field: field,
                reason: "must be in \(range.lowerBound)...\(range.upperBound), got \(value)"
            )
        }
    }

    private static func isHexDigest(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 65 && scalar.value <= 70) || (scalar.value >= 97 && scalar.value <= 102)
        }
    }
}

// MARK: - Canonical form / cache identity

extension Recipe {
    /// Deterministic JSON: sorted keys, no escaped slashes, no pretty printing.
    /// Used for hashing and for writing the recipe beside the output.
    public func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Canonical JSON with the metadata-only fields that cannot affect pixels removed.
    ///
    /// Two fields are excluded on purpose (review P1-6):
    /// - `created` never affects pixels (docs/reference/recipe.md, validation and determinism), so
    ///   the same recipe re-sent tomorrow must hit the
    ///   cache instead of missing it;
    /// - `source.path` is provenance only, so relocating the repository or the same bytes in a
    ///   different folder must not change the cache key. The source *identity* stays in: `sha256`,
    ///   plus the `width`/`height` the recipe was authored for.
    ///
    /// Everything else is included, so any render-affecting field change produces a new key.
    public func canonicalRenderJSON() throws -> Data {
        /// The `source` object as it enters the render key: identity, no provenance path.
        struct RenderSource: Encodable {
            let sha256: String
            let width: Int
            let height: Int
        }
        struct RenderStable: Encodable {
            let schema: Int
            let source: RenderSource
            let base: Base
            let hdr: HDR
            let encoder: EncoderParams
            let versions: Versions
        }
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try jsonEncoder.encode(
            RenderStable(
                schema: schema,
                source: RenderSource(sha256: source.sha256, width: source.width, height: source.height),
                base: base,
                hdr: hdr,
                encoder: encoder,
                versions: versions
            )
        )
    }

    /// SHA-256 of `canonicalRenderJSON()`, hex encoded. The source SHA-256 names the per-item
    /// directory; the delivery report and the recipe echo record this key, and it is the intended
    /// "hash(recipe)" half of a stage-2 cache key (docs/reference/operations.md). No preview cache consumes it yet.
    /// Contract: only fields that can affect rendering enter the key — `created` and
    /// `source.path` are excluded, so the key is stable across clock and path changes.
    public func renderKey() throws -> String {
        SHA256.hash(data: try canonicalRenderJSON()).map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience: the source-identity half of the cache key (never the provenance path).
    public var sourceKey: String { source.sha256 }
}
