import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reusable ImageIO / Core Image analysis for the M4 delivery report (docs/reference/deliver.md, report schema 1).
///
/// The verifier is an *analysis* layer, never a second renderer: it reads the encoded HEIC back
/// with ImageIO (never `sips`, which silently strips gain maps — docs/reference/container.md), compares it with the
/// buffers the pipeline still holds, and formats the named checks. This file owns the parts that
/// touch pixels:
///
/// - the container facts ImageIO does not expose (`ftyp` major/compatible brands, needed for the
///   ISO 21496-1 `tmap` check);
/// - strip-wise rendering to linear extended Display P3 float32 / 8-bit Display P3, so a 24 Mpx
///   comparison never allocates two full float buffers (a few hundred rows are in flight at once);
/// - ΔE2000 and 8-bit absolute-difference distributions with a fixed histogram (no per-pixel
///   array of 24 M doubles);
/// - the ImageIO map-stripped SDR fallback copy (`CGImageDestination`, no auxiliary data, no EXIF
///   timestamps — deterministic bytes for the same input, docs/reference/deliver.md, delivery contract determinism gate).
///
/// Row orientation is pinned, not assumed. `CIContext.render(…, toBitmap:, bounds:)` writes the
/// first destination row as the *top* of the requested bounds (Core Image's y axis grows up), so
/// without care a strip render of rows `[y, y+rows)` lands upside down relative to row 0 of a
/// `LinearImage` from `SourceDecoder.decode` (which renders the whole image in one call). The
/// strip helper below always computes `ciY = height - blockStart - rows`, which makes destination
/// row `r` correspond to reference row `blockStart + r`; `DeliveryVerifierTests` pins that mapping
/// with a two-row fixture so a refactor cannot silently flip the base comparison.
public enum DeliveryImageProbe {
    // MARK: - ISO-BMFF `ftyp` (the container check ImageIO cannot answer)

    /// The leading `ftyp` box of an ISO-BMFF file: the brands that tell a HEIF/ISO 21496-1 file
    /// apart from a JPEG or a bare HEVC bitstream.
    public struct FTYP: Equatable, Sendable {
        public let majorBrand: String
        public let minorVersion: UInt32
        /// All compatible brands, in file order.
        public let compatibleBrands: [String]
        /// The declared box size (bytes).
        public let boxSize: Int

        /// The major brand is in the HEIF (ISO/IEC 23008-12) family.
        public var isHEIF: Bool { DeliveryImageProbe.heifBrands.contains(majorBrand) }

        /// The ISO 21496-1 gain-map dialect is signalled by a compatible `tmap` brand.
        public var hasTMap: Bool { compatibleBrands.contains("tmap") || majorBrand == "tmap" }
    }

    /// HEIF brand family (ISO/IEC 23008-12): single image, image sequence, 10-bit variants and the
    /// MIAF (`mif1`/`msf1`) wrapper brands. The encoder's `-b` output declares major brand `heic`.
    public static let heifBrands: Set<String> = [
        "heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "mif2", "msf1",
    ]

