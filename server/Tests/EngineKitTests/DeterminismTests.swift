import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import EngineKit

/// The M1 hard contract: same source + recipe ⇒ byte-identical `sdr.tif`, `hdr.tif`,
/// `preview.heic`; the SDR base is 16-bit with no alpha; the authored HDR peak is exactly the
/// recipe cap; and `meta.json` describes the files it sits next to.
final class DeterminismTests: XCTestCase {
    // MARK: - Determinism

    func testPipelineIsDeterministicForSameSourceAndRecipe() throws {
        let directory = try TestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = try TestFixtures.writeGradientP3TIFF(
            size: PixelSize(width: 256, height: 192),
            to: directory.appendingPathComponent("source.tif")
        )
        let pipeline = try Pipeline(encoderVersion: "determinism-test")

        // A 128 px preview exercises the Lanczos path (the source's long edge is 256 px).
        // The explicit 2.5 cap keeps the authored-peak assertions below meaningful (the documented
        // default cap is 2^2 now, which this gradient never reaches).
        let sourceSHA = try TestFixtures.sha256(ofFileAt: sourceURL)
        func makeRecipe(created: String) -> Recipe {
            Recipe(
                source: .init(path: sourceURL.path, sha256: sourceSHA, width: 256, height: 192),
                hdr: .init(headroomCap: 2.5),
                versions: .init(encoder: "determinism-test"),
                created: created
            )
        }
        func prepare(into name: String, created: String) throws -> PrepResult {
            try pipeline.prepare(
                sourceURL: sourceURL,
                recipe: makeRecipe(created: created),
                options: PipelineOptions(
                    outputDirectory: directory.appendingPathComponent(name, isDirectory: true),
                    previewLongEdge: 128
                )
            )
        }
        // Different `created` timestamps prove the metadata-only field never reaches the pixels.
        let first = try prepare(into: "run1", created: "2026-11-07T00:00:00+08:00")
        let second = try prepare(into: "run2", created: "2026-11-07T00:00:01+08:00")

        // Same source + recipe ⇒ identical bytes. Run two uses a fresh `created` timestamp, so
        // this also proves the metadata-only field never reaches the pixels.
        for (lhs, rhs, name) in [
            (first.sdrTIFF, second.sdrTIFF, "sdr.tif"),
            (first.hdrTIFF, second.hdrTIFF, "hdr.tif"),
            (first.previewHEIC, second.previewHEIC, "preview.heic"),
        ] {
            let firstHash = try TestFixtures.sha256(ofFileAt: lhs)
            let secondHash = try TestFixtures.sha256(ofFileAt: rhs)
            XCTAssertEqual(firstHash, secondHash, "\(name) must be byte-identical across runs")
            XCTAssertGreaterThan(try fileSize(of: lhs), 0)
        }
        XCTAssertEqual(try first.recipe.renderKey(), try second.recipe.renderKey(), "render key ignores created")
        XCTAssertEqual(first.sourceSHA256, try TestFixtures.sha256(ofFileAt: sourceURL))

        // The SDR base is 16 bpc, 3 samples, no alpha (docs/reference/deliver.md, report schema 1: alpha check).
        let sdrLayout = try imageLayout(of: first.sdrTIFF)
        XCTAssertEqual(sdrLayout.bitsPerComponent, 16)
        XCTAssertEqual(sdrLayout.bitsPerPixel, 48)
        XCTAssertFalse(sdrLayout.hasAlpha, "the delivered base must have no alpha channel")

        // The authored peak is exactly the recipe cap after a TIFF round-trip.
        let hdrPeak = try peakOfLinearImage(at: first.hdrTIFF)
        XCTAssertEqual(Double(hdrPeak), 2.5, accuracy: 1e-5, "authored HDR peak must equal the 2.5 cap")

        // The preview HEIC is a real ISO BMFF file and is a 128 px long edge, i.e. downscaled.
        let previewHeader = [UInt8](try Data(contentsOf: first.previewHEIC).prefix(12))
        XCTAssertEqual(Array(previewHeader[4..<8]), Array("ftyp".utf8), "preview is not a HEIC container")
        let previewLayout = try imageLayout(of: first.previewHEIC)
        XCTAssertEqual(previewLayout.width, 128) // 256x192 downscaled to long edge 128
        XCTAssertEqual(previewLayout.height, 96)

        // meta.json decodes as the M2 contract and its hashes/sizes match the files it lists.
        let metadata = try JSONDecoder().decode(PrepMetadata.self, from: try Data(contentsOf: first.metadataJSON))
        XCTAssertEqual(metadata.schema, PrepMetadata.currentSchema)
        XCTAssertEqual(metadata.source.sha256, first.sourceSHA256)
        XCTAssertEqual(metadata.recipe.source.sha256, first.sourceSHA256)
        XCTAssertEqual(metadata.render.headroomCapLinear, 2.5)
        XCTAssertEqual(metadata.render.authoredPeakLinear, 2.5, accuracy: 1e-5)
        XCTAssertEqual(metadata.render.authoredPeakStops, log2(2.5), accuracy: 1e-9)
        XCTAssertGreaterThan(metadata.render.fractionAboveOne, 0)
        XCTAssertGreaterThan(metadata.render.fractionAtCap, 0)
        XCTAssertGreaterThan(metadata.encoder.elapsedSeconds, 0)
        XCTAssertGreaterThan(metadata.timings.totalSeconds, 0)
        for file in [metadata.outputs.sdrTIFF, metadata.outputs.hdrTIFF, metadata.outputs.previewHEIC] {
            let url = resolveOutput(file.path, in: first.outputDirectory)
            XCTAssertEqual(try TestFixtures.sha256(ofFileAt: url), file.sha256, "meta.json hash for \(file.path)")
            XCTAssertEqual(try fileSize(of: url), file.bytes, "meta.json byte count for \(file.path)")
        }
    }

