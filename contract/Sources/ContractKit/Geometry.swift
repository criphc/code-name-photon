import Foundation

/// Pixel geometry of a decoded image / rendered buffer.
public struct PixelSize: Codable, Equatable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixelCount: Int { width * height }
    public var description: String { "\(width)x\(height)" }
}

/// One pixel of the working space: linear light, extended Display P3 primaries, D65,
/// where 1.0 is SDR reference white and values above 1.0 are authored HDR.
public struct RGBA: Equatable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let transparent = RGBA(r: 0, g: 0, b: 0, a: 0)

    /// Rec.709 luma of the linear RGB components. Used for the highlight mask; alpha is ignored.
    /// This is the exact luma definition the highlight mask and its tests share.
    public var rec709Luma: Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    public var isFinite: Bool { r.isFinite && g.isFinite && b.isFinite && a.isFinite }
}

/// The Stage-1 working buffer: interleaved RGBA `Float32` in linear extended Display P3,
/// row-major, top row first, alpha always 1.0. No clipping is applied on decode: values may
/// exceed 1.0 once the HDR rendition is built, and that is the point of this type.
///
/// Geometry dictates `pixels.count == size.pixelCount * 4`. The type is a value type on
/// purpose: M1's determinism contract is "same source + recipe → identical bytes", and
/// immutable-ish buffers make that easy to reason about.
public struct LinearImage: Sendable {
    public let size: PixelSize
    public private(set) var pixels: [Float]

    /// Creates a buffer from raw interleaved RGBA float data.
    /// - Throws: `PhotonError.invalidImage` if the element count does not match the geometry.
    public init(size: PixelSize, pixels: [Float]) throws {
        guard pixels.count == size.pixelCount * 4 else {
            throw PhotonError.invalidImage(
                reason: "expected \(size.pixelCount * 4) floats for \(size), got \(pixels.count)"
            )
        }
        self.size = size
        self.pixels = pixels
    }

    /// Creates a buffer filled with a uniform pixel (default: black, opaque).
    public init(size: PixelSize, repeating pixel: RGBA = .black) {
        self.size = size
        self.pixels = [Float](repeating: 0, count: size.pixelCount * 4)
        if pixel != .black {
            for index in stride(from: 0, to: pixels.count, by: 4) {
                pixels[index] = pixel.r
                pixels[index + 1] = pixel.g
                pixels[index + 2] = pixel.b
                pixels[index + 3] = pixel.a
            }
        }
    }

    /// Row-major index of the first float of pixel (x, y). No bounds checking.
    public func pixelIndex(x: Int, y: Int) -> Int { (y * size.width + x) * 4 }

    public func pixel(x: Int, y: Int) -> RGBA {
        let index = pixelIndex(x: x, y: y)
        return RGBA(r: pixels[index], g: pixels[index + 1], b: pixels[index + 2], a: pixels[index + 3])
    }

    public mutating func setPixel(x: Int, y: Int, _ value: RGBA) {
        let index = pixelIndex(x: x, y: y)
        pixels[index] = value.r
        pixels[index + 1] = value.g
        pixels[index + 2] = value.b
        pixels[index + 3] = value.a
    }

    /// True when every alpha sample is exactly 1.0 (what every Stage-1 deliverable must be).
    public var isOpaque: Bool {
        for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] != 1 {
            return false
        }
        return true
    }

    /// True when no sample is NaN / infinite.
    public var isFinite: Bool {
        for value in pixels where !value.isFinite { return false }
        return true
    }

    /// Largest R/G/B sample in the buffer (alpha ignored). Used to assert the authored headroom.
    public var maxChannel: Float {
        var peak: Float = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let value = max(pixels[index], max(pixels[index + 1], pixels[index + 2]))
            if value > peak { peak = value }
        }
        return peak
    }

    /// Fraction of pixels whose largest R/G/B sample is greater than `threshold`.
    public func fractionAbove(_ threshold: Float) -> Double {
        guard size.pixelCount > 0 else { return 0 }
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if max(pixels[index], max(pixels[index + 1], pixels[index + 2])) > threshold { count += 1 }
        }
        return Double(count) / Double(size.pixelCount)
    }

    /// Element-wise pixel transform (value semantics: returns a new buffer).
    public func map(_ transform: (RGBA) -> RGBA) -> LinearImage {
        var output = pixels
        for index in stride(from: 0, to: output.count, by: 4) {
            let value = transform(
                RGBA(r: output[index], g: output[index + 1], b: output[index + 2], a: output[index + 3])
            )
            output[index] = value.r
            output[index + 1] = value.g
            output[index + 2] = value.b
            output[index + 3] = value.a
        }
        return try! LinearImage(size: size, pixels: output)
    }
}
