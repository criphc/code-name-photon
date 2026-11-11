import Foundation

/// A CIELAB colour (D65 white point), used for the ΔE2000 colour-accuracy checks in the delivery
/// report (docs/reference/deliver.md, report schema 1).
public struct LABColor: Equatable, Sendable {
    public let L: Double
    public let a: Double
    public let b: Double

    public init(L: Double, a: Double, b: Double) {
        self.L = L
        self.a = a
        self.b = b
    }
}

/// Colour science needed by M1's tests and by the M4 verification report.
///
/// The working space is linear extended Display P3 with a D65 white: 1.0 in all three
/// channels is the reference white, so a white pixel maps to L* = 100, a* = b* = 0.
/// Nothing here clips: out-of-gamut / negative values produced by colour management still
/// produce a mathematically defined Lab, which is what the round-trip tests need.
public enum Colorimetry {
    // Display P3 (SMPTE RP 431-2 primaries R(0.680, 0.320), G(0.265, 0.690),
    // B(0.150, 0.060), D65 white x=0.3127, y=0.3290) → CIE XYZ, D65.
    //
    // Derived from the primaries and the D65 white point with the standard
    // "chromaticity → XYZ → invert" procedure; this is the matrix published in the
    // Display P3 / CSS Color 4 specifications (values rounded to 16 significant digits).
    // Each row sums to the corresponding D65 tristimulus value (0.9504559…, 1.0, 1.0890578…),
    // so `whiteX/Y/Z` below are consistent with the matrix by construction.
    //
    // Nine `Double` constants, not a `[[Double]]`: the per-pixel `lab()` call is the hot loop of
    // every full-resolution comparison, and in a debug build the array subscripting adds an ARC
    // retain/release per access. That made the parallel ΔE pass slower than the serial one
    // (0.39×; docs/plans/verify-performance-investigation.md). The values are unchanged.
    private static let m00 = 0.4865709486482162
    private static let m01 = 0.26566769316909306
    private static let m02 = 0.1982172852343625
    private static let m10 = 0.2289745640697488
    private static let m11 = 0.6917385218365064
    private static let m12 = 0.079286914093745
    private static let m20 = 0.0
    private static let m21 = 0.04511338185890264
    private static let m22 = 1.043944368900976

    /// D65 white as reproduced by the matrix (the row sums), not a separately rounded constant.
    private static let whiteX = m00 + m01 + m02
    private static let whiteY = m10 + m11 + m12
    private static let whiteZ = m20 + m21 + m22

    /// Linear extended Display P3 (D65) → CIELAB (D65). Linear light in, absolute Lab out
    /// (no scaling: 1.0 is the reference white, i.e. Y = 1.0 ⇒ L* = 100).
    public static func lab(_ pixel: RGBA) -> LABColor {
        let r = Double(pixel.r)
        let g = Double(pixel.g)
        let b = Double(pixel.b)

        let x = m00 * r + m01 * g + m02 * b
        let y = m10 * r + m11 * g + m12 * b
        let z = m20 * r + m21 * g + m22 * b

        let fx = labF(x / whiteX)
        let fy = labF(y / whiteY)
        let fz = labF(z / whiteZ)
        return LABColor(L: 116.0 * fy - 16.0, a: 500.0 * (fx - fy), b: 200.0 * (fy - fz))
    }

    /// The CIE standard f(t) with δ = 6/29 (linear segment below the knee, cube root above).
    private static func labF(_ t: Double) -> Double {
        let delta = 6.0 / 29.0
        let delta3 = delta * delta * delta
        if t > delta3 { return cbrt(t) }
        return t / (3.0 * delta * delta) + 4.0 / 29.0
    }