    // MARK: - Fail-fast contracts (no encoder needed)

    func testPrepareRejectsARecipeForADifferentSource() throws {
        let directory = try TestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = try TestFixtures.writeGradientP3TIFF(
            size: PixelSize(width: 64, height: 48),
            to: directory.appendingPathComponent("source.tif")
        )
        let staleRecipe = Recipe.defaults(
            sourcePath: "some/other/export.tif",
            sourceSHA256: String(repeating: "ab", count: 32),
            width: 64,
            height: 48,
            encoderVersion: "test"
        )
        let pipeline = try Pipeline(encoderVersion: "test")
        XCTAssertThrowsError(
            try pipeline.prepare(
                sourceURL: sourceURL,
                recipe: staleRecipe,
                options: PipelineOptions(outputDirectory: directory.appendingPathComponent("out"))
            )
        ) { error in
            guard case let PhotonError.sourceHashMismatch(expected, actual)? = error as? PhotonError else {
                return XCTFail("expected sourceHashMismatch, got \(error)")
            }
            XCTAssertEqual(expected, staleRecipe.source.sha256)
            XCTAssertNotEqual(actual, staleRecipe.source.sha256)
        }
    }

    func testPrepareRejectsARecipeWithWrongDimensions() throws {
        let directory = try TestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let size = PixelSize(width: 64, height: 48)
        let sourceURL = try TestFixtures.writeGradientP3TIFF(
            size: size,
            to: directory.appendingPathComponent("source.tif")
        )
        let sourceSHA = try TestFixtures.sha256(ofFileAt: sourceURL)
        let wrongSizeRecipe = Recipe.defaults(
            sourcePath: "source.tif",
            sourceSHA256: sourceSHA,
            width: 32,
            height: 48,
            encoderVersion: "test"
        )
        let pipeline = try Pipeline(encoderVersion: "test")
        XCTAssertThrowsError(
            try pipeline.prepare(
                sourceURL: sourceURL,
                recipe: wrongSizeRecipe,
                options: PipelineOptions(outputDirectory: directory.appendingPathComponent("out"))
            )
        ) { error in
            guard case let PhotonError.dimensionMismatch(ew, eh, aw, ah)? = error as? PhotonError else {
                return XCTFail("expected dimensionMismatch, got \(error)")
            }
            XCTAssertEqual([ew, eh, aw, ah], [32, 48, 64, 48])
        }
    }