    /// Parses only the leading `ftyp` box. `maxBytes` bounds the read (an `ftyp` box is tiny).
    ///
    /// - Throws: `PhotonError.encoderOutputInvalid` for an unreadable/truncated file or when the
    ///   first box is not `ftyp` (not an ISO-BMFF image). A malformed file is a failed *check*,
    ///   never a crash.
    public static func readFTYP(_ url: URL, maxBytes: Int = 4096) throws -> FTYP {
        let path = url.standardizedFileURL.path
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw PhotonError.encoderOutputInvalid(path: path, reason: "cannot open the file to read its ftyp box: \(error)")
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maxBytes) ?? Data()
        } catch {
            throw PhotonError.encoderOutputInvalid(path: path, reason: "cannot read the file to read its ftyp box: \(error)")
        }
        return try parseFTYP(data, path: path)
    }

    /// In-memory variant (tests, and the `ftyp` reader's truncated/non-BMFF cases).
    public static func readFTYP(_ data: Data) throws -> FTYP {
        try parseFTYP(data, path: "<memory>")
    }

    private static func parseFTYP(_ data: Data, path: String) throws -> FTYP {
        let bytes = [UInt8](data)
        guard bytes.count >= 16 else {
            throw PhotonError.encoderOutputInvalid(
                path: path,
                reason: "truncated ISO-BMFF: \(bytes.count) bytes, shorter than the 16-byte ftyp header"
            )
        }
        let boxType = fourCC(bytes, 4)
        guard boxType == "ftyp" else {
            throw PhotonError.encoderOutputInvalid(
                path: path,
                reason: "the first ISO-BMFF box is '\(boxType)', not 'ftyp': not an ISO-BMFF/HEIF image"
            )
        }
        let declared = Int(be32(bytes, 0))
        guard declared >= 16 else {
            throw PhotonError.encoderOutputInvalid(
                path: path,
                reason: "malformed ftyp box size \(declared) (< 16)"
            )
        }
        guard declared <= bytes.count else {
            throw PhotonError.encoderOutputInvalid(
                path: path,
                reason: "truncated ISO-BMFF: ftyp box declares \(declared) bytes, only \(bytes.count) available"
            )
        }
        guard (declared - 16) % 4 == 0 else {
            throw PhotonError.encoderOutputInvalid(
                path: path,
                reason: "malformed ftyp box: \(declared - 16) compatible-brand bytes is not a multiple of 4"
            )
        }
        var brands: [String] = []
        var offset = 16
        while offset + 4 <= declared {
            brands.append(fourCC(bytes, offset))
            offset += 4
        }
        return FTYP(
            majorBrand: fourCC(bytes, 8),
            minorVersion: be32(bytes, 12),
            compatibleBrands: brands,
            boxSize: declared
        )
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func fourCC(_ bytes: [UInt8], _ offset: Int) -> String {
        let slice = bytes[offset..<offset + 4]
        return String(bytes: slice, encoding: .isoLatin1) ?? "?"
    }

    // MARK: - Decoded delivery (one decode for every pixel check)

    /// The two decodes of the delivered HEIC plus the container facts.
    ///
    /// `sdr` is ImageIO's plain primary decode (what an SDR-only viewer shows); `hdr` is the
    /// `kCGImageSourceDecodeToHDR` decode (nil when the file has no gain map to apply). Both are
    /// produced by a single `CGImageSource`, so the `alpha`/`headroom`/`clipping` checks all read
    /// the same file state.
    public struct DecodedDelivery {
        public let url: URL
        public let facts: EncodedHEICFacts
        public let sdr: CGImage
        public let hdr: CGImage?

        public var sdrSize: PixelSize { PixelSize(width: sdr.width, height: sdr.height) }
        public var sdrAlphaInfo: CGImageAlphaInfo { sdr.alphaInfo }
        public var hdrAlphaInfo: CGImageAlphaInfo? { hdr?.alphaInfo }
        public var sdrAlphaInfoName: String { DeliveryImageProbe.alphaInfoName(sdr.alphaInfo) }
        public var hdrAlphaInfoName: String {
            guard let hdr else { return "absent" }
            return DeliveryImageProbe.alphaInfoName(hdr.alphaInfo)
        }
    }

    /// Opens `url` once and returns the facts plus both decoded images.
    ///
    /// - Throws: `PhotonError.encoderOutputInvalid` when the file cannot be opened or the SDR
    ///   image cannot be decoded. That is the verifier's only legitimate throw: everything else
    ///   is a failed check (the pipeline has already read the file back at the encoder gate).
    public static func decode(_ url: URL) throws -> DecodedDelivery {
        let path = url.standardizedFileURL.path
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw PhotonError.encoderOutputInvalid(
                path: path,
                reason: "ImageIO cannot open the file (missing, or not a recognised image)"
            )
        }
        let (facts, sdr, hdr) = try EncodedHEICValidator.inspect(source, path: path)
        return DecodedDelivery(url: url, facts: facts, sdr: sdr, hdr: hdr)
    }

    // MARK: - Alpha layout naming (report `measured` strings)

    public static func alphaInfoName(_ info: CGImageAlphaInfo) -> String {
        switch info {
        case .none: return "none"
        case .premultipliedLast: return "premultipliedLast"
        case .premultipliedFirst: return "premultipliedFirst"
        case .last: return "last"
        case .first: return "first"
        case .noneSkipLast: return "noneSkipLast"
        case .noneSkipFirst: return "noneSkipFirst"
        case .alphaOnly: return "alphaOnly"
        @unknown default: return "unknown(\(info.rawValue))"
        }
    }

    /// `.none` / `.noneSkipLast` / `.noneSkipFirst` carry no alpha samples (decision 5).
    public static func hasAlpha(_ info: CGImageAlphaInfo) -> Bool {
        switch info {
        case .none, .noneSkipLast, .noneSkipFirst: return false
        default: return true
        }
    }

    /// Raw-value form for `EncodedHEICFacts.hdrAlphaInfoRaw`; `-1` (no HDR decode) is reported as
    /// alpha-bearing so a check that forgets to handle the missing decode fails closed.
    public static func hasAlpha(rawValue: Int) -> Bool {
        guard rawValue >= 0, let info = CGImageAlphaInfo(rawValue: UInt32(rawValue)) else { return true }
        return hasAlpha(info)
    }

    // MARK: - Colour spaces and contexts

    /// Linear extended Display P3 — the Stage-1 working space.
    static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    /// Display P3 (nonlinear, ICC) — the delivered base's colour space.
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// A context whose working and output spaces are the working space, so a render to `.RGBAf`
    /// performs no output conversion (`verify-heic` uses the same options).
    public static func makeContext() -> CIContext {
        // One shared context: a cold GPU context's first render is the flaky stage
        // (docs/plans/preview-agreement-investigation.md).
        CIRender.sharedContext
    }

    // MARK: - Distributions

    /// ΔE2000 distribution over pixels: the objective colour-match measure of docs/reference/deliver.md, report schema 1
    /// (`baseDeltaE`: mean < 1, p95 < 2) and the preview↔delivery residual of docs/reference/deliver.md, delivery contract.
    public struct DeltaEStats: Equatable, Sendable {
        public let mean: Double
        public let p50: Double
        public let p95: Double
        public let p99: Double
        public let max: Double
        public let fractionAbove2: Double
        public let fractionAbove3: Double
        public let fractionAbove5: Double
        /// Pixels that contributed (non-finite differences are excluded and counted separately).
        public let pixelCount: Int
        public let nonFiniteCount: Int
    }

    /// Distribution of absolute per-sample differences in 8-bit Display P3 LSB — the
    /// `tools/verify-heic` shape, the codec-sanity cross-check for the base and the fallback copy.
    public struct LSBStats: Equatable, Sendable {
        public let meanAbsDiff: Double
        public let p50: Int
        public let p90: Int
        public let p99: Int
        public let max: Int
        public let fractionNonZero: Double
        /// RGB samples compared (3 × pixelCount).
        public let sampleCount: Int
    }

    /// Linear-light statistics of one decoded HDR image: the decode-side overshoot diagnostics of
    /// docs/reference/verification.md (reported, never a gate).
    public struct LinearStats: Equatable, Sendable {
        public let peak: Double
        public let mean: Double
        public let fractionAboveOne: Double
        /// Fraction of R/G/B samples above `cap` (nil when no cap was supplied).
        public let fractionAboveCap: Double?
        /// Fraction of R/G/B samples above the advertised `contentHeadroom` (nil when absent).
        public let fractionAboveContentHeadroom: Double?
        public let nonFiniteCount: Int
        public let sampleCount: Int
    }

    // MARK: - Strip rendering

    /// Rows per block for the parallel comparisons: 256 rows of a 6000 px line is a 24.6 MB
    /// float buffer — bounded per worker while still giving Core Image a large enough tile.
    static let stripRows = 256

    // MARK: - ΔE2000 comparisons

    /// ΔE2000 between an encoded SDR decode and the in-memory linear-P3 base the pipeline holds.
    ///
    /// Both sides are compared pixel by pixel at full resolution; only strips are allocated.
    public static func deltaEStats(
        reference: LinearImage,
        candidate: CIImage,
        context: CIContext
    ) throws -> DeltaEStats {
        let size = reference.size
        guard size.width > 0, size.height > 0 else { return DeltaEAccumulator().stats() }
        let width = size.width
        let height = size.height
        let pixels = reference.pixels
        let blockCount = (height + stripRows - 1) / stripRows
        var accumulators = [DeltaEAccumulator](repeating: DeltaEAccumulator(), count: blockCount)
        var errors = [Error?](repeating: nil, count: blockCount)
        DispatchQueue.concurrentPerform(iterations: blockCount) { block in
            let blockStart = block * stripRows
            let rows = min(stripRows, height - blockStart)
            let ciY = height - blockStart - rows
            var buffer = [Float](repeating: 0, count: width * rows * 4)
            do {
                try buffer.withUnsafeMutableBytes { raw in
                    try CIRender.render(
                        candidate,
                        toBitmap: raw.baseAddress!,
                        rowBytes: width * 16,
                        bounds: CGRect(x: 0, y: ciY, width: width, height: rows),
                        format: .RGBAf,
                        colorSpace: linearP3,
                        context: context
                    )
                }
                var accumulator = DeltaEAccumulator()
                pixels.withUnsafeBufferPointer { referencePixels in
                    buffer.withUnsafeBufferPointer { candidatePixels in
                        for row in 0..<rows {
                            let referenceBase = (blockStart + row) * width * 4
                            let candidateBase = row * width * 4
                            for x in 0..<width {
                                let referenceIndex = referenceBase + x * 4
                                let candidateIndex = candidateBase + x * 4
                                let lhs = RGBA(
                                    r: referencePixels[referenceIndex],
                                    g: referencePixels[referenceIndex + 1],
                                    b: referencePixels[referenceIndex + 2]
                                )
                                let rhs = RGBA(
                                    r: candidatePixels[candidateIndex],
                                    g: candidatePixels[candidateIndex + 1],
                                    b: candidatePixels[candidateIndex + 2]
                                )
                                accumulator.add(deltaE2000(lhs, rhs))
                            }
                        }
                    }
                }
                accumulators[block] = accumulator
            } catch {
                errors[block] = error
            }
        }
        if let error = errors.compactMap({ $0 }).first { throw error }
        var merged = DeltaEAccumulator()
        for accumulator in accumulators { merged.merge(accumulator) }
        return merged.stats()
    }

    /// ΔE2000 between two decoded images of the same size (delivered SDR vs the fallback copy).
    public static func deltaEStats(
        _ lhs: CIImage,
        _ rhs: CIImage,
        size: PixelSize,
        context: CIContext
    ) throws -> DeltaEStats {
        guard size.width > 0, size.height > 0 else { return DeltaEAccumulator().stats() }
        let width = size.width
        let height = size.height
        let blockCount = (height + stripRows - 1) / stripRows
        var accumulators = [DeltaEAccumulator](repeating: DeltaEAccumulator(), count: blockCount)
        var errors = [Error?](repeating: nil, count: blockCount)
        DispatchQueue.concurrentPerform(iterations: blockCount) { block in
            let blockStart = block * stripRows
            let rows = min(stripRows, height - blockStart)
            let ciY = height - blockStart - rows
            var lhsBuffer = [Float](repeating: 0, count: width * rows * 4)
            var rhsBuffer = [Float](repeating: 0, count: width * rows * 4)
            do {
                try lhsBuffer.withUnsafeMutableBytes { raw in
                    try CIRender.render(
                        lhs,
                        toBitmap: raw.baseAddress!,
                        rowBytes: width * 16,
                        bounds: CGRect(x: 0, y: ciY, width: width, height: rows),
                        format: .RGBAf,
                        colorSpace: linearP3,
                        context: context
                    )
                }
                try rhsBuffer.withUnsafeMutableBytes { raw in
                    try CIRender.render(
                        rhs,
                        toBitmap: raw.baseAddress!,
                        rowBytes: width * 16,
                        bounds: CGRect(x: 0, y: ciY, width: width, height: rows),
                        format: .RGBAf,
                        colorSpace: linearP3,
                        context: context
                    )
                }
                var accumulator = DeltaEAccumulator()
                lhsBuffer.withUnsafeBufferPointer { lhsPointer in
                    rhsBuffer.withUnsafeBufferPointer { rhsPointer in
                        for row in 0..<rows {
                            let rowBase = row * width * 4
                            for x in 0..<width {
                                let index = rowBase + x * 4
                                let lhsPixel = RGBA(r: lhsPointer[index], g: lhsPointer[index + 1], b: lhsPointer[index + 2])
                                let rhsPixel = RGBA(r: rhsPointer[index], g: rhsPointer[index + 1], b: rhsPointer[index + 2])
                                accumulator.add(deltaE2000(lhsPixel, rhsPixel))
                            }
                        }
                    }
                }
                accumulators[block] = accumulator
            } catch {
                errors[block] = error
            }
        }
        if let error = errors.compactMap({ $0 }).first { throw error }
        var merged = DeltaEAccumulator()
        for accumulator in accumulators { merged.merge(accumulator) }
        return merged.stats()
    }

    /// ΔE2000 between two in-memory preview buffers (both already linear P3, same size).
    ///
    /// This is a plain row-major comparison: both buffers came from `PreviewRenderer.render`,
    /// which renders the whole image in one call, so their row order is identical by construction.
    /// The loop is parallel over row blocks; the accumulators are merged exactly.
    public static func deltaEStats(_ lhs: LinearImage, _ rhs: LinearImage) -> DeltaEStats {
        guard lhs.size == rhs.size else { return DeltaEAccumulator().stats() }
        let width = lhs.size.width
        let pixelCount = lhs.size.pixelCount
        guard width > 0, pixelCount > 0 else { return DeltaEAccumulator().stats() }
        let blockPixels = width * stripRows
        let blockCount = (pixelCount + blockPixels - 1) / blockPixels
        var accumulators = [DeltaEAccumulator](repeating: DeltaEAccumulator(), count: blockCount)
        let left = lhs.pixels
        let right = rhs.pixels
        DispatchQueue.concurrentPerform(iterations: blockCount) { block in
            let start = block * blockPixels
            let end = min(start + blockPixels, pixelCount)
            var accumulator = DeltaEAccumulator()
            left.withUnsafeBufferPointer { leftPixels in
                right.withUnsafeBufferPointer { rightPixels in
                    for pixel in start..<end {
                        let index = pixel * 4
                        let lhsPixel = RGBA(r: leftPixels[index], g: leftPixels[index + 1], b: leftPixels[index + 2])
                        let rhsPixel = RGBA(r: rightPixels[index], g: rightPixels[index + 1], b: rightPixels[index + 2])
                        accumulator.add(deltaE2000(lhsPixel, rhsPixel))
                    }
                }
            }
            accumulators[block] = accumulator
        }
        var merged = DeltaEAccumulator()
        for accumulator in accumulators { merged.merge(accumulator) }
        return merged.stats()
    }

    private static func deltaE2000(_ lhs: RGBA, _ rhs: RGBA) -> Double {
        // Local wrapper: one call site to swap if the colour science ever moves.
        Colorimetry.deltaE2000(Colorimetry.lab(lhs), Colorimetry.lab(rhs))
    }

    // MARK: - 8-bit LSB comparisons

    /// Absolute 8-bit Display P3 differences between an encoded SDR decode and the in-memory base,
    /// as a codec sanity cross-check (the delivered base is an 8-bit 4:2:0 HEVC encode).
    ///
    /// The reference samples are the *same* 16-bit quantisation the encoder was handed
    /// (`SDRQuantiser.encoded16`, the one definition shared with `TIFFWriter`/`PNGWriter`),
    /// reduced to 8 bits; the candidate is rendered by the same `CIContext` path `verify-heic`
    /// uses. It is a cross-check because two different 8-bit quantisation paths can legitimately
    /// disagree by one LSB; no gate in the report depends on it.
    public static func lsbStats(
        reference: LinearImage,
        candidate: CIImage,
        context: CIContext
    ) throws -> LSBStats {
        let size = reference.size
        guard size.width > 0, size.height > 0 else { return LSBAccumulator().stats() }
        let width = size.width
        let height = size.height
        let rowBytes = width * 4
        let pixels = reference.pixels
        let blockCount = (height + stripRows - 1) / stripRows
        var accumulators = [LSBAccumulator](repeating: LSBAccumulator(), count: blockCount)
        var errors = [Error?](repeating: nil, count: blockCount)
        DispatchQueue.concurrentPerform(iterations: blockCount) { block in
            let blockStart = block * stripRows
            let rows = min(stripRows, height - blockStart)
            let ciY = height - blockStart - rows
            var buffer = [UInt8](repeating: 0, count: rowBytes * rows)
            do {
                try buffer.withUnsafeMutableBytes { raw in
                    try CIRender.render(
                        candidate,
                        toBitmap: raw.baseAddress!,
                        rowBytes: rowBytes,
                        bounds: CGRect(x: 0, y: ciY, width: width, height: rows),
                        format: .RGBA8,
                        colorSpace: displayP3,
                        context: context
                    )
                }
                var accumulator = LSBAccumulator()
                pixels.withUnsafeBufferPointer { referencePixels in
                    buffer.withUnsafeBufferPointer { candidatePixels in
                        for row in 0..<rows {
                            let referenceBase = (blockStart + row) * width * 4
                            let candidateBase = row * rowBytes
                            for x in 0..<width {
                                let referenceIndex = referenceBase + x * 4
                                let candidateIndex = candidateBase + x * 4
                                for channel in 0..<3 {
                                    let expected = quantised8(referencePixels[referenceIndex + channel])
                                    accumulator.add(abs(Int(candidatePixels[candidateIndex + channel]) - expected))
                                }
                            }
                        }
                    }
                }
                accumulators[block] = accumulator
            } catch {
                errors[block] = error
            }
        }
        if let error = errors.compactMap({ $0 }).first { throw error }
        var merged = LSBAccumulator()
        for accumulator in accumulators { merged.merge(accumulator) }
        return merged.stats()
    }

    /// 8-bit Display P3 samples of the in-memory base, from `SDRQuantiser.encoded16` (the exact
    /// 16-bit quantisation the encoder was handed) reduced to 8 bits.
    private static func quantised8(_ linear: Float) -> Int {
        Int((Double(SDRQuantiser.encoded16(linear)) / 257.0).rounded())
    }

    /// Absolute 8-bit differences between two decoded images of the same size (the fallback check:
    /// the map-stripped copy re-decoded versus the delivered primary decode).
    public static func lsbStats(
        _ lhs: CIImage,
        _ rhs: CIImage,
        size: PixelSize,
        context: CIContext
    ) throws -> LSBStats {
        guard size.width > 0, size.height > 0 else { return LSBAccumulator().stats() }
        let width = size.width
        let height = size.height
        let rowBytes = width * 4
        let blockCount = (height + stripRows - 1) / stripRows
        var accumulators = [LSBAccumulator](repeating: LSBAccumulator(), count: blockCount)
        var errors = [Error?](repeating: nil, count: blockCount)
        DispatchQueue.concurrentPerform(iterations: blockCount) { block in
            let blockStart = block * stripRows
            let rows = min(stripRows, height - blockStart)
            let ciY = height - blockStart - rows
            var lhsBuffer = [UInt8](repeating: 0, count: rowBytes * rows)
            var rhsBuffer = [UInt8](repeating: 0, count: rowBytes * rows)
            do {
                try lhsBuffer.withUnsafeMutableBytes { raw in
                    try CIRender.render(
                        lhs,
                        toBitmap: raw.baseAddress!,
                        rowBytes: rowBytes,
                        bounds: CGRect(x: 0, y: ciY, width: width, height: rows),
                        format: .RGBA8,
                        colorSpace: displayP3,
                        context: context
                    )
                }
                try rhsBuffer.withUnsafeMutableBytes { raw in
                    try CIRender.render(
                        rhs,
                        toBitmap: raw.baseAddress!,
                        rowBytes: rowBytes,
                        bounds: CGRect(x: 0, y: ciY, width: width, height: rows),
                        format: .RGBA8,
                        colorSpace: displayP3,
                        context: context
                    )
                }
                var accumulator = LSBAccumulator()
                lhsBuffer.withUnsafeBufferPointer { lhsPointer in
                    rhsBuffer.withUnsafeBufferPointer { rhsPointer in
                        for row in 0..<rows {
                            let rowBase = row * rowBytes
                            for x in 0..<width {
                                let index = rowBase + x * 4
                                for channel in 0..<3 {
                                    accumulator.add(abs(Int(lhsPointer[index + channel]) - Int(rhsPointer[index + channel])))
                                }
                            }
                        }
                    }
                }
                accumulators[block] = accumulator
            } catch {
                errors[block] = error
            }
        }
        if let error = errors.compactMap({ $0 }).first { throw error }
        var merged = LSBAccumulator()
        for accumulator in accumulators { merged.merge(accumulator) }
        return merged.stats()
    }

    // MARK: - Linear-light measurement (decode-side diagnostics)

    /// Renders a decoded image to linear extended Display P3 and measures the HDR signal.
    ///
    /// The fractions are per **sample** (R/G/B), the `tools/verify-heic` convention: a pure SDR P3
    /// image renders at peak ≈ 1.14–1.19 from ColorSync overshoot, so "fraction above 1.0" here is
    /// a diagnostic of the decode, not the authored above-white fraction (docs/reference/verification.md).
    public static func linearStats(
        candidate: CIImage,
        size: PixelSize,
        cap: Double?,
        contentHeadroom: Double?,
        context: CIContext
    ) throws -> LinearStats {
        guard size.width > 0, size.height > 0 else {
            return LinearStatsAccumulator(cap: cap, contentHeadroom: contentHeadroom).stats()
        }
        let width = size.width
        let height = size.height
        let blockCount = (height + stripRows - 1) / stripRows
        var accumulators = [LinearStatsAccumulator](
            repeating: LinearStatsAccumulator(cap: cap, contentHeadroom: contentHeadroom),
            count: blockCount
        )
        var errors = [Error?](repeating: nil, count: blockCount)
        DispatchQueue.concurrentPerform(iterations: blockCount) { block in
            let blockStart = block * stripRows
            let rows = min(stripRows, height - blockStart)
            let ciY = height - blockStart - rows
            var buffer = [Float](repeating: 0, count: width * rows * 4)
            do {
                try buffer.withUnsafeMutableBytes { raw in
                    try CIRender.render(
                        candidate,
                        toBitmap: raw.baseAddress!,
                        rowBytes: width * 16,
                        bounds: CGRect(x: 0, y: ciY, width: width, height: rows),
                        format: .RGBAf,
                        colorSpace: linearP3,
                        context: context
                    )
                }
                var accumulator = LinearStatsAccumulator(cap: cap, contentHeadroom: contentHeadroom)
                buffer.withUnsafeBufferPointer { pointer in
                    for row in 0..<rows {
                        let rowBase = row * width * 4
                        for x in 0..<width {
                            let index = rowBase + x * 4
                            accumulator.add(pointer[index], pointer[index + 1], pointer[index + 2])
                        }
                    }
                }
                accumulators[block] = accumulator
            } catch {
                errors[block] = error
            }
        }
        if let error = errors.compactMap({ $0 }).first { throw error }
        var merged = LinearStatsAccumulator(cap: cap, contentHeadroom: contentHeadroom)
        for accumulator in accumulators { merged.merge(accumulator) }
        return merged.stats()
    }

    // MARK: - The SDR fallback copy (ImageIO only — never `sips`)

    /// Writes a gain-map-free HEIC from the delivered file's SDR primary image with
    /// `CGImageDestination`, and returns the written URL.
    ///
    /// This is the "prove the fallback separately" step of docs/reference/deliver.md, report schema 1: the copy a non-HDR viewer
    /// shows must be the approved Capture One base. ImageIO is the only writer used (`sips`
    /// silently strips gain maps and cannot be part of a proof, docs/reference/container.md).
    ///
    /// No metadata dictionary is passed: no auxiliary data (so no gain map), no EXIF, no
    /// orientation, no timestamps — the copy's bytes are a pure function of the decoded pixels.
    /// `DeliveryVerifierTests.testMapStrippedCopyIsDeterministicAndCarriesNoISOAux` pins that two
    /// writes of the same input are byte-identical (the docs/reference/deliver.md, delivery contract determinism gate).
    @discardableResult
    public static func makeMapStrippedCopy(of sourceURL: URL, to destinationURL: URL) throws -> URL {
        let sourcePath = sourceURL.standardizedFileURL.path
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw PhotonError.encoderOutputInvalid(
                path: sourcePath,
                reason: "ImageIO cannot open the file to make the SDR fallback copy"
            )
        }
        guard let primary = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PhotonError.encoderOutputInvalid(
                path: sourcePath,
                reason: "ImageIO could not decode the SDR primary to make the fallback copy"
            )
        }
        // A stale file from an earlier run must never masquerade as this run's copy.
        try? FileManager.default.removeItem(at: destinationURL)
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotonError.writeFailed(
                path: destinationURL.path,
                reason: "cannot create a HEIC destination for the SDR fallback copy"
            )
        }
        CGImageDestinationAddImage(destination, primary, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotonError.writeFailed(
                path: destinationURL.path,
                reason: "HEIC destination finalize failed for the SDR fallback copy"
            )
        }
        return destinationURL
    }

    // MARK: - File helpers

    /// SHA-256 of a file's bytes (reuses the streaming decoder helper: the delivered HEIC can be
    /// several MB and the copy is small, but one implementation is enough).
    public static func sha256(ofFileAt url: URL) throws -> String {
        try SourceDecoder.sha256(ofFileAt: url)
    }

    /// Size in bytes, `nil` when the file is missing.
    public static func fileBytes(_ url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}

