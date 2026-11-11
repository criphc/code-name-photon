import Foundation
import ContractKit

/// Schema 1 of the v2 delivery report (`{stem}.report.json`).
///
/// The report is the **gate**, not a log (docs/reference/deliver.md): `appctl deliver` installs the
/// deliverables into `--out` only when every check of **every requested profile** is `PASS`. A
/// `FAIL` keeps the diagnosis in `work/<sha>/rejected/<renderKey12>/` and names the failing
/// profile/check. The v2 report groups one `ProfileReport` per output profile (bit depth, map
/// resolution/kind, quality); the source/recipe/provenance are shared.
///
/// The check list and what each one asserts are docs/reference/deliver.md. The names are stable
/// identifiers:
///
///   `container`        HEIF/ISO-BMFF, `tmap` compatible brand, ISO gain-map auxiliary present
///   `identity`         decoded dimensions == the source; sha256/renderKey/versions recorded
///   `alpha`            no alpha in the SDR **and** HDR decodes
///   `headroom`         advertised `contentHeadroom` within 5 % of the authored headroom
///   `clipping`         authored peak clamps to the cap with no sample above it; fractions reported
///   `baseDeltaE`       decoded SDR base vs the 16-bit P3 export (ΔE2000)
///   `fallback`         the 8-bit SDR fallback matches the delivered SDR base
///   `previewAgreement` the same recipe at preview scale vs the delivered HDR decode downscaled
public struct DeliveryReport: Codable, Equatable, Sendable {
    /// The only accepted schema. Bump on any semantic change.
    public static let currentSchema = 1

    /// The canonical check order inside every profile.
    public static let checkOrder = [
        "container",
        "identity",
        "alpha",
        "headroom",
        "clipping",
        "baseDeltaE",
        "fallback",
        "previewAgreement",
    ]

    public enum Status: String, Codable, Equatable, Sendable {
        case pass = "PASS"
        case fail = "FAIL"
    }

    /// One measured value in a check's `measured` object. A small tagged union keeps the JSON
    /// honest (numbers stay numbers, strings stay strings) without a dependency.
    public enum Value: Codable, Equatable, Sendable {
        case number(Double)
        case integer(Int)
        case text(String)
        case boolean(Bool)

        public init(_ value: Double) { self = .number(value) }
        public init(_ value: Int) { self = .integer(value) }
        public init(_ value: String) { self = .text(value) }
        public init(_ value: Bool) { self = .boolean(value) }

        public var numberValue: Double? {
            switch self {
            case let .number(value): return value
            case let .integer(value): return Double(value)
            case let .boolean(value): return value ? 1 : 0
            case .text: return nil
            }
        }

        public var textValue: String? {
            switch self {
            case let .text(value): return value
            case let .number(value): return value.description
            case let .integer(value): return String(value)
            case let .boolean(value): return String(value)
            }
        }

        private enum CodingKeys: String, CodingKey { case type, value }

        public func encode(to encoder: Swift.Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .number(value):
                try container.encode("number", forKey: .type)
                try container.encode(value, forKey: .value)
            case let .integer(value):
                try container.encode("integer", forKey: .type)
                try container.encode(value, forKey: .value)
            case let .text(value):
                try container.encode("text", forKey: .type)
                try container.encode(value, forKey: .value)
            case let .boolean(value):
                try container.encode("boolean", forKey: .type)
                try container.encode(value, forKey: .value)
            }
        }

