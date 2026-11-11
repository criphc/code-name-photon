import CryptoKit
import Foundation

/// Options for one `appctl deliver` run (docs/reference/deliver.md, delivery contract).
///
/// Everything here is an input to one delivery; the pipeline itself is stateless, so the CLI can
/// build a configuration per invocation and tests can drive it with temporary directories.
public struct DeliveryConfiguration: Sendable {
    /// The source whose identity the recipe must match (resolved by the CLI from an item id or
    /// `--source`). This is the only way a delivery starts.
    public var sourcePath: URL
    /// The recipe to apply. `nil` = the recipe the M3 client stored at
    /// `<workDirectory>/<source sha256>/recipe.json`.
    public var recipePath: URL?
    /// Per-item state root: `work/` in production. Holds the stored recipe and receives the
    /// staging / rejected diagnostics.
    public var workDirectory: URL
    /// Flat delivery folder (`out/` by default): the profile HEICs, the shared SDR fallback, the
    /// recipe echo and the report are installed here.
    public var outputDirectory: URL
    /// The requested output profiles. Empty = the recipe's `encoder` block (one profile).
    public var profiles: [HEICEncodeOptions]
    /// Encoder identity recorded in the report (`coreimage-1`, or the oracle's git short sha).
    public var encoderVersion: String
    /// Long edge for the `previewAgreement` render (2560 is the M3 preview edge).
    public var previewLongEdge: Int
    /// Delivery build identity recorded in the report.
    public var appVersion: String

    public init(
        sourcePath: URL,
        recipePath: URL? = nil,
        workDirectory: URL = URL(fileURLWithPath: "work", isDirectory: true),
        outputDirectory: URL = URL(fileURLWithPath: "out", isDirectory: true),
        profiles: [HEICEncodeOptions] = [],
        encoderVersion: String = "coreimage-1",
        previewLongEdge: Int = 2560,
        appVersion: String = DeliveryReport.Provenance.currentVersion
    ) {
        self.sourcePath = sourcePath
        self.recipePath = recipePath
        self.workDirectory = workDirectory
        self.outputDirectory = outputDirectory
        self.profiles = profiles
        self.encoderVersion = encoderVersion
        self.previewLongEdge = previewLongEdge
        self.appVersion = appVersion
    }
}

/// The files the delivery installs into `--out`: one HDR HEIC per profile, one shared 8-bit SDR
/// fallback, the recipe echo and the report.
public struct DeliveryArtifacts: Sendable, Equatable {
    /// Profile name (`10-half-rgb`) → installed HDR file.
    public let hdrHEICs: [String: URL]
    public let sdrHEIC: URL
    public let recipeJSON: URL
    public let reportJSON: URL

    public init(hdrHEICs: [String: URL], sdrHEIC: URL, recipeJSON: URL, reportJSON: URL) {
        self.hdrHEICs = hdrHEICs
        self.sdrHEIC = sdrHEIC
        self.recipeJSON = recipeJSON
        self.reportJSON = reportJSON
    }
}

/// What one successful delivery produced. `report.pass` is necessarily true here (a failing report
/// installs nothing and throws `PhotonError.deliveryVerificationFailed`).
public struct DeliveryOutcome: Sendable {
    public let sourceSHA256: String
    public let renderKey: String
    public let report: DeliveryReport
    public let artifacts: DeliveryArtifacts

    public init(sourceSHA256: String, renderKey: String, report: DeliveryReport, artifacts: DeliveryArtifacts) {
        self.sourceSHA256 = sourceSHA256
        self.renderKey = renderKey
        self.report = report
        self.artifacts = artifacts
    }
}

/// The v2 delivery job: recipe → one shared render context → one encode + verify per profile →
/// one report → fail-closed install (docs/reference/deliver.md).
///
/// The expensive work (decode, SDR base, HDR rendition, preview pair) is done **once**; the
/// per-profile work is the gain map/encode and the verifier. All profiles share the 8-bit SDR
/// fallback and the recipe echo. The install is fail-closed: any failed check in any profile
/// installs nothing and moves the whole staging set to `work/<sha>/rejected/<renderKey12>/`.
public struct DeliveryPipeline {
    /// One verification pass for one profile. Injectable only so tests can prove the fail-closed
    /// rule without hand-crafting a defective HEIC.
    public typealias Verification = (DeliveryVerificationInput) throws -> [DeliveryReport.Check]

    private let encoder: HEICEncoder
    private let verification: Verification

    public init(
        encoder: HEICEncoder = CoreImageHEICEncoder(),
        verification: @escaping Verification = DeliveryVerifier.verify
    ) {
        self.encoder = encoder
        self.verification = verification
    }

