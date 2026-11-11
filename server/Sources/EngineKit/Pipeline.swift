import Foundation

/// Options for one `prepare` run.
public struct PipelineOptions: Sendable {
    /// Defaults to `work/<source sha256>/` relative to the current directory (run the CLI from the repo root).
    public var outputDirectory: URL?
    /// Long edge of the preview HEIC (≤2560 px).
    public var previewLongEdge: Int

    public init(outputDirectory: URL? = nil, previewLongEdge: Int = 2560) {
        self.outputDirectory = outputDirectory
        self.previewLongEdge = previewLongEdge
    }
}

/// Timing breakdown, also written into meta.json.
public struct PipelineTimings: Sendable, Equatable {
    public var decodeSeconds: Double
    public var sdrBaseSeconds: Double
    public var hdrSeconds: Double
    public var previewSeconds: Double
    public var encodeSeconds: Double
    public var metadataSeconds: Double
    public var totalSeconds: Double

    public init() {
        decodeSeconds = 0
        sdrBaseSeconds = 0
        hdrSeconds = 0
        previewSeconds = 0
        encodeSeconds = 0
        metadataSeconds = 0
        totalSeconds = 0
    }
}

/// What a successful `prepare` produced. Paths are absolute.
public struct PrepResult: Sendable {
    public let sourceSHA256: String
    public let recipe: Recipe
    public let outputDirectory: URL
    public let sdrTIFF: URL
    public let hdrTIFF: URL
    public let previewHEIC: URL
    public let metadataJSON: URL
    public let timings: PipelineTimings

    public init(
        sourceSHA256: String,
        recipe: Recipe,
        outputDirectory: URL,
        sdrTIFF: URL,
        hdrTIFF: URL,
        previewHEIC: URL,
        metadataJSON: URL,
        timings: PipelineTimings
    ) {
        self.sourceSHA256 = sourceSHA256
        self.recipe = recipe
        self.outputDirectory = outputDirectory
        self.sdrTIFF = sdrTIFF
        self.hdrTIFF = hdrTIFF
        self.previewHEIC = previewHEIC
        self.metadataJSON = metadataJSON
        self.timings = timings
    }
}

/// The M1 Mac pipeline: decode → SDR base → HDR rendition → preview HEIC → meta.json.
///
/// Outputs (`work/<sha256>/`, docs/archive/stage-1/04-stage-1-plan.md M1): `sdr.tif`, `hdr.tif`,
/// `preview.heic`, `meta.json`.
/// Determinism is a hard contract: same source + recipe ⇒ identical bytes (`DeterminismTests`).
///
/// Replacement is atomic where a reader can race the writer (review P1-7, docs/reference/operations.md): the encoded
/// HEIC is `rename(2)`-ed over `preview.heic` and `meta.json` is written temp-then-rename
/// (`AtomicFile`), so a reader sees either the old file or the new one — never a prefix. The
/// intermediate `sdr.tif`/`hdr.tif` keep their single-write route
/// (docs/archive/stage-1/04-stage-1-plan.md M1 intermediates).
///
/// The default recipe's `source.path` is provenance only and does not enter `Recipe.renderKey()`;
/// `prepare` records it relative to the current working directory when the source lives under it
/// (review P1-6, see `provenancePath(for:)`).
///
/// Encoding is refused and verified, never assumed (review P0-1). A rendition is refused before
/// anything is written when its authored peak is below
/// `EncodedHEICValidator.minimumAuthoredPeak` (`PhotonError.hdrTooDim`) — below that the tool
/// silently writes a plain SDR HEIC — and the same floor is re-checked on the downscaled preview,
/// because Lanczos can average an isolated highlight away. The encoded file is then read back with
/// ImageIO (`EncodedHEICValidator.validate`) before it may replace `preview.heic`
/// (`PhotonError.encoderOutputInvalid`).
///
/// The directory name is the source hash for M1 (docs/archive/stage-1/04-stage-1-plan.md). M2 will key the cache on
/// `hash(source) + hash(recipe)` using `Recipe.renderKey()` — see the note in `PrepResult.recipe`.
public struct Pipeline {
    private let encoderVersion: String
    /// The container writer: the in-process Core Image writer by default; the external tool only
    /// when `appctl prep --encoder` selects the migration oracle.
    private let encoder: HEICEncoder

