import CoreGraphics
import Foundation

/// The ISO 21496-1 gain map: per-channel `log2(HDR / SDR)`, normalised to `[0, maxLogGain]`,
/// quantised to 8-bit RGB. The metadata template's `GainMapMax` is set to the same `maxLogGain`,
/// so the decoder's gain is the authored one.
///
/// The map is computed on the CPU (parallel over rows): the per-pixel work is one divide and one
/// `log2` per channel, and the spike measured the debug serial loop at ~21 s; the parallel release
/// loop is well under the encode time. A Core Image kernel is a later optimisation, not a
/// correctness requirement.
public enum GainMap {
    public struct Result {
        public let cgImage: CGImage
        public let width: Int
        public let height: Int
        public let maxLogGain: Double
    }

    /// - Parameters:
    ///   - base: the SDR base in linear extended Display P3.
    ///   - hdr: the authored HDR rendition in the same space.
    ///   - resolution: `.half` averages each 2×2 block before the ratio (Apple's half-res shape);
    ///     `.full` uses every pixel.
    ///   - authoredPeak: the largest HDR sample; the map's maximum log gain.
    /// - Throws: `PhotonError.invalidImage` for a size mismatch, a non-finite sample, or a peak
    ///   that cannot produce a positive log range.
    public static func make(
        base: LinearImage,
        hdr: LinearImage,
        resolution: HEICEncodeOptions.MapResolution,
        authoredPeak: Float
    ) throws -> Result {
        guard base.size == hdr.size else {
            throw PhotonError.invalidImage(
                reason: "gain map base \(base.size) and hdr \(hdr.size) differ"
            )
        }
        guard authoredPeak.isFinite, authoredPeak >= 1 else {
            throw PhotonError.invalidImage(reason: "gain map authored peak \(authoredPeak) must be >= 1")
        }
        let maxLogGain = log2(Double(authoredPeak))
        guard maxLogGain > 0 else {
            throw PhotonError.invalidImage(reason: "gain map authored peak \(authoredPeak) has no headroom")
        }
        let width = base.size.width
        let height = base.size.height
        guard width > 0, height > 0 else {
            throw PhotonError.invalidImage(reason: "gain map source has zero size")
        }
        let mapWidth = resolution == .half ? max(1, width / 2) : width
        let mapHeight = resolution == .half ? max(1, height / 2) : height
        var map = [UInt8](repeating: 0, count: mapWidth * mapHeight * 3)

        base.pixels.withUnsafeBufferPointer { sdr in
            hdr.pixels.withUnsafeBufferPointer { hdrPixels in
                map.withUnsafeMutableBufferPointer { out in
                    DispatchQueue.concurrentPerform(iterations: mapHeight) { my in
                        if resolution == .half {
                            writeHalfRow(
                                my, mapWidth: mapWidth, width: width, height: height,
                                sdr: sdr, hdr: hdrPixels, out: out, maxLogGain: maxLogGain
                            )
                        } else {
                            writeFullRow(
                                my, mapWidth: mapWidth, width: width,
                                sdr: sdr, hdr: hdrPixels, out: out, maxLogGain: maxLogGain
                            )
                        }
                    }
                }
            }
        }

        let data = Data(map)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw PhotonError.invalidImage(reason: "cannot create a gain-map data provider")
        }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cgImage = CGImage(
            width: mapWidth,
            height: mapHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: mapWidth * 3,
            space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw PhotonError.invalidImage(reason: "cannot create the gain-map CGImage")
        }
        return Result(cgImage: cgImage, width: mapWidth, height: mapHeight, maxLogGain: maxLogGain)
    }

    // MARK: - Rows

    private static func writeFullRow(
        _ my: Int,
        mapWidth: Int,
        width: Int,
        sdr: UnsafeBufferPointer<Float>,
        hdr: UnsafeBufferPointer<Float>,
        out: UnsafeMutableBufferPointer<UInt8>,
        maxLogGain: Double
    ) {
        let sourceRow = my * width * 4
        let mapRow = my * mapWidth * 3
        for mx in 0..<mapWidth {
            let i = sourceRow + mx * 4
            let o = mapRow + mx * 3
            for channel in 0..<3 {
                out[o + channel] = quantise(
                    sdr: Double(sdr[i + channel]),
                    hdr: Double(hdr[i + channel]),
                    maxLogGain: maxLogGain
                )
            }
        }
    }

    private static func writeHalfRow(
        _ my: Int,
        mapWidth: Int,
        width: Int,
        height: Int,
        sdr: UnsafeBufferPointer<Float>,
        hdr: UnsafeBufferPointer<Float>,
        out: UnsafeMutableBufferPointer<UInt8>,
        maxLogGain: Double
    ) {
        let y0 = my * 2
        let rows = min(2, height - y0)
        let mapRow = my * mapWidth * 3
        for mx in 0..<mapWidth {
            let x0 = mx * 2
            let columns = min(2, width - x0)
            let count = Double(rows * columns)
            var s0 = 0.0, s1 = 0.0, s2 = 0.0
            var h0 = 0.0, h1 = 0.0, h2 = 0.0
            for dy in 0..<rows {
                let row = (y0 + dy) * width * 4
                for dx in 0..<columns {
                    let i = row + (x0 + dx) * 4
                    s0 += Double(sdr[i]); s1 += Double(sdr[i + 1]); s2 += Double(sdr[i + 2])
                    h0 += Double(hdr[i]); h1 += Double(hdr[i + 1]); h2 += Double(hdr[i + 2])
                }
            }
            let o = mapRow + mx * 3
            out[o] = quantise(sdr: s0 / count, hdr: h0 / count, maxLogGain: maxLogGain)
            out[o + 1] = quantise(sdr: s1 / count, hdr: h1 / count, maxLogGain: maxLogGain)
            out[o + 2] = quantise(sdr: s2 / count, hdr: h2 / count, maxLogGain: maxLogGain)
        }
    }

    /// `q = round(clamp(log2(max(hdr / sdr, 1)), 0, maxLogGain) / maxLogGain * 255)`.
    private static func quantise(sdr: Double, hdr: Double, maxLogGain: Double) -> UInt8 {
        let gain = sdr > 1e-5 ? hdr / sdr : 1
        let logGain = min(max(log2(max(gain, 1)), 0), maxLogGain)
        let value = (logGain / maxLogGain * 255).rounded()
        return UInt8(min(max(value, 0), 255))
    }
}