    public func deliver(_ configuration: DeliveryConfiguration) throws -> DeliveryOutcome {
        let runStart = Date()
        let sourcePath = configuration.sourcePath.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourcePath.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw PhotonError.sourceUnreadable(
                path: sourcePath.path,
                reason: "source does not exist or is not a regular file"
            )
        }

        // MARK: 1. Decode + resolve the stored recipe

        var stepStart = Date()
        let source = try SourceDecoder.decode(url: sourcePath)
        let decodeSeconds = Date().timeIntervalSince(stepStart)

        let recipeURL = try resolveRecipeURL(for: source, configuration: configuration)
        let recipe = try loadRecipe(from: recipeURL)
        try recipe.validate()

        guard recipe.source.sha256.lowercased() == source.sha256 else {
            throw PhotonError.sourceHashMismatch(expected: recipe.source.sha256, actual: source.sha256)
        }
        guard recipe.source.width == source.size.width, recipe.source.height == source.size.height else {
            throw PhotonError.dimensionMismatch(
                expectedWidth: recipe.source.width,
                expectedHeight: recipe.source.height,
                actualWidth: source.size.width,
                actualHeight: source.size.height
            )
        }
        let toneMap = try ToneMapKind.named(recipe.base.toneMap)
        let shape = try HighlightShape(recipe: recipe.hdr)
        let renderKey: String
        do {
            renderKey = try recipe.renderKey()
        } catch {
            throw PhotonError.invalidRecipe(field: "recipe", reason: "cannot compute renderKey: \(error)")
        }

        // MARK: 2. One shared render context

        stepStart = Date()
        let sdrBase = try ToneMapper.sdrBase(from: source.linear, toneMap: toneMap)
        let hdrRendition = try HDRRendition.render(base: sdrBase, shape: shape)
        let renderSeconds = Date().timeIntervalSince(stepStart)

        guard hdrRendition.authoredPeak >= EncodedHEICValidator.minimumAuthoredPeak else {
            throw PhotonError.hdrTooDim(
                peak: hdrRendition.authoredPeak,
                minimum: EncodedHEICValidator.minimumAuthoredPeak
            )
        }

        stepStart = Date()
        let previewLongEdge = PreviewRenderer.previewLongEdge(for: source.size, limit: configuration.previewLongEdge)
        let previewPair = try PreviewRenderer.downscale(
            base: sdrBase,
            hdr: hdrRendition.image,
            longEdge: previewLongEdge,
            headroomCap: shape.headroomCap
        )
        let previewPeak = previewPair.hdr.maxChannel
        guard previewPeak >= EncodedHEICValidator.minimumAuthoredPeak else {
            throw PhotonError.hdrTooDim(
                peak: previewPeak,
                minimum: EncodedHEICValidator.minimumAuthoredPeak
            )
        }
        let previewSeconds = Date().timeIntervalSince(stepStart)

        // MARK: 3. Profiles

        let profiles = try resolveProfiles(configuration: configuration, recipe: recipe)

        // MARK: 4. Staging: one shared fallback/recipe echo, one HDR file per profile

