@testable import ClientKit
import ContractKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Pins the M3.2 BaseStore decode path (docs/reference/client.md, architecture "BaseStore"; docs/reference/wire.md, M2.1 wire contract):
/// 16-bit Display P3 PNG → validated facts → linear extended Display P3 RGBA Float32 (row 0 =
/// top row, alpha 1). Rejections are specific — a non-P3 base is refused with its actual profile
/// name and never clamped. The real 2560×1707 trial base is exercised when this machine has it.
final class BasePNGTests: XCTestCase {
    // MARK: - Fixture helpers

    private static let p3Name: String = CGColorSpace(name: CGColorSpace.displayP3)!.name as String? ?? ""
    private static let srgbName: String = CGColorSpace(name: CGColorSpace.sRGB)!.name as String? ?? ""

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func expectedBase(
        _ data: Data,
        width: Int,
        height: Int,
        format: String = BasePNG.expectedFormat,
        workingSpace: String = BasePNG.expectedWorkingSpace,
        sha256: String? = nil,
        profileName: String? = "Display P3"
    ) -> PreviewMetadata.BaseInfo {
        PreviewMetadata.BaseInfo(
            file: "preview-base.png",
            bytes: data.count,
            sha256: sha256 ?? sha256Hex(data),
            width: width,
            height: height,
            format: format,
            workingSpace: workingSpace,
            profileName: profileName,
            longEdge: max(width, height)
        )
    }