        public init(from decoder: Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "number": self = .number(try container.decode(Double.self, forKey: .value))
            case "integer": self = .integer(try container.decode(Int.self, forKey: .value))
            case "text": self = .text(try container.decode(String.self, forKey: .value))
            case "boolean": self = .boolean(try container.decode(Bool.self, forKey: .value))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "unknown DeliveryReport.Value type"
                )
            }
        }
    }

    /// One named PASS/FAIL with its measured values. `warnings` are recorded but do not fail the
    /// delivery (the half-res `previewAgreement` band and any future soft signal).
    public struct Check: Codable, Equatable, Sendable {
        public let name: String
        public let status: Status
        /// One sentence: what was measured and why it passed or failed.
        public let detail: String
        /// The numbers behind the verdict (sorted keys on disk).
        public let measured: [String: Value]
        /// Non-fatal observations; a warning never changes `status`.
        public let warnings: [String]

        public init(
            name: String,
            status: Status,
            detail: String,
            measured: [String: Value] = [:],
            warnings: [String] = []
        ) {
            self.name = name
            self.status = status
            self.detail = detail
            self.measured = measured
            self.warnings = warnings
        }

        /// Convenience for the verifier: `pass` decides the status.
        public init(
            name: String,
            pass: Bool,
            detail: String,
            measured: [String: Value] = [:],
            warnings: [String] = []
        ) {
            self.init(
                name: name,
                status: pass ? .pass : .fail,
                detail: detail,
                measured: measured,
                warnings: warnings
            )
        }

        public var passed: Bool { status == .pass }
    }

    public struct Provenance: Codable, Equatable, Sendable {
        public static let tool = "photon deliver"
        public static let currentVersion = "0.5.0-v2"

        public let tool: String
        public let appVersion: String
        /// The engine identity: `coreimage-1`, or the external tool's git short sha while the
        /// oracle is in use.
        public let encoderVersion: String
        /// RFC 3339, local offset (the shape `Recipe.currentTimestamp()` uses).
        public let generatedAt: String
        public let hostOS: String

        public init(
            appVersion: String = Provenance.currentVersion,
            encoderVersion: String,
            generatedAt: String = Recipe.currentTimestamp(),
            hostOS: String = ProcessInfo.processInfo.operatingSystemVersionString
        ) {
            self.tool = Provenance.tool
            self.appVersion = appVersion
            self.encoderVersion = encoderVersion
            self.generatedAt = generatedAt
            self.hostOS = hostOS
        }
    }

    /// The source the delivery was made from: identity plus what the decoder observed.
    public struct SourceIdentity: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public let width: Int
        public let height: Int
        public let profileName: String?
        public let bitsPerComponent: Int

        public init(
            path: String,
            sha256: String,
            width: Int,
            height: Int,
            profileName: String?,
            bitsPerComponent: Int
        ) {
            self.path = path
            self.sha256 = sha256
            self.width = width
            self.height = height
            self.profileName = profileName
            self.bitsPerComponent = bitsPerComponent
        }
    }

    /// The recipe the delivery used. The exact recipe JSON is archived beside the HEICs; this is
    /// the audit summary that makes "which recipe produced this file" answerable from the report.
    public struct RecipeReference: Codable, Equatable, Sendable {
        public let renderKey: String
        public let created: String
        public let start: Double
        public let liftStops: Double
        public let transition: Double
        public let headroomCap: Double
        public let quality: Double
        public let depth: Int

        public init(recipe: Recipe, renderKey: String) {
            self.renderKey = renderKey
            self.created = recipe.created
            self.start = recipe.hdr.start
            self.liftStops = recipe.hdr.liftStops
            self.transition = recipe.hdr.transition
            self.headroomCap = recipe.hdr.headroomCap
            self.quality = recipe.encoder.quality
            self.depth = recipe.encoder.depth
        }
    }

    /// One output profile: the name is also the artifact suffix (`{stem}-hdr-{name}.heic`).
    public struct ProfileReference: Codable, Equatable, Sendable {
        public let name: String
        public let bitDepth: Int
        public let quality: Double
        public let mapResolution: String
        public let mapKind: String

        public init(options: HEICEncodeOptions) {
            self.name = options.profileName
            self.bitDepth = options.bitDepth.rawValue
            self.quality = options.quality
            self.mapResolution = options.mapResolution.rawValue
            self.mapKind = options.mapKind.rawValue
        }
    }

    /// One file of the delivery set: name relative to the `--out` folder, its size and SHA-256.
    public struct FileArtifact: Codable, Equatable, Sendable {
        public let file: String
        public let bytes: Int
        public let sha256: String

        public init(file: String, bytes: Int, sha256: String) {
            self.file = file
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    public struct Artifacts: Codable, Equatable, Sendable {
        public let hdrHEIC: FileArtifact
        /// The shared 8-bit SDR fallback (the same file for every profile).
        public let sdrHEIC: FileArtifact
        /// The shared recipe echo.
        public let recipeJSON: FileArtifact

        public init(hdrHEIC: FileArtifact, sdrHEIC: FileArtifact, recipeJSON: FileArtifact) {
            self.hdrHEIC = hdrHEIC
            self.sdrHEIC = sdrHEIC
            self.recipeJSON = recipeJSON
        }
    }

    /// The authored rendition, as measured on the float pixels *before* encoding.
    public struct Render: Codable, Equatable, Sendable {
        public let width: Int
        public let height: Int
        public let headroomCap: Double
        public let authoredPeak: Double
        public let authoredPeakStops: Double
        public let fractionAboveOne: Double
        public let fractionAtCap: Double
        public let capEngaged: Bool
        public let previewLongEdge: Int

        public init(
            width: Int,
            height: Int,
            headroomCap: Double,
            authoredPeak: Double,
            fractionAboveOne: Double,
            fractionAtCap: Double,
            previewLongEdge: Int
        ) {
            self.width = width
            self.height = height
            self.headroomCap = headroomCap
            self.authoredPeak = authoredPeak
            self.authoredPeakStops = authoredPeak > 0 ? log2(authoredPeak) : 0
            self.fractionAboveOne = fractionAboveOne
            self.fractionAtCap = fractionAtCap
            self.capEngaged = authoredPeak >= headroomCap - 1e-6
            self.previewLongEdge = previewLongEdge
        }
    }

    /// Per-step wall-clock times. The report contains them, so `report.json` is not byte-identical
    /// across runs; the determinism gate covers the HEICs and the recipe echo.
    public struct Timings: Codable, Equatable, Sendable {
        public let decodeSeconds: Double
        public let renderSeconds: Double
        public let previewSeconds: Double
        public let encodeSeconds: Double
        public let verifySeconds: Double
        public let totalSeconds: Double

        public init(
            decodeSeconds: Double,
            renderSeconds: Double,
            previewSeconds: Double,
            encodeSeconds: Double,
            verifySeconds: Double,
            totalSeconds: Double
        ) {
            self.decodeSeconds = decodeSeconds
            self.renderSeconds = renderSeconds
            self.previewSeconds = previewSeconds
            self.encodeSeconds = encodeSeconds
            self.verifySeconds = verifySeconds
            self.totalSeconds = totalSeconds
        }
    }

    /// One profile's verdict, artifacts and checks.
    public struct ProfileReport: Codable, Equatable, Sendable {
        public let profile: ProfileReference
        public let render: Render
        public let artifacts: Artifacts
        public let checks: [Check]
        public let timings: Timings
        public let pass: Bool
        public let failures: [String]

        public init(
            profile: ProfileReference,
            render: Render,
            artifacts: Artifacts,
            checks: [Check],
            timings: Timings
        ) throws {
            let ordered = try Self.orderedChecks(checks)
            self.profile = profile
            self.render = render
            self.artifacts = artifacts
            self.checks = ordered
            self.timings = timings
            self.failures = ordered.filter { !$0.passed }.map(\.name)
            self.pass = self.failures.isEmpty
        }

        private static func orderedChecks(_ checks: [Check]) throws -> [Check] {
            var seen = Set<String>()
            for check in checks {
                guard DeliveryReport.checkOrder.contains(check.name) else {
                    throw PhotonError.invalidImage(
                        reason: "delivery report has an unknown check '\(check.name)'; documented checks are \(DeliveryReport.checkOrder.joined(separator: ", "))"
                    )
                }
                guard seen.insert(check.name).inserted else {
                    throw PhotonError.invalidImage(reason: "delivery report has a duplicate check '\(check.name)'")
                }
            }
            return DeliveryReport.checkOrder.compactMap { name in checks.first { $0.name == name } }
        }

        private enum CodingKeys: String, CodingKey {
            case profile, render, artifacts, checks, timings, pass, failures
        }

        public init(from decoder: Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let checks = try container.decode([Check].self, forKey: .checks)
            let ordered = try Self.orderedChecks(checks)
            self.profile = try container.decode(ProfileReference.self, forKey: .profile)
            self.render = try container.decode(Render.self, forKey: .render)
            self.artifacts = try container.decode(Artifacts.self, forKey: .artifacts)
            self.checks = ordered
            self.timings = try container.decode(Timings.self, forKey: .timings)
            self.failures = ordered.filter { !$0.passed }.map(\.name)
            self.pass = self.failures.isEmpty
        }
    }

    public let schema: Int
    /// True iff every check of every profile passed. Derived, never set independently.
    public let pass: Bool
    /// `"<profile>: <check>"` for every failed check, in profile then canonical order.
    public let failures: [String]
    public let provenance: Provenance
    public let source: SourceIdentity
    public let recipe: RecipeReference
    public let profiles: [ProfileReport]

    public init(
        provenance: Provenance,
        source: SourceIdentity,
        recipe: RecipeReference,
        profiles: [ProfileReport]
    ) throws {
        guard !profiles.isEmpty else {
            throw PhotonError.invalidImage(reason: "delivery report has no profiles")
        }
        var names = Set<String>()
        for profile in profiles {
            guard names.insert(profile.profile.name).inserted else {
                throw PhotonError.invalidImage(
                    reason: "delivery report has a duplicate profile '\(profile.profile.name)'"
                )
            }
        }
        self.schema = Self.currentSchema
        self.provenance = provenance
        self.source = source
        self.recipe = recipe
        self.profiles = profiles
        self.failures = profiles.flatMap { profile in
            profile.failures.map { "\(profile.profile.name): \($0)" }
        }
        self.pass = self.failures.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case schema, pass, failures, provenance, source, recipe, profiles
    }

    /// Decodes a report and re-derives the verdict, so a hand-edited `pass` cannot survive a read.
    public init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(Int.self, forKey: .schema)
        guard schema == Self.currentSchema else {
            throw DecodingError.dataCorruptedError(
                forKey: .schema,
                in: container,
                debugDescription: "unsupported delivery report schema \(schema); this build understands \(Self.currentSchema)"
            )
        }
        self.schema = schema
        _ = try container.decodeIfPresent(Bool.self, forKey: .pass)
        _ = try container.decodeIfPresent([String].self, forKey: .failures)
        self.provenance = try container.decode(Provenance.self, forKey: .provenance)
        self.source = try container.decode(SourceIdentity.self, forKey: .source)
        self.recipe = try container.decode(RecipeReference.self, forKey: .recipe)
        let profiles = try container.decode([ProfileReport].self, forKey: .profiles)
        self.profiles = profiles
        self.failures = profiles.flatMap { profile in
            profile.failures.map { "\(profile.profile.name): \($0)" }
        }
        self.pass = self.failures.isEmpty
    }

    public func profile(named name: String) -> ProfileReport? {
        profiles.first { $0.profile.name == name }
    }

    /// The check with this name in this profile, if the report has one.
    public func check(profile: String, named name: String) -> Check? {
        self.profile(named: profile)?.checks.first { $0.name == name }
    }

    /// Pretty JSON with sorted keys — the document `appctl deliver` writes as `{stem}.report.json`.
    /// The caller appends the trailing newline (the other sidecars in this repo do the same).
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(self)
        } catch {
            throw PhotonError.writeFailed(path: "report.json", reason: "cannot encode the delivery report: \(error)")
        }
    }
}

/// The facts about the decoded source that the delivery verifier needs, without the 96 MB working
/// buffer. `DeliveryPipeline` builds this from `DecodedSource` so the verifier cannot accidentally
/// re-render the source's colour maths.
public struct DeliverySourceFacts: Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let size: PixelSize
    public let profileName: String?
    public let bitsPerComponent: Int

    public init(path: String, sha256: String, size: PixelSize, profileName: String?, bitsPerComponent: Int) {
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.profileName = profileName
        self.bitsPerComponent = bitsPerComponent
    }
}