        let stem = sourcePath.deletingPathExtension().lastPathComponent
        let itemWorkDirectory = configuration.workDirectory.standardizedFileURL
            .appendingPathComponent(source.sha256, isDirectory: true)
        let stagingDirectory = itemWorkDirectory
            .appendingPathComponent("delivery", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createDirectory(stagingDirectory)

        var stagingMovedToEvidence = false
        defer {
            if !stagingMovedToEvidence {
                try? FileManager.default.removeItem(at: stagingDirectory)
            }
        }

        let fallbackURL = stagingDirectory.appendingPathComponent("\(stem)-sdr.heic")
        let recipeEchoURL = stagingDirectory.appendingPathComponent("\(stem).recipe.json")
        let recipeEchoData: Data
        do {
            recipeEchoData = try recipe.canonicalJSON()
        } catch {
            throw PhotonError.writeFailed(path: recipeEchoURL.path, reason: "cannot encode the recipe echo: \(error)")
        }
        try AtomicFile.write(recipeEchoData, to: recipeEchoURL)
        let recipeArtifact = DeliveryReport.FileArtifact(
            file: "\(stem).recipe.json",
            bytes: recipeEchoData.count,
            sha256: sha256Hex(recipeEchoData)
        )

        let reportSource = DeliveryReport.SourceIdentity(
            path: Pipeline.provenancePath(for: sourcePath),
            sha256: source.sha256,
            width: source.size.width,
            height: source.size.height,
            profileName: source.profileName,
            bitsPerComponent: source.bitsPerComponent
        )
        let reportRecipe = DeliveryReport.RecipeReference(recipe: recipe, renderKey: renderKey)
        let reportRender = DeliveryReport.Render(
            width: source.size.width,
            height: source.size.height,
            headroomCap: recipe.hdr.headroomCap,
            authoredPeak: Double(hdrRendition.authoredPeak),
            fractionAboveOne: hdrRendition.fractionAboveOne,
            fractionAtCap: hdrRendition.fractionAtCap,
            previewLongEdge: previewLongEdge
        )

        var profileReports: [DeliveryReport.ProfileReport] = []
        for (index, options) in profiles.enumerated() {
            let hdrURL = stagingDirectory.appendingPathComponent("\(stem)-hdr-\(options.profileName).heic")
            let request = HEICEncodeRequest(
                sdrBase: sdrBase,
                hdrRendition: hdrRendition.image,
                authoredPeak: hdrRendition.authoredPeak,
                options: options,
                sourceURL: source.url,
                hdrOutputURL: hdrURL,
                sdrOutputURL: index == 0 ? fallbackURL : nil
            )
            let encodeStart = Date()
            let result = try encoder.encode(request)
            let encodeSeconds = Date().timeIntervalSince(encodeStart)

            let verifyStart = Date()
            let checks = try verification(
                DeliveryVerificationInput(
                    encodedHEIC: result.hdrHEIC,
                    fallbackHEIC: fallbackURL,
                    sdrBase: sdrBase,
                    authoredPeak: hdrRendition.authoredPeak,
                    fractionAboveOne: hdrRendition.fractionAboveOne,
                    fractionAtCap: hdrRendition.fractionAtCap,
                    preview: previewPair,
                    previewLongEdge: previewLongEdge,
                    recipe: recipe,
                    source: DeliverySourceFacts(
                        path: source.url.standardizedFileURL.path,
                        sha256: source.sha256,
                        size: source.size,
                        profileName: source.profileName,
                        bitsPerComponent: source.bitsPerComponent
                    ),
                    profile: options
                )
            )
            let verifySeconds = Date().timeIntervalSince(verifyStart)

            let hdrArtifact = try fileArtifact(for: result.hdrHEIC, named: "\(stem)-hdr-\(options.profileName).heic")
            let fallbackArtifact = try fileArtifact(for: fallbackURL, named: "\(stem)-sdr.heic")
            let profileReport = try DeliveryReport.ProfileReport(
                profile: DeliveryReport.ProfileReference(options: options),
                render: reportRender,
                artifacts: DeliveryReport.Artifacts(
                    hdrHEIC: hdrArtifact,
                    sdrHEIC: fallbackArtifact,
                    recipeJSON: recipeArtifact
                ),
                checks: checks,
                timings: DeliveryReport.Timings(
                    decodeSeconds: decodeSeconds,
                    renderSeconds: renderSeconds,
                    previewSeconds: previewSeconds,
                    encodeSeconds: encodeSeconds,
                    verifySeconds: verifySeconds,
                    totalSeconds: decodeSeconds + renderSeconds + previewSeconds + encodeSeconds + verifySeconds
                )
            )
            profileReports.append(profileReport)
        }

        // MARK: 5. One report, fail-closed

        let report = try DeliveryReport(
            provenance: DeliveryReport.Provenance(
                appVersion: configuration.appVersion,
                encoderVersion: configuration.encoderVersion
            ),
            source: reportSource,
            recipe: reportRecipe,
            profiles: profileReports
        )
        let reportURL = stagingDirectory.appendingPathComponent("\(stem).report.json")
        try AtomicFile.write(try report.jsonData() + Data("\n".utf8), to: reportURL)

        guard report.pass else {
            let evidence = try moveStagingToEvidence(
                stagingDirectory,
                itemWorkDirectory: itemWorkDirectory,
                renderKey: renderKey
            )
            stagingMovedToEvidence = true
            let evidenceReportURL = evidence.appendingPathComponent("\(stem).report.json")
            throw PhotonError.deliveryVerificationFailed(
                reportPath: evidenceReportURL.path,
                failures: report.failures
            )
        }

        // MARK: 6. Install — only when every profile passed

        let rehashedSource = try SourceDecoder.sha256(ofFileAt: sourcePath)
        guard rehashedSource == source.sha256 else {
            throw PhotonError.sourceHashMismatch(expected: source.sha256, actual: rehashedSource)
        }

        let outputDirectory = configuration.outputDirectory.standardizedFileURL
        try createDirectory(outputDirectory)
        var installedHDRs: [String: URL] = [:]
        for (index, options) in profiles.enumerated() {
            let staged = stagingDirectory.appendingPathComponent("\(stem)-hdr-\(options.profileName).heic")
            installedHDRs[options.profileName] = try installFile(
                staged, named: "\(stem)-hdr-\(options.profileName).heic", into: outputDirectory
            )
            _ = index
        }
        let installedFallback = try installFile(fallbackURL, named: "\(stem)-sdr.heic", into: outputDirectory)
        let installedRecipe = try installFile(recipeEchoURL, named: "\(stem).recipe.json", into: outputDirectory)
        let installedReport = try installFile(reportURL, named: "\(stem).report.json", into: outputDirectory)

        return DeliveryOutcome(
            sourceSHA256: source.sha256,
            renderKey: renderKey,
            report: report,
            artifacts: DeliveryArtifacts(
                hdrHEICs: installedHDRs,
                sdrHEIC: installedFallback,
                recipeJSON: installedRecipe,
                reportJSON: installedReport
            )
        )
    }