    /// CIEDE2000 colour difference (Sharma et al. 2005 formulation, kL = kC = kH = 1).
    ///
    /// Implements the final formulation from "The CIEDE2000 Color-Difference Formula:
    /// Implementation Notes, Supplementary Test Data, and Mathematical Observations"
    /// (Sharma, Wu & Dalal, 2005), including the hue-difference wrap rules around 0°/360°
    /// and the mean-hue rules for the neutral (C' = 0) cases. A validation table of all
    /// 34 published test pairs lives in `ColorimetryTests`.
    public static func deltaE2000(_ lhs: LABColor, _ rhs: LABColor) -> Double {
        let l1 = lhs.L, a1 = lhs.a, b1 = lhs.b
        let l2 = rhs.L, a2 = rhs.a, b2 = rhs.b

        // Step 1 — C' and h' in the a'b' plane.
        let c1 = (a1 * a1 + b1 * b1).squareRoot()
        let c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cBar = (c1 + c2) / 2.0
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1.0 - (cBar7 / (cBar7 + pow(25.0, 7))).squareRoot())
        let a1p = (1.0 + g) * a1
        let a2p = (1.0 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot()
        let c2p = (a2p * a2p + b2 * b2).squareRoot()
        let h1p = hueAngle(b: b1, a: a1p, chroma: c1p)
        let h2p = hueAngle(b: b2, a: a2p, chroma: c2p)

        // Step 2 — ΔL', ΔC', ΔH'.
        let dLp = l2 - l1
        let dCp = c2p - c1p
        let dhp: Double
        if c1p * c2p == 0.0 {
            dhp = 0.0
        } else if h2p - h1p > 180.0 {
            dhp = h2p - h1p - 360.0
        } else if h2p - h1p < -180.0 {
            dhp = h2p - h1p + 360.0
        } else {
            dhp = h2p - h1p
        }
        let dHp = 2.0 * (c1p * c2p).squareRoot() * sin(radians(dhp) / 2.0)

        // Step 3 — weighting functions.
        let lBarP = (l1 + l2) / 2.0
        let cBarP = (c1p + c2p) / 2.0
        let hBarP: Double
        if c1p * c2p == 0.0 {
            hBarP = h1p + h2p
        } else if abs(h1p - h2p) <= 180.0 {
            hBarP = (h1p + h2p) / 2.0
        } else if h1p + h2p < 360.0 {
            hBarP = (h1p + h2p + 360.0) / 2.0
        } else {
            hBarP = (h1p + h2p - 360.0) / 2.0
        }

        let t = 1.0
            - 0.17 * cos(radians(hBarP - 30.0))
            + 0.24 * cos(radians(2.0 * hBarP))
            + 0.32 * cos(radians(3.0 * hBarP + 6.0))
            - 0.20 * cos(radians(4.0 * hBarP - 63.0))

        let dTheta = 30.0 * exp(-pow((hBarP - 275.0) / 25.0, 2))
        let cBarP7 = pow(cBarP, 7)
        let rC = 2.0 * (cBarP7 / (cBarP7 + pow(25.0, 7))).squareRoot()
        let rT = -sin(radians(2.0 * dTheta)) * rC

        let sL = 1.0 + (0.015 * pow(lBarP - 50.0, 2)) / (20.0 + pow(lBarP - 50.0, 2)).squareRoot()
        let sC = 1.0 + 0.045 * cBarP
        let sH = 1.0 + 0.015 * cBarP * t

        let termL = dLp / sL
        let termC = dCp / sC
        let termH = dHp / sH
        return (termL * termL + termC * termC + termH * termH + rT * termC * termH).squareRoot()
    }

    /// Convenience: ΔE2000 between two linear Display P3 pixels.
    public static func deltaE2000(_ lhs: RGBA, _ rhs: RGBA) -> Double {
        deltaE2000(lab(lhs), lab(rhs))
    }

    /// Hue angle in degrees, 0 ≤ h < 360; a neutral colour (C' = 0) reports 0.
    private static func hueAngle(b: Double, a: Double, chroma: Double) -> Double {
        guard chroma != 0.0 else { return 0.0 }
        var degrees = atan2(b, a) * 180.0 / Double.pi
        if degrees < 0.0 { degrees += 360.0 }
        return degrees
    }

    private static func radians(_ degrees: Double) -> Double { degrees * Double.pi / 180.0 }
}