    func testPrepareRefusesARenderBelowTheAuthoredPeakFloor() throws {
        let directory = try TestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Uniform 0.2 is below the default recipe's `hdr.start` (0.62), so the highlight mask is
        // all-zero and the "HDR" rendition is just the SDR base. `toGainMapHDR` would exit 0 and
        // write a plain SDR HEIC (review P0-1); `prepare` must refuse before touching the output.
        let sourceURL = try TestFixtures.writeUniformP3TIFF(
            size: PixelSize(width: 64, height: 48),
            linearValue: 0.2,
            to: directory.appendingPathComponent("source.tif")
        )
        let outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
        let pipeline = try Pipeline(encoderVersion: "test")

        XCTAssertThrowsError(
            try pipeline.prepare(
                sourceURL: sourceURL,
                recipe: nil,
                options: PipelineOptions(outputDirectory: outputDirectory)
            )
        ) { error in
            guard case let PhotonError.hdrTooDim(peak, minimum)? = error as? PhotonError else {
                return XCTFail("expected hdrTooDim, got \(error)")
            }
            XCTAssertEqual(peak, 0.2, accuracy: 1e-3)
            XCTAssertEqual(minimum, EncodedHEICValidator.minimumAuthoredPeak)
        }

        let products = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
        XCTAssertTrue(products.isEmpty, "a refused render must leave no products, got \(products)")
    }

