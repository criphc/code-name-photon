import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import EngineKit

/// CIELAB / CIEDE2000 acceptance tests for the colour half of M1.
///
/// The ΔE2000 numbers are checked against the complete published supplementary test set from
/// Sharma, Wu & Dalal (2005), "The CIEDE2000 Color-Difference Formula: Implementation Notes,
/// Supplementary Test Data, and Mathematical Observations" — the official
/// `ciede2000testdata.txt` distributed by the first author. Pairs 1–6 are the blue
/// hue-rotation edge cases the formula is notorious for; a regression there fails the
/// encompassing table test with the failing pair named in its message.
final class ColorimetryTests: XCTestCase {
    // MARK: - Display P3 → Lab

    func testDisplayP3WhiteIsLabReferenceWhite() {
        let white = Colorimetry.lab(RGBA(r: 1, g: 1, b: 1))
        XCTAssertEqual(white.L, 100.0, accuracy: 1e-12)
        XCTAssertEqual(white.a, 0.0, accuracy: 1e-12)
        XCTAssertEqual(white.b, 0.0, accuracy: 1e-12)
    }

    func testBlackMapsToLabOrigin() {
        let black = Colorimetry.lab(RGBA(r: 0, g: 0, b: 0))
        XCTAssertEqual(black.L, 0.0, accuracy: 1e-12)
        XCTAssertEqual(black.a, 0.0, accuracy: 1e-12)
        XCTAssertEqual(black.b, 0.0, accuracy: 1e-12)
    }

    /// Neutrals have no chroma in Lab regardless of the transfer function.
    func testNeutralGreyHasZeroChroma() {
        for value in [Float(0.02), 0.18, 0.5, 0.98] {
            let lab = Colorimetry.lab(RGBA(r: value, g: value, b: value))
            XCTAssertEqual(lab.a, 0.0, accuracy: 1e-9, "neutral \(value) has a* = \(lab.a)")
            XCTAssertEqual(lab.b, 0.0, accuracy: 1e-9, "neutral \(value) has b* = \(lab.b)")
            XCTAssertGreaterThan(lab.L, 0)
            XCTAssertLessThan(lab.L, 100)
        }
    }

    /// Independent cross-check of the P3→XYZ matrix + Lab pipeline: sRGB's red primary expressed
    /// in linear Display P3 (standard sRGB→Display P3 linear-light matrix; red maps to
    /// (0.822592, 0.033200, 0.017086)) must come out at the published sRGB-red CIELAB value
    /// (53.2408, 80.0925, 67.2032). Tolerance covers the 6-decimal rounding of that matrix.
    func testSRGBRedInLinearP3HasSRGBRedLab() {
        let lab = Colorimetry.lab(RGBA(r: 0.822592, g: 0.033200, b: 0.017086))
        XCTAssertEqual(lab.L, 53.2408, accuracy: 0.01)
        XCTAssertEqual(lab.a, 80.0925, accuracy: 0.01)
        XCTAssertEqual(lab.b, 67.2032, accuracy: 0.01)
    }

    // MARK: - CIEDE2000

    func testDeltaE2000MatchesSharmaTable() {
        var failures: [String] = []
        for (index, pair) in Self.sharmaTable.enumerated() {
            let got = Colorimetry.deltaE2000(
                LABColor(L: pair.l1, a: pair.a1, b: pair.b1),
                LABColor(L: pair.l2, a: pair.a2, b: pair.b2)
            )
            if abs(got - pair.expected) > 1e-4 {
                failures.append(
                    "pair \(index + 1): expected \(pair.expected), got \(got) "
                        + "(\(pair.l1), \(pair.a1), \(pair.b1) | \(pair.l2), \(pair.a2), \(pair.b2))"
                )
            }
        }
        XCTAssertTrue(failures.isEmpty, "CIEDE2000 disagrees with Sharma et al. (2005):\n" + failures.joined(separator: "\n"))
        XCTAssertEqual(Self.sharmaTable.count, 34)
    }