// MARK: - Accumulators (fixed histograms, no per-pixel arrays)

/// ΔE2000 distribution accumulator.
///
/// A 0.01-wide fixed histogram (0 … 40 ΔE, overflow in the last bin) keeps the memory constant for
/// a 24 Mpx comparison; percentiles are nearest-rank over the histogram and mean/max are exact.
/// The samples here have small ΔE by construction (the comparison runs on 8-bit codec output), so
/// the 40 ΔE ceiling only saturates pathological disagreement, which shows up in `max` anyway.
private struct DeltaEAccumulator {
    static let binWidth = 0.01
    static let binCount = 4000

    private var bins = [Int](repeating: 0, count: DeltaEAccumulator.binCount)
    private var count = 0
    private var sum = 0.0
    private var maxValue = 0.0
    private var nonFinite = 0
    private var above2 = 0
    private var above3 = 0
    private var above5 = 0

    mutating func add(_ value: Double) {
        guard value.isFinite else {
            nonFinite += 1
            return
        }
        count += 1
        sum += value
        if value > maxValue { maxValue = value }
        if value > 2.0 { above2 += 1 }
        if value > 3.0 { above3 += 1 }
        if value > 5.0 { above5 += 1 }
        let bin = min(max(Int(value / Self.binWidth), 0), Self.binCount - 1)
        bins[bin] += 1
    }