    func testPrepareRefusesAPreviewThatCollapsesBelowTheFloor() throws {
        let directory = try TestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // One white pixel in a 128x96 frame: the full-resolution rendition reaches the 2.5 cap and
        // passes the first guard, but a 16 px Lanczos preview averages the isolated highlight down
        // below the 1.05 floor — there is no gain map left to encode.
        let sourceURL = try TestFixtures.writeSpotP3TIFF(
            size: PixelSize(width: 128, height: 96),
            baseValue: 0.1,
            spotValue: 1.0,
            to: directory.appendingPathComponent("source.tif")
        )
        let outputDirectory = directory.appendingPathComponent("out", isDirectory: true)
        // No encoder is supplied: the preview guard fires before `Encoder.resolveExecutable`.
        let pipeline = try Pipeline(encoderVersion: "test")

        XCTAssertThrowsError(
            try pipeline.prepare(
                sourceURL: sourceURL,
                recipe: nil,
                options: PipelineOptions(outputDirectory: outputDirectory, previewLongEdge: 16)
            )
        ) { error in
            guard case let PhotonError.hdrTooDim(peak, minimum)? = error as? PhotonError else {
                return XCTFail("expected hdrTooDim from the collapsed preview, got \(error)")
            }
            XCTAssertLessThan(peak, EncodedHEICValidator.minimumAuthoredPeak)
            XCTAssertEqual(minimum, EncodedHEICValidator.minimumAuthoredPeak)
        }

        for name in ["preview.heic", "meta.json"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent(name).path),
                "a refused preview must not leave \(name)"
            )
        }
    }

    // MARK: - Preview geometry and clamping (no encoder needed)

    func testPreviewLongEdgeNeverUpscales() {
        let landscape = PixelSize(width: 6000, height: 4000)
        XCTAssertEqual(PreviewRenderer.previewLongEdge(for: landscape, limit: 2560), 2560)
        let small = PixelSize(width: 256, height: 192)
        XCTAssertEqual(PreviewRenderer.previewLongEdge(for: small, limit: 2560), 256)
        let square = PixelSize(width: 100, height: 100)
        XCTAssertEqual(PreviewRenderer.previewLongEdge(for: square, limit: 2560), 100)
    }

    func testDownscaleProducesMatchingSizesAndClampsTheHDRPreview() throws {
        let size = PixelSize(width: 32, height: 24)
        var basePixels = [Float](repeating: 1, count: size.pixelCount * 4)
        var hdrPixels = basePixels
        // Sharp 0.1 → 2.5 step: Lanczos rings around it, so without the clamp the preview
        // would exceed the authored cap (M0 measured exactly this on the 2560 px preview).
        for y in 0..<size.height {
            for x in 0..<size.width {
                let baseValue: Float = x < size.width / 2 ? 0.1 : 0.98
                let hdrValue: Float = x < size.width / 2 ? 0.1 : 2.5
                let index = (y * size.width + x) * 4
                basePixels[index] = baseValue
                basePixels[index + 1] = baseValue
                basePixels[index + 2] = baseValue
                hdrPixels[index] = hdrValue
                hdrPixels[index + 1] = hdrValue
                hdrPixels[index + 2] = hdrValue
            }
        }
        let base = try LinearImage(size: size, pixels: basePixels)
        let hdr = try LinearImage(size: size, pixels: hdrPixels)

        let pair = try PreviewRenderer.downscale(base: base, hdr: hdr, longEdge: 16, headroomCap: 2.5)
        XCTAssertEqual(pair.size, PixelSize(width: 16, height: 12))
        XCTAssertEqual(pair.base.size, pair.size)
        XCTAssertEqual(pair.hdr.size, pair.size)
        XCTAssertLessThanOrEqual(pair.hdr.maxChannel, 2.5, "Lanczos overshoot above the cap must be re-clamped")
        XCTAssertGreaterThan(pair.hdr.maxChannel, 1.0, "the authored highlight must survive the downscale")
        XCTAssertTrue(pair.base.isOpaque)
        XCTAssertTrue(pair.hdr.isOpaque)
    }

    func testDownscaleBelowTheLimitReturnsTheSourceSize() throws {
        let size = PixelSize(width: 20, height: 10)
        let base = LinearImage(size: size, repeating: RGBA(r: 0.2, g: 0.2, b: 0.2))
        let hdr = LinearImage(size: size, repeating: RGBA(r: 2.5, g: 2.5, b: 2.5))
        let pair = try PreviewRenderer.downscale(base: base, hdr: hdr, longEdge: 2560, headroomCap: 2.5)
        XCTAssertEqual(pair.size, size)
        XCTAssertEqual(pair.base.pixels, base.pixels)
        XCTAssertLessThanOrEqual(pair.hdr.maxChannel, 2.5)
    }

    // MARK: - Helpers

    private struct ImageLayout {
        let width: Int
        let height: Int
        let bitsPerComponent: Int
        let bitsPerPixel: Int
        let hasAlpha: Bool
    }

    private func imageLayout(of url: URL) throws -> ImageLayout {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "cannot open \(url.path)")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), "cannot decode \(url.path)")
        let alphaInfo = image.alphaInfo
        let hasAlpha = alphaInfo == .premultipliedFirst
            || alphaInfo == .premultipliedLast
            || alphaInfo == .first
            || alphaInfo == .last
            || alphaInfo == .alphaOnly
        return ImageLayout(
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerComponent,
            bitsPerPixel: image.bitsPerPixel,
            hasAlpha: hasAlpha
        )
    }

    /// Peak R/G/B sample of a float TIFF, decoded back into the linear extended P3 working space.
    private func peakOfLinearImage(at url: URL) throws -> Float {
        let linearP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let image = try XCTUnwrap(CIImage(contentsOf: url, options: [.expandToHDR: true]), "cannot read \(url.path)")
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)
        let context = CIContext(options: [
            .workingColorSpace: linearP3,
            .outputColorSpace: linearP3,
            .cacheIntermediates: false,
        ])
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(
            image,
            toBitmap: &pixels,
            rowBytes: width * 16,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBAf,
            colorSpace: linearP3
        )
        var peak: Float = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            peak = max(peak, max(pixels[index], max(pixels[index + 1], pixels[index + 2])))
        }
        return peak
    }

    private func fileSize(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    private func resolveOutput(_ path: String, in directory: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path)
    }
}