    func testDeltaE2000IsSymmetricAndZeroForIdenticalColours() {
        for pair in Self.sharmaTable.prefix(8) {
            let lhs = LABColor(L: pair.l1, a: pair.a1, b: pair.b1)
            let rhs = LABColor(L: pair.l2, a: pair.a2, b: pair.b2)
            XCTAssertEqual(
                Colorimetry.deltaE2000(lhs, rhs),
                Colorimetry.deltaE2000(rhs, lhs),
                accuracy: 1e-12
            )
            XCTAssertEqual(Colorimetry.deltaE2000(lhs, lhs), 0.0, accuracy: 1e-12)
        }
    }

    /// The P3-pixel convenience overload must agree with the Lab overload.
    func testPixelConvenienceMatchesLabOverload() {
        let lhs = RGBA(r: 0.12, g: 0.34, b: 0.56)
        let rhs = RGBA(r: 0.34, g: 0.56, b: 0.78)
        XCTAssertEqual(
            Colorimetry.deltaE2000(lhs, rhs),
            Colorimetry.deltaE2000(Colorimetry.lab(lhs), Colorimetry.lab(rhs)),
            accuracy: 1e-15
        )
        XCTAssertGreaterThan(Colorimetry.deltaE2000(lhs, rhs), 0)
    }

    // MARK: - Sharma, Wu & Dalal (2005), Table 1 — all 34 pairs

    private struct SharmaPair {
        let l1: Double, a1: Double, b1: Double
        let l2: Double, a2: Double, b2: Double
        let expected: Double
    }