    /// Merge a strip's accumulator into this one. The histograms and counters are additive, so
    /// the merged mean/percentiles are exactly the serial result (the benchmark pins that).
    mutating func merge(_ other: DeltaEAccumulator) {
        count += other.count
        sum += other.sum
        if other.maxValue > maxValue { maxValue = other.maxValue }
        nonFinite += other.nonFinite
        above2 += other.above2
        above3 += other.above3
        above5 += other.above5
        for index in 0..<Self.binCount { bins[index] += other.bins[index] }
    }

    private func percentile(_ percent: Double) -> Double {
        guard count > 0 else { return 0 }
        let rank = max(1, Int((percent / 100.0 * Double(count)).rounded(.up)))
        var cumulative = 0
        for (index, binCount) in bins.enumerated() {
            cumulative += binCount
            if cumulative >= rank { return Double(index) * Self.binWidth }
        }
        return maxValue
    }

    private func fraction(_ count: Int) -> Double {
        count > 0 ? Double(count) / Double(self.count) : 0
    }

    func stats() -> DeliveryImageProbe.DeltaEStats {
        DeliveryImageProbe.DeltaEStats(
            mean: count > 0 ? sum / Double(count) : 0,
            p50: percentile(50),
            p95: percentile(95),
            p99: percentile(99),
            max: maxValue,
            fractionAbove2: fraction(above2),
            fractionAbove3: fraction(above3),
            fractionAbove5: fraction(above5),
            pixelCount: count,
            nonFiniteCount: nonFinite
        )
    }
}