    /// - Parameters:
    ///   - encoderVersion: the engine identity recorded in the recipe/meta (`coreimage-1`, or the
    ///     oracle's git short sha).
    ///   - encoder: the writer; defaults to `CoreImageHEICEncoder`.
    public init(encoderVersion: String, encoder: HEICEncoder = CoreImageHEICEncoder()) throws {
        self.encoderVersion = encoderVersion
        self.encoder = encoder
    }

    /// The provenance path recorded in a default recipe (review P1-6).
    ///
    /// `source.path` never enters `Recipe.renderKey()`, and this keeps the recorded value stable
    /// for humans too: when the source lives under `base` (the current working directory when
    /// `prepare` runs from the repo root) the path is relative — `fixtures/media/sources/R0003777-P3.tif`
    /// — otherwise the absolute path is kept so a source outside the working tree stays locatable.
    /// `base` is injectable for tests; production always uses the current working directory.
    public static func provenancePath(
        for sourceURL: URL,
        relativeTo base: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) -> String {
        let sourcePath = sourceURL.standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        let prefix = basePath == "/" ? "/" : (basePath.hasSuffix("/") ? basePath : basePath + "/")
        guard sourcePath.hasPrefix(prefix) else { return sourcePath }
        return String(sourcePath.dropFirst(prefix.count))
    }

