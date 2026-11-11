import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import EngineKit

/// Contract tests for the Core Image HEIC writer: the structural read-back (bit depth, gain-map
/// size/kind, ISO aux, headroom, no alpha), the 8-bit SDR fallback, the metadata filter and the
/// profile parser. The fixtures are generated, so the suite does not need `fixtures/media/` or the
/// external encoder.
final class CoreImageHEICEncoderTests: XCTestCase {
    // MARK: - Helpers

    private func makeInput(
        size: PixelSize = PixelSize(width: 256, height: 192)
    ) throws -> (directory: URL, source: DecodedSource, sdrBase: LinearImage, hdr: HDRRendition.Result) {
        let directory = try TestFixtures.makeTemporaryDirectory()
        let sourceURL = try TestFixtures.writeGradientP3TIFF(
            size: size,
            to: directory.appendingPathComponent("source.tif")
        )
        let source = try SourceDecoder.decode(url: sourceURL)
        let recipe = Recipe(
            source: .init(
                path: sourceURL.path,
                sha256: source.sha256,
                width: source.size.width,
                height: source.size.height
            ),
            hdr: .init(start: 0.2, liftStops: 1.4, transition: 0.5, headroomCap: 2.5),
            versions: .init(encoder: "coreimage-test"),
            created: "2026-11-09T00:00:00+08:00"
        )
        let toneMap = try ToneMapKind.named(recipe.base.toneMap)
        let sdrBase = try ToneMapper.sdrBase(from: source.linear, toneMap: toneMap)
        let hdr = try HDRRendition.render(base: sdrBase, shape: try HighlightShape(recipe: recipe.hdr))
        return (directory, source, sdrBase, hdr)
    }

    private func encode(
        _ options: HEICEncodeOptions,
        directory: URL,
        source: DecodedSource,
        sdrBase: LinearImage,
        hdr: HDRRendition.Result,
        name: String
    ) throws -> HEICEncodeResult {
        let request = HEICEncodeRequest(
            sdrBase: sdrBase,
            hdrRendition: hdr.image,
            authoredPeak: hdr.authoredPeak,
            options: options,
            sourceURL: source.url,
            hdrOutputURL: directory.appendingPathComponent("\(name)-hdr.heic"),
            sdrOutputURL: directory.appendingPathComponent("\(name)-sdr.heic")
        )
        return try CoreImageHEICEncoder().encode(request)
    }

    // MARK: - 10-bit half-res RGB

    func testTenBitHalfRGBWritesTheDocumentedShape() throws {
        let input = try makeInput()
        defer { try? FileManager.default.removeItem(at: input.directory) }
        let options = try HEICEncodeOptions(
            bitDepth: .ten, quality: 0.85, mapResolution: .half, mapKind: .isoRGB
        )
        let result = try encode(
            options, directory: input.directory, source: input.source,
            sdrBase: input.sdrBase, hdr: input.hdr, name: "ten-half-rgb"
        )

        XCTAssertEqual(result.facts.width, 256)
        XCTAssertEqual(result.facts.height, 192)
        XCTAssertEqual(result.facts.sdrBitsPerComponent, 10, "the 10-bit profile must write a 10-bit base")
        XCTAssertFalse(result.facts.sdrHasAlpha)
        XCTAssertTrue(result.facts.isoGainMapPresent)
        XCTAssertTrue(result.facts.hdrDecoded)
        XCTAssertEqual(result.gainMapWidth, 128, "half-res map width")
        XCTAssertEqual(result.gainMapHeight, 96, "half-res map height")
        XCTAssertEqual(result.gainMapKind, .isoRGB)
        XCTAssertEqual(
            result.facts.contentHeadroom,
            Double(input.hdr.authoredPeak),
            accuracy: Double(input.hdr.authoredPeak) * 0.05,
            "advertised headroom must match the authored peak"
        )

        // The fallback is an 8-bit SDR HEIC with no auxiliary data.
        let fallback = try EncodedHEICValidator.inspect(try XCTUnwrap(result.sdrHEIC))
        XCTAssertEqual(fallback.sdrBitsPerComponent, 8)
        XCTAssertFalse(fallback.isoGainMapPresent)
        XCTAssertFalse(fallback.sdrHasAlpha)
        XCTAssertEqual(fallback.width, 256)
        XCTAssertEqual(fallback.height, 192)

        // The delivered HDR decode matches the authored rendition at preview scale.
        let decoded = try DeliveryImageProbe.decode(result.hdrHEIC)
        let hdr = try XCTUnwrap(decoded.hdr)
        let preview = try PreviewRenderer.downscale(
            base: input.sdrBase,
            hdr: input.hdr.image,
            longEdge: 128,
            headroomCap: 2.5
        )
        let context = DeliveryImageProbe.makeContext()
        let deliveredPreview = try PreviewRenderer.render(
            PreviewRenderer.lanczos(CIImage(cgImage: hdr), to: preview.size),
            size: preview.size,
            context: context
        )
        let deltaE = DeliveryImageProbe.deltaEStats(deliveredPreview, preview.hdr)
        XCTAssertLessThan(deltaE.mean, 2.5, "half-res preview agreement mean")
        XCTAssertLessThan(deltaE.p99, 10.0, "half-res preview agreement p99")

        // The decoded 10-bit base matches the SDR base within the codec loss.
        let baseDeltaE = try DeliveryImageProbe.deltaEStats(
            reference: input.sdrBase,
            candidate: CIImage(cgImage: decoded.sdr),
            context: context
        )
        XCTAssertLessThan(baseDeltaE.mean, 2.5)
        XCTAssertLessThan(baseDeltaE.p95, 6.0)
    }