/// Absolute 8-bit difference accumulator (0…255 histogram, exact mean/max).
private struct LSBAccumulator {
    private var counts = [Int](repeating: 0, count: 256)
    private var count = 0
    private var sum = 0.0
    private var maxValue = 0
    private var nonZero = 0

    mutating func add(_ difference: Int) {
        let value = min(max(difference, 0), 255)
        count += 1
        sum += Double(value)
        if value > maxValue { maxValue = value }
        if value != 0 { nonZero += 1 }
        counts[value] += 1
    }

    /// Merge a strip's accumulator into this one (additive histogram + exact sum/max).
    mutating func merge(_ other: LSBAccumulator) {
        count += other.count
        sum += other.sum
        if other.maxValue > maxValue { maxValue = other.maxValue }
        nonZero += other.nonZero
        for index in 0..<256 { counts[index] += other.counts[index] }
    }

    private func percentile(_ percent: Double) -> Int {
        guard count > 0 else { return 0 }
        let rank = max(1, Int((percent / 100.0 * Double(count)).rounded(.up)))
        var cumulative = 0
        for (value, binCount) in counts.enumerated() {
            cumulative += binCount
            if cumulative >= rank { return value }
        }
        return maxValue
    }

    func stats() -> DeliveryImageProbe.LSBStats {
        DeliveryImageProbe.LSBStats(
            meanAbsDiff: count > 0 ? sum / Double(count) : 0,
            p50: percentile(50),
            p90: percentile(90),
            p99: percentile(99),
            max: maxValue,
            fractionNonZero: count > 0 ? Double(nonZero) / Double(count) : 0,
            sampleCount: count
        )
    }
}

