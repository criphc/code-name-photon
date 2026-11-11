import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import EngineKit

/// The read-back contract behind review P0-1: a HEIC is only accepted when ImageIO can see the
/// ISO gain map, no alpha plane, the expected size and an advertised headroom near the authored
/// peak. These tests need no encoder — they write a plain SDR HEIC with Core Image.
final class EncodedHEICValidationTests: XCTestCase {
    /// A gain-map-free HEIC written by Core Image is exactly what `toGainMapHDR` degrades to for a
    /// too-dim pair, so the validator must reject it with a reason that names the ISO auxiliary.
    func testPlainSDRHEICIsRejected() throws {
        let directory = try TestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let size = PixelSize(width: 32, height: 24)
        let url = directory.appendingPathComponent("plain.heic")
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = CIContext(options: [
            .workingColorSpace: displayP3,
            .outputColorSpace: displayP3,
            .cacheIntermediates: false,
        ])
        let image = CIImage(
            color: CIColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1, colorSpace: displayP3)!
        ).cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        try context.writeHEIFRepresentation(
            of: image,
            to: url,
            format: .RGBA8,
            colorSpace: displayP3,
            options: [:]
        )

        let facts = try EncodedHEICValidator.inspect(url)
        XCTAssertFalse(facts.isoGainMapPresent, "Core Image writes no ISO gain map")
        XCTAssertEqual(facts.width, size.width)
        XCTAssertEqual(facts.height, size.height)
        XCTAssertEqual(facts.sdrBitsPerComponent, 8)

        XCTAssertThrowsError(
            try EncodedHEICValidator.validate(url, expectedSize: nil)
        ) { error in
            guard case let PhotonError.encoderOutputInvalid(_, reason)? = error as? PhotonError else {
                return XCTFail("expected encoderOutputInvalid, got \(error)")
            }
            XCTAssertTrue(
                reason.contains("ISO") || reason.contains("gain-map"),
                "the reason must name the missing ISO gain map: \(reason)"
            )
        }
    }

    func testMissingFileIsEncoderOutputInvalid() {
        let missing = URL(fileURLWithPath: "/definitely/not/here/photon-\(UUID().uuidString).heic")

        XCTAssertThrowsError(try EncodedHEICValidator.inspect(missing)) { error in
            guard case let PhotonError.encoderOutputInvalid(path, reason)? = error as? PhotonError else {
                return XCTFail("expected encoderOutputInvalid, got \(error)")
            }
            XCTAssertEqual(path, missing.standardizedFileURL.path)
            XCTAssertFalse(reason.isEmpty, "the reason must say why the file is not a valid HEIC")
        }

        XCTAssertThrowsError(
            try EncodedHEICValidator.validate(missing, expectedSize: nil)
        ) { error in
            guard case PhotonError.encoderOutputInvalid? = error as? PhotonError else {
                return XCTFail("expected encoderOutputInvalid, got \(error)")
            }
        }
    }
}