    /// Builds a PNG with an arbitrary bit depth / colour space / alpha layout, for the rejection
    /// cases. Values are encoded (transfer-encoded), not linear.
    private func makePNG(
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        space: CGColorSpace,
        alphaInfo: CGImageAlphaInfo,
        fill: (Int, Int) -> (r: Double, g: Double, b: Double, a: Double)
    ) throws -> Data {
        let components = 4
        let bytesPerComponent = bitsPerComponent / 8
        let bytesPerRow = width * components * bytesPerComponent
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        func clamped(_ value: Double) -> Double { min(1, max(0, value)) }
        for y in 0 ..< height {
            for x in 0 ..< width {
                let pixel = fill(x, y)
                let values = [pixel.r, pixel.g, pixel.b, pixel.a]
                let offset = y * bytesPerRow + x * components * bytesPerComponent
                for component in 0 ..< components {
                    let value = clamped(values[component])
                    let sampleOffset = offset + component * bytesPerComponent
                    if bitsPerComponent == 16 {
                        let sample = UInt16((value * Double(UInt16.max)).rounded())
                        bytes[sampleOffset] = UInt8(sample & 0xff)
                        bytes[sampleOffset + 1] = UInt8(sample >> 8)
                    } else {
                        bytes[sampleOffset] = UInt8((value * 255).rounded())
                    }
                }
            }
        }
        let bitmapInfo = alphaInfo.rawValue
            | (bitsPerComponent == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        let image: CGImage = try bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: bitmapInfo
            ), let image = context.makeImage() else {
                throw TestSupportError.cannotCreateImage
            }
            return image
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw TestSupportError.cannotCreateImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestSupportError.cannotCreateImage
        }
        return output as Data
    }

    /// The sRGB/Display P3 transfer function (they are the same curve), encoded → linear.
    private func encodedToLinear(_ encoded: Double) -> Double {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    // MARK: - Happy path

    func testValidateAcceptsA16BitDisplayP3PNG() throws {
        let data = try TestSupport.make16BitDisplayP3PNG(width: 2, height: 2) { _, _ in
            (UInt16.max, UInt16.max / 2, 0)
        }
        let facts = try BasePNG.validate(data: data, expected: expectedBase(data, width: 2, height: 2))
        XCTAssertEqual(facts.width, 2)
        XCTAssertEqual(facts.height, 2)
        XCTAssertEqual(facts.bitsPerComponent, 16)
        XCTAssertEqual(facts.colorSpaceName, Self.p3Name)
        XCTAssertEqual(facts.colorSpaceName, "kCGColorSpaceDisplayP3")
        XCTAssertFalse(facts.hasAlpha)
        XCTAssertEqual(facts.byteCount, data.count)
    }

    func testLoadYieldsLinearTopRowFirstOrientation() throws {
        // Row 0: red, green, white. Row 1: mid grey, black, blue. Encoded (16-bit) samples.
        let data = try TestSupport.make16BitDisplayP3PNG(width: 3, height: 2) { x, y in
            switch (y, x) {
            case (0, 0): return (UInt16.max, 0, 0)
            case (0, 1): return (0, UInt16.max, 0)
            case (0, 2): return (UInt16.max, UInt16.max, UInt16.max)
            case (1, 0): return (32768, 32768, 32768)
            case (1, 1): return (0, 0, 0)
            default:     return (0, 0, UInt16.max)
            }
        }
        let expected = expectedBase(data, width: 3, height: 2)
        let image = try BasePNG.load(data: data, expected: expected)

        XCTAssertEqual(image.size, PixelSize(width: 3, height: 2))
        XCTAssertTrue(image.isFinite)
        XCTAssertTrue(image.isOpaque, "a 16-bit P3 base has no alpha; every sample must be 1.0")

        // Orientation: row 0 is the PNG's top row (red/green/white), row 1 the bottom row.
        let topLeft = image.pixel(x: 0, y: 0)
        XCTAssertEqual(Double(topLeft.r), 1, accuracy: 1e-4)
        XCTAssertEqual(Double(topLeft.g), 0, accuracy: 1e-4)
        XCTAssertEqual(Double(topLeft.b), 0, accuracy: 1e-4)
        let topMiddle = image.pixel(x: 1, y: 0)
        XCTAssertEqual(Double(topMiddle.g), 1, accuracy: 1e-4)
        let topRight = image.pixel(x: 2, y: 0)
        XCTAssertEqual(Double(topRight.r), 1, accuracy: 1e-4)
        XCTAssertEqual(Double(topRight.g), 1, accuracy: 1e-4)
        XCTAssertEqual(Double(topRight.b), 1, accuracy: 1e-4)
        let bottomLeft = image.pixel(x: 0, y: 1)
        XCTAssertEqual(Double(bottomLeft.a), 1, accuracy: 1e-6)

        // Linearisation: encoded 32768/65535 → sRGB EOTF ≈ 0.2140 in all channels.
        let midEncoded = Double(32768) / Double(UInt16.max)
        let midLinear = encodedToLinear(midEncoded)
        XCTAssertEqual(Double(bottomLeft.r), midLinear, accuracy: 1e-4)
        XCTAssertEqual(Double(bottomLeft.g), midLinear, accuracy: 1e-4)
        XCTAssertEqual(Double(bottomLeft.b), midLinear, accuracy: 1e-4)
        XCTAssertEqual(encodedToLinear(1), 1, accuracy: 1e-9)
        // Black stays black and blue stays blue (no channel swizzle).
        let black = image.pixel(x: 1, y: 1)
        XCTAssertEqual(Double(black.r), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(black.g), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(black.b), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(black.a), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(image.pixel(x: 2, y: 1).b), 1, accuracy: 1e-4)
    }

    // MARK: - Rejections

    func testValidateRejectsAn8BitPNG() throws {
        let data = try makePNG(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            space: TestSupport.displayP3ColorSpace(),
            alphaInfo: .noneSkipLast
        ) { _, _ in (0.5, 0.5, 0.5, 1) }
        XCTAssertThrowsError(try BasePNG.validate(data: data, expected: expectedBase(data, width: 2, height: 2))) { error in
            XCTAssertEqual(error as? BasePNGError, .not16Bit(actual: 8))
        }
    }

    func testValidateRejectsASRGBPNG() throws {
        let data = try makePNG(
            width: 2,
            height: 2,
            bitsPerComponent: 16,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            alphaInfo: .noneSkipLast
        ) { _, _ in (0.5, 0.5, 0.5, 1) }
        XCTAssertThrowsError(try BasePNG.validate(data: data, expected: expectedBase(data, width: 2, height: 2))) { error in
            guard case let .notDisplayP3(name) = error as? BasePNGError else {
                return XCTFail("expected .notDisplayP3, got \(error)")
            }
            XCTAssertEqual(name, Self.srgbName, "the rejection must report the actual profile name")
            XCTAssertNotEqual(name, Self.p3Name)
        }
    }

    func testValidateRejectsAPNGWithAlpha() throws {
        let data = try makePNG(
            width: 2,
            height: 2,
            bitsPerComponent: 16,
            space: TestSupport.displayP3ColorSpace(),
            alphaInfo: .premultipliedLast
        ) { _, _ in (1, 0.25, 0.1, 0.5) }
        XCTAssertThrowsError(try BasePNG.validate(data: data, expected: expectedBase(data, width: 2, height: 2))) { error in
            XCTAssertEqual(error as? BasePNGError, .hasAlpha)
        }
    }

    func testValidateRejectsWrongDimensions() throws {
        let data = try TestSupport.make16BitDisplayP3PNG(width: 2, height: 2) { _, _ in
            (UInt16.max, 0, 0)
        }
        XCTAssertThrowsError(
            try BasePNG.validate(data: data, expected: expectedBase(data, width: 3, height: 2))
        ) { error in
            XCTAssertEqual(
                error as? BasePNGError,
                .dimensionMismatch(
                    expected: PixelSize(width: 3, height: 2),
                    actual: PixelSize(width: 2, height: 2)
                )
            )
        }
    }

    func testValidateRejectsAHashMismatchBeforeDecoding() throws {
        let data = try TestSupport.make16BitDisplayP3PNG(width: 2, height: 2) { _, _ in
            (0, UInt16.max, 0)
        }
        let expectedHash = String(repeating: "0", count: 64)
        XCTAssertThrowsError(
            try BasePNG.validate(
                data: data,
                expected: expectedBase(data, width: 2, height: 2, sha256: expectedHash)
            )
        ) { error in
            XCTAssertEqual(
                error as? BasePNGError,
                .hashMismatch(expected: expectedHash, actual: self.sha256Hex(data))
            )
        }
    }

    func testValidateRejectsNonImageData() throws {
        let data = Data("this is not a PNG".utf8)
        XCTAssertThrowsError(try BasePNG.validate(data: data, expected: expectedBase(data, width: 2, height: 2))) { error in
            XCTAssertEqual(error as? BasePNGError, .invalidData)
        }
        XCTAssertThrowsError(try BasePNG.linearise(data: data)) { error in
            XCTAssertEqual(error as? BasePNGError, .invalidData)
        }
    }

    func testValidateRejectsUnexpectedFormatOrWorkingSpaceMetadata() throws {
        let data = try TestSupport.make16BitDisplayP3PNG(width: 2, height: 2) { _, _ in
            (0, 0, UInt16.max)
        }
        XCTAssertThrowsError(
            try BasePNG.validate(
                data: data,
                expected: expectedBase(data, width: 2, height: 2, format: "png-8-srgb")
            )
        ) { error in
            guard case .formatUnexpected = error as? BasePNGError else {
                return XCTFail("expected .formatUnexpected, got \(error)")
            }
        }
        XCTAssertThrowsError(
            try BasePNG.validate(
                data: data,
                expected: expectedBase(
                    data,
                    width: 2,
                    height: 2,
                    workingSpace: "srgb-float32"
                )
            )
        ) { error in
            guard case .formatUnexpected = error as? BasePNGError else {
                return XCTFail("expected .formatUnexpected, got \(error)")
            }
        }
    }

    // MARK: - The real trial base (gitignored; skip when absent)

    func testRealTrialBaseWhenPresent() throws {
        guard let data = try TestSupport.loadWorkBasePNG() else {
            throw XCTSkip(
                "no trial base at work/m21-final/preview-base.png (or $PHOTON_M3_BASE_PNG); "
                    + "run `appctl serve`'s prepare on fixtures/media/sources/R0003777-P3.tif to produce it"
            )
        }
        // Measured on this machine (work/m21-final/meta.json, M2.1): 2560×1707, 16-bit Display P3
        // RGB, no alpha, 22,111,140 B. The real decode must be finite and opaque; the linear
        // values are the ones the shader consumes (row 0 is the top row of the photograph).
        let expected = expectedBase(data, width: 2560, height: 1707)
        let facts = try BasePNG.validate(data: data, expected: expected)
        XCTAssertEqual(facts.width, 2560)
        XCTAssertEqual(facts.height, 1707)
        XCTAssertEqual(facts.bitsPerComponent, 16)
        XCTAssertFalse(facts.hasAlpha)
        XCTAssertEqual(facts.colorSpaceName, Self.p3Name)

        let image = try BasePNG.load(data: data, expected: expected)
        XCTAssertEqual(image.size, PixelSize(width: 2560, height: 1707))
        XCTAssertTrue(image.isFinite, "the decoded base must contain no NaN/infinite samples")
        XCTAssertTrue(image.isOpaque)
        XCTAssertGreaterThan(image.maxChannel, 0.1, "a valid photograph cannot decode to black")
        XCTAssertLessThanOrEqual(image.maxChannel, 1.0001, "the SDR base is encoded at or below 1.0")
    }
}