    // MARK: - Profiles

    private func resolveProfiles(
        configuration: DeliveryConfiguration,
        recipe: Recipe
    ) throws -> [HEICEncodeOptions] {
        let requested = configuration.profiles.isEmpty
            ? [try HEICEncodeOptions(recipe: recipe)]
            : configuration.profiles
        var seen = Set<String>()
        for options in requested {
            guard seen.insert(options.profileName).inserted else {
                throw PhotonError.invalidRecipe(
                    field: "profile",
                    reason: "duplicate profile '\(options.profileName)'"
                )
            }
        }
        return requested
    }

    // MARK: - Recipe loading

    private func resolveRecipeURL(
        for source: DecodedSource,
        configuration: DeliveryConfiguration
    ) throws -> URL {
        if let explicit = configuration.recipePath {
            let url = explicit.standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PhotonError.invalidRecipe(
                    field: "recipe",
                    reason: "recipe file '\(url.path)' does not exist"
                )
            }
            return url
        }
        let stored = configuration.workDirectory.standardizedFileURL
            .appendingPathComponent(source.sha256, isDirectory: true)
            .appendingPathComponent("recipe.json")
        guard FileManager.default.fileExists(atPath: stored.path) else {
            throw PhotonError.invalidRecipe(
                field: "recipe",
                reason: "no stored recipe at '\(stored.path)'; post one from the iPad (M3) or pass --recipe <file>"
            )
        }
        return stored
    }

    private func loadRecipe(from url: URL) throws -> Recipe {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PhotonError.invalidRecipe(
                field: "recipe",
                reason: "cannot read '\(url.path)': \(error.localizedDescription)"
            )
        }
        do {
            return try JSONDecoder().decode(Recipe.self, from: data)
        } catch {
            throw PhotonError.invalidRecipe(field: "recipe", reason: "cannot decode '\(url.path)': \(error)")
        }
    }

    // MARK: - Assembly helpers

    /// A file of the delivery set: name relative to `--out`, byte size, content hash.
    private func fileArtifact(for url: URL, named name: String) throws -> DeliveryReport.FileArtifact {
        let bytes: Int
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            throw PhotonError.writeFailed(path: url.path, reason: "cannot stat the delivery artifact: \(error)")
        }
        let hash: String
        do {
            hash = try SourceDecoder.sha256(ofFileAt: url)
        } catch {
            throw PhotonError.writeFailed(path: url.path, reason: "cannot hash the delivery artifact: \(error)")
        }
        return DeliveryReport.FileArtifact(file: name, bytes: bytes, sha256: hash)
    }

    private func sha256Hex(_ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Filesystem helpers

    private func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw PhotonError.writeFailed(path: url.path, reason: "cannot create directory: \(error)")
        }
    }

    /// Moves a rejected staging directory under `work/<sha>/rejected/<renderKey12>/` and returns
    /// the destination. The destination is replaced, not merged: a re-run of the same failing
    /// recipe must show this run's diagnosis, not a mix of both.
    private func moveStagingToEvidence(
        _ stagingDirectory: URL,
        itemWorkDirectory: URL,
        renderKey: String
    ) throws -> URL {
        let rejectedRoot = itemWorkDirectory.appendingPathComponent("rejected", isDirectory: true)
        let destination = rejectedRoot.appendingPathComponent(String(renderKey.prefix(12)), isDirectory: true)
        try createDirectory(rejectedRoot)
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                try FileManager.default.removeItem(at: destination)
            } catch {
                throw PhotonError.writeFailed(
                    path: destination.path,
                    reason: "cannot clear the previous rejected evidence: \(error)"
                )
            }
        }
        do {
            try FileManager.default.moveItem(at: stagingDirectory, to: destination)
        } catch {
            throw PhotonError.writeFailed(
                path: destination.path,
                reason: "cannot move the staging directory to the rejected evidence folder: \(error)"
            )
        }
        return destination
    }

    /// Copies `source` to a hidden temp file **inside** `directory` and `rename(2)`s it over the
    /// destination: the destination never disappears and a reader never sees a partial file.
    private func installFile(_ source: URL, named name: String, into directory: URL) throws -> URL {
        let destination = directory.appendingPathComponent(name)
        let temporary = directory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
        } catch {
            throw PhotonError.writeFailed(path: destination.path, reason: "cannot stage \(name): \(error)")
        }
        do {
            try AtomicFile.replace(temporary, with: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        return destination
    }
}