/// Linear-light HDR signal accumulator for the decode-side diagnostics.
private struct LinearStatsAccumulator {
    let cap: Double?
    let contentHeadroom: Double?

    private var peak = 0.0
    private var sum = 0.0
    private var sampleCount = 0
    private var aboveOne = 0
    private var aboveCap = 0
    private var aboveContentHeadroom = 0
    private var nonFinite = 0

    init(cap: Double?, contentHeadroom: Double?) {
        self.cap = cap
        self.contentHeadroom = contentHeadroom
    }

    mutating func add(_ r: Float, _ g: Float, _ b: Float) {
        if !(r.isFinite && g.isFinite && b.isFinite) {
            nonFinite += 3
            return
        }
        addSample(Double(r))
        addSample(Double(g))
        addSample(Double(b))
    }

    private mutating func addSample(_ value: Double) {
        sampleCount += 1
        sum += value
        if value > peak { peak = value }
        if value > 1.0 { aboveOne += 1 }
        if let cap, value > cap { aboveCap += 1 }
        if let contentHeadroom, value > contentHeadroom { aboveContentHeadroom += 1 }
    }

    /// Merge a strip's accumulator into this one (peak/sum/counters are additive).
    mutating func merge(_ other: LinearStatsAccumulator) {
        peak = max(peak, other.peak)
        sum += other.sum
        sampleCount += other.sampleCount
        aboveOne += other.aboveOne
        aboveCap += other.aboveCap
        aboveContentHeadroom += other.aboveContentHeadroom
        nonFinite += other.nonFinite
    }

    func stats() -> DeliveryImageProbe.LinearStats {
        let denominator = Double(max(sampleCount, 1))
        return DeliveryImageProbe.LinearStats(
            peak: peak,
            mean: sampleCount > 0 ? sum / denominator : 0,
            fractionAboveOne: sampleCount > 0 ? Double(aboveOne) / denominator : 0,
            fractionAboveCap: cap != nil && sampleCount > 0 ? Double(aboveCap) / denominator : nil,
            fractionAboveContentHeadroom: contentHeadroom != nil && sampleCount > 0
                ? Double(aboveContentHeadroom) / denominator
                : nil,
            nonFiniteCount: nonFinite,
            sampleCount: sampleCount
        )
    }
}