    /// Runs the pipeline once. When `recipe` is nil, documented defaults are used and returned.
    public func prepare(sourceURL: URL, recipe: Recipe?, options: PipelineOptions) throws -> PrepResult {
        let runStart = Date()
        var timings = PipelineTimings()

        // MARK: 1. Decode the source (fail before touching the output directory).

        var stepStart = Date()
        let source = try SourceDecoder.decode(url: sourceURL)
        timings.decodeSeconds = Date().timeIntervalSince(stepStart)

        // MARK: 2. Resolve the recipe against the decoded source.

        let resolvedRecipe: Recipe
        if let recipe {
            try recipe.validate()
            guard recipe.source.sha256 == source.sha256 else {
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
            resolvedRecipe = recipe
        } else {
            // `source.path` is provenance only (review P1-6): record it cwd-relative when possible,
            // and never let it reach `renderKey()`.
            resolvedRecipe = Recipe.defaults(
                sourcePath: Self.provenancePath(for: sourceURL),
                sourceSHA256: source.sha256,
                width: source.size.width,
                height: source.size.height,
                encoderVersion: encoderVersion
            )
        }

        let toneMap = try ToneMapKind.named(resolvedRecipe.base.toneMap)

        // MARK: 3. SDR base — the authoritative Capture One look, untouched.

        stepStart = Date()
        let sdrBase = try ToneMapper.sdrBase(from: source.linear, toneMap: toneMap)
        timings.sdrBaseSeconds = Date().timeIntervalSince(stepStart)

        // MARK: 4. HDR rendition — authored lift, clamped to the recipe cap.

        stepStart = Date()
        let shape = try HighlightShape(recipe: resolvedRecipe.hdr)
        let hdrRendition = try HDRRendition.render(base: sdrBase, shape: shape)
        timings.hdrSeconds = Date().timeIntervalSince(stepStart)

        // MARK: 5. Refuse a rendition the encoder can only degrade to plain SDR.

        // `toGainMapHDR` exits 0 even when the pair carries no headroom: a legal P3 source plus
        // the default recipe (start 0.62 above the image's own peak) makes the highlight mask
        // all-zero and the tool writes a plain SDR HEIC with no ISO gain map (review P0-1).
        // Below the floor this is an explicit refusal, not a silent downgrade — and it happens
        // before the output directory exists, so a refused run leaves no half-products behind.
        guard hdrRendition.authoredPeak >= EncodedHEICValidator.minimumAuthoredPeak else {
            throw PhotonError.hdrTooDim(
                peak: hdrRendition.authoredPeak,
                minimum: EncodedHEICValidator.minimumAuthoredPeak
            )
        }

        // MARK: 6. Output directory.

        let outputDirectory = (options.outputDirectory
            ?? URL(fileURLWithPath: "work/\(source.sha256)")).standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw PhotonError.writeFailed(path: outputDirectory.path, reason: "cannot create output directory: \(error)")
        }

        let sdrTIFF = outputDirectory.appendingPathComponent("sdr.tif")
        let hdrTIFF = outputDirectory.appendingPathComponent("hdr.tif")
        let previewHEIC = outputDirectory.appendingPathComponent("preview.heic")
        let metadataJSON = outputDirectory.appendingPathComponent("meta.json")

        // MARK: 7. Intermediate TIFFs (16-bit 3-channel base, 32-bit float RGBAf HDR).

        try TIFFWriter.writeSDRBase(sdrBase, to: sdrTIFF)
        try TIFFWriter.writeHDR(hdrRendition.image, to: hdrTIFF)

        // MARK: 8. Preview HEIC — same encoder, same flags, Lanczos re-clamped to the cap.
        //
        // Geometry and the peak floor are checked BEFORE the encoder is resolved: a preview that
        // collapses an isolated highlight below the floor has no gain map to encode, and that
        // refusal must be reachable (and testable) with no encoder installed.

        stepStart = Date()
        let previewLongEdge = PreviewRenderer.previewLongEdge(
            for: source.size,
            limit: options.previewLongEdge
        )
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

        // The preview is a development/regression artifact: an 8-bit, full-res, ISO RGB profile of
        // the downscaled pair. The delivery profiles are independent of this.
        let previewOptions = try HEICEncodeOptions(
            bitDepth: .eight,
            quality: resolvedRecipe.encoder.quality,
            mapResolution: .full,
            mapKind: .isoRGB
        )
        let stagingDirectory = outputDirectory.appendingPathComponent(".preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }
        let stagingPreview = stagingDirectory.appendingPathComponent("preview.heic")
        timings.previewSeconds = Date().timeIntervalSince(stepStart)

        stepStart = Date()
        let encodedPreview = try encoder.encode(
            HEICEncodeRequest(
                sdrBase: previewPair.base,
                hdrRendition: previewPair.hdr,
                authoredPeak: previewPeak,
                options: previewOptions,
                sourceURL: source.url,
                hdrOutputURL: stagingPreview,
                sdrOutputURL: nil
            )
        ).hdrHEIC
        timings.encodeSeconds = Date().timeIntervalSince(stepStart)

        // Read the encoded HEIC back before it is allowed to become `preview.heic`: the read-back
        // is the structural gate, never the writer's return value.
        _ = try EncodedHEICValidator.validate(
            encodedPreview,
            expectedSize: previewPair.size
        )
        // Same-volume rename over the previous preview: never "remove, then move" (review P1-7).
        try AtomicFile.replace(encodedPreview, with: previewHEIC)

        // MARK: 9. meta.json — pretty, sorted keys, atomic.
        //
        // A meta.json cannot contain the exact cost of writing itself: build + encode it once to
        // measure `metadata_seconds`, then write the document with those final numbers. The
        // returned timings match the file; only the final write (~1 ms) is excluded.

        stepStart = Date()
        func buildMetadata() -> PrepMetadata {
            makeMetadata(
                source: source,
                recipe: resolvedRecipe,
                sdrTIFF: sdrTIFF,
                hdrTIFF: hdrTIFF,
                previewHEIC: previewHEIC,
                hdrRendition: hdrRendition,
                toneMap: toneMap,
                encoderVersion: encoderVersion,
                previewOptions: previewOptions,
                timings: timings
            )
        }
        _ = try encodeJSON(buildMetadata())
        timings.metadataSeconds = Date().timeIntervalSince(stepStart)
        timings.totalSeconds = Date().timeIntervalSince(runStart)
        // `AtomicFile.write` is the temp-then-rename step; the trailing newline is part of the
        // document (pretty JSON has no final newline of its own).
        try AtomicFile.write(try encodeJSON(buildMetadata()) + Data("\n".utf8), to: metadataJSON)

        return PrepResult(
            sourceSHA256: source.sha256,
            recipe: resolvedRecipe,
            outputDirectory: outputDirectory,
            sdrTIFF: sdrTIFF,
            hdrTIFF: hdrTIFF,
            previewHEIC: previewHEIC,
            metadataJSON: metadataJSON,
            timings: timings
        )
    }

    // MARK: - meta.json

    /// Field names live in `PrepMetadata` (M2's contract). `OutputFile.path` is the file name
    /// relative to `meta.json`'s own directory, so an output folder can be moved/renamed whole.
    private func makeMetadata(
        source: DecodedSource,
        recipe: Recipe,
        sdrTIFF: URL,
        hdrTIFF: URL,
        previewHEIC: URL,
        hdrRendition: HDRRendition.Result,
        toneMap: ToneMapKind,
        encoderVersion: String,
        previewOptions: HEICEncodeOptions,
        timings: PipelineTimings
    ) -> PrepMetadata {
        let sourceInfo = PrepMetadata.SourceInfo(
            path: source.url.standardizedFileURL.path,
            sha256: source.sha256,
            width: source.size.width,
            height: source.size.height,
            profileName: source.profileName,
            bitsPerComponent: source.bitsPerComponent
        )
        let outputs = PrepMetadata.Outputs(
            sdrTIFF: outputFile(sdrTIFF),
            hdrTIFF: outputFile(hdrTIFF),
            previewHEIC: outputFile(previewHEIC)
        )
        let authoredPeak = Double(hdrRendition.authoredPeak)
        let render = PrepMetadata.RenderInfo(
            toneMap: toneMap.name,
            start: recipe.hdr.start,
            liftStops: recipe.hdr.liftStops,
            transition: recipe.hdr.transition,
            headroomCapLinear: recipe.hdr.headroomCap,
            authoredPeakLinear: authoredPeak,
            authoredPeakStops: authoredPeak > 0 ? log2(authoredPeak) : 0,
            fractionAboveOne: hdrRendition.fractionAboveOne,
            fractionAtCap: hdrRendition.fractionAtCap
        )
        // The encoder block records what actually ran — the selected writer (`--encoder` oracle or
        // the in-process Core Image writer) and the preview encode's own profile (fixed 8-bit,
        // full-res ISO RGB; the delivery profiles are independent of this).
        let encoderInfo = PrepMetadata.EncoderInfo(
            tool: encoder.identity.tool,
            executable: encoder.identity.executable,
            version: encoderVersion,
            quality: previewOptions.quality,
            depth: previewOptions.bitDepth.rawValue,
            headroomCapArg: recipe.hdr.headroomCap,
            elapsedSeconds: timings.encodeSeconds
        )
        let metadataTimings = PrepMetadata.Timings(
            decodeSeconds: timings.decodeSeconds,
            sdrBaseSeconds: timings.sdrBaseSeconds,
            hdrSeconds: timings.hdrSeconds,
            previewSeconds: timings.previewSeconds,
            encodeSeconds: timings.encodeSeconds,
            metadataSeconds: timings.metadataSeconds,
            totalSeconds: timings.totalSeconds
        )
        return PrepMetadata(
            source: sourceInfo,
            recipe: recipe,
            outputs: outputs,
            render: render,
            encoder: encoderInfo,
            timings: metadataTimings
        )
    }

    private func outputFile(_ url: URL) -> PrepMetadata.OutputFile {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let hash = (try? SourceDecoder.sha256(ofFileAt: url)) ?? ""
        return PrepMetadata.OutputFile(path: url.lastPathComponent, bytes: bytes, sha256: hash)
    }

    // MARK: - File helpers

    /// Pretty JSON with sorted keys; the data the atomic writer receives.
    /// The trailing newline is appended by the caller so it stays out of the timing measurement.
    private func encodeJSON(_ metadata: PrepMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(metadata)
        } catch {
            throw PhotonError.writeFailed(path: "meta.json", reason: "cannot encode metadata: \(error)")
        }
    }
}