    private static let sharmaTable: [SharmaPair] = [
        SharmaPair(l1: 50.0000, a1: 2.6772, b1: -79.7751, l2: 50.0000, a2: 0.0000, b2: -82.7485, expected: 2.0425),
        SharmaPair(l1: 50.0000, a1: 3.1571, b1: -77.2803, l2: 50.0000, a2: 0.0000, b2: -82.7485, expected: 2.8615),
        SharmaPair(l1: 50.0000, a1: 2.8361, b1: -74.0200, l2: 50.0000, a2: 0.0000, b2: -82.7485, expected: 3.4412),
        SharmaPair(l1: 50.0000, a1: -1.3802, b1: -84.2814, l2: 50.0000, a2: 0.0000, b2: -82.7485, expected: 1.0000),
        SharmaPair(l1: 50.0000, a1: -1.1848, b1: -84.8006, l2: 50.0000, a2: 0.0000, b2: -82.7485, expected: 1.0000),
        SharmaPair(l1: 50.0000, a1: -0.9009, b1: -85.5211, l2: 50.0000, a2: 0.0000, b2: -82.7485, expected: 1.0000),
        SharmaPair(l1: 50.0000, a1: 0.0000, b1: 0.0000, l2: 50.0000, a2: -1.0000, b2: 2.0000, expected: 2.3669),
        SharmaPair(l1: 50.0000, a1: -1.0000, b1: 2.0000, l2: 50.0000, a2: 0.0000, b2: 0.0000, expected: 2.3669),
        SharmaPair(l1: 50.0000, a1: 2.4900, b1: -0.0010, l2: 50.0000, a2: -2.4900, b2: 0.0009, expected: 7.1792),
        SharmaPair(l1: 50.0000, a1: 2.4900, b1: -0.0010, l2: 50.0000, a2: -2.4900, b2: 0.0010, expected: 7.1792),
        SharmaPair(l1: 50.0000, a1: 2.4900, b1: -0.0010, l2: 50.0000, a2: -2.4900, b2: 0.0011, expected: 7.2195),
        SharmaPair(l1: 50.0000, a1: 2.4900, b1: -0.0010, l2: 50.0000, a2: -2.4900, b2: 0.0012, expected: 7.2195),
        SharmaPair(l1: 50.0000, a1: -0.0010, b1: 2.4900, l2: 50.0000, a2: 0.0009, b2: -2.4900, expected: 4.8045),
        SharmaPair(l1: 50.0000, a1: -0.0010, b1: 2.4900, l2: 50.0000, a2: 0.0010, b2: -2.4900, expected: 4.8045),
        SharmaPair(l1: 50.0000, a1: -0.0010, b1: 2.4900, l2: 50.0000, a2: 0.0011, b2: -2.4900, expected: 4.7461),
        SharmaPair(l1: 50.0000, a1: 2.5000, b1: 0.0000, l2: 50.0000, a2: 0.0000, b2: -2.5000, expected: 4.3065),
        SharmaPair(l1: 50.0000, a1: 2.5000, b1: 0.0000, l2: 73.0000, a2: 25.0000, b2: -18.0000, expected: 27.1492),
        SharmaPair(l1: 50.0000, a1: 2.5000, b1: 0.0000, l2: 61.0000, a2: -5.0000, b2: 29.0000, expected: 22.8977),
        SharmaPair(l1: 50.0000, a1: 2.5000, b1: 0.0000, l2: 56.0000, a2: -27.0000, b2: -3.0000, expected: 31.9030),
        SharmaPair(l1: 50.0000, a1: 2.5000, b1: 0.0000, l2: 58.0000, a2: 24.0000, b2: 15.0000, expected: 19.4535),
        SharmaPair(l1: 50.0000, a1: 2.5000, b1: 0.0000, l2: 50.0000, a2: 3.1736, b2: 0.5854, expected: 1.0000),
        SharmaPair(l1: 50.0000, a1: 2.5000, b1: 0.0000, l2: 50.0000, a2: 3.2972, b2: 0.0000, expected: 1.0000),
        SharmaPair(l1: 50.0000, a1: 2.5000, b1: 0.0000, l2: 50.0000, a2: 1.8634, b2: 0.5757, expected: 1.0000),
        SharmaPair(l1: 50.0000, a1: 2.5000, b1: 0.0000, l2: 50.0000, a2: 3.2592, b2: 0.3350, expected: 1.0000),
        SharmaPair(l1: 60.2574, a1: -34.0099, b1: 36.2677, l2: 60.4626, a2: -34.1751, b2: 39.4387, expected: 1.2644),
        SharmaPair(l1: 63.0109, a1: -31.0961, b1: -5.8663, l2: 62.8187, a2: -29.7946, b2: -4.0864, expected: 1.2630),
        SharmaPair(l1: 61.2901, a1: 3.7196, b1: -5.3901, l2: 61.4292, a2: 2.2480, b2: -4.9620, expected: 1.8731),
        SharmaPair(l1: 35.0831, a1: -44.1164, b1: 3.7933, l2: 35.0232, a2: -40.0716, b2: 1.5901, expected: 1.8645),
        SharmaPair(l1: 22.7233, a1: 20.0904, b1: -46.6940, l2: 23.0331, a2: 14.9730, b2: -42.5619, expected: 2.0373),
        SharmaPair(l1: 36.4612, a1: 47.8580, b1: 18.3852, l2: 36.2715, a2: 50.5065, b2: 21.2231, expected: 1.4146),
        SharmaPair(l1: 90.8027, a1: -2.0831, b1: 1.4410, l2: 91.1528, a2: -1.6435, b2: 0.0447, expected: 1.4441),
        SharmaPair(l1: 90.9257, a1: -0.5406, b1: -0.9208, l2: 88.6381, a2: -0.8985, b2: -0.7239, expected: 1.5381),
        SharmaPair(l1: 6.7747, a1: -0.2908, b1: -2.4247, l2: 5.8714, a2: -0.0985, b2: -2.2286, expected: 0.6377),
        SharmaPair(l1: 2.0776, a1: 0.0795, b1: -1.1350, l2: 0.9033, a2: -0.0636, b2: -0.5514, expected: 0.9082),
    ]
}