    // MARK: - 8-bit full-res mono

    func testEightBitFullMonoWritesTheDocumentedShape() throws {
        let input = try makeInput(size: PixelSize(width: 160, height: 120))
        defer { try? FileManager.default.removeItem(at: input.directory) }
        let options = try HEICEncodeOptions(
            bitDepth: .eight, quality: 0.85, mapResolution: .full, mapKind: .isoMono
        )
        let result = try encode(
            options, directory: input.directory, source: input.source,
            sdrBase: input.sdrBase, hdr: input.hdr, name: "eight-full-mono"
        )

        XCTAssertEqual(result.facts.sdrBitsPerComponent, 8)
        XCTAssertTrue(result.facts.isoGainMapPresent)
        XCTAssertTrue(result.facts.hdrDecoded)
        XCTAssertEqual(result.gainMapWidth, 160, "full-res map width")
        XCTAssertEqual(result.gainMapHeight, 120, "full-res map height")
        XCTAssertEqual(result.gainMapKind, .isoMono)
        XCTAssertEqual(
            result.facts.contentHeadroom,
            Double(input.hdr.authoredPeak),
            accuracy: Double(input.hdr.authoredPeak) * 0.05
        )

        let fallback = try EncodedHEICValidator.inspect(try XCTUnwrap(result.sdrHEIC))
        XCTAssertEqual(fallback.sdrBitsPerComponent, 8)
        XCTAssertFalse(fallback.isoGainMapPresent)
    }

    // MARK: - Metadata filter

    func testMetadataFilterKeepsEXIFTIFFGPSAndDropsXMP() throws {
        let source = CGImageMetadataCreateMutable()
        let exif = "http://ns.adobe.com/exif/1.0/" as CFString
        let tiff = "http://ns.adobe.com/tiff/1.0/" as CFString
        let gps = "http://ns.adobe.com/exif/1.0/gps/" as CFString
        let xmp = "http://ns.adobe.com/xap/1.0/" as CFString
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(source, exif, "exif" as CFString, nil))
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(source, tiff, "tiff" as CFString, nil))
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(source, gps, "gps" as CFString, nil))
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(source, xmp, "xmp" as CFString, nil))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(source, nil, "exif:WhiteBalance" as CFString, NSNumber(value: 1)))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(source, nil, "tiff:Orientation" as CFString, NSNumber(value: 1)))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(source, nil, "gps:Latitude" as CFString, NSNumber(value: 31.2)))
        XCTAssertTrue(CGImageMetadataSetValueWithPath(source, nil, "xmp:Label" as CFString, "keep out" as CFString))

        let filtered = try XCTUnwrap(MetadataTemplate.filteredSourceMetadata(source))
        XCTAssertNotNil(CGImageMetadataCopyTagWithPath(filtered, nil, "exif:WhiteBalance" as CFString))
        XCTAssertNotNil(CGImageMetadataCopyTagWithPath(filtered, nil, "tiff:Orientation" as CFString))
        XCTAssertNotNil(CGImageMetadataCopyTagWithPath(filtered, nil, "gps:Latitude" as CFString))
        XCTAssertNil(CGImageMetadataCopyTagWithPath(filtered, nil, "xmp:Label" as CFString))
    }

    // MARK: - Profile parser

    func testProfileStringParsing() throws {
        XCTAssertEqual(try XCTUnwrap(HEICEncodeOptions(profileString: "10/half/rgb")).profileName, "10-half-rgb")
        XCTAssertEqual(try XCTUnwrap(HEICEncodeOptions(profileString: "8/full/mono")).profileName, "8-full-mono")
        XCTAssertEqual(try XCTUnwrap(HEICEncodeOptions(profileString: "10/full/iso-rgb")).profileName, "10-full-rgb")
        XCTAssertNil(HEICEncodeOptions(profileString: "9/half/rgb"))
        XCTAssertNil(HEICEncodeOptions(profileString: "10/quarter/rgb"))
        XCTAssertNil(HEICEncodeOptions(profileString: "10/half"))
    }
}
