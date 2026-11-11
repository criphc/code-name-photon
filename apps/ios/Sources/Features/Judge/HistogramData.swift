import Foundation
import ContractKit

/// base 的 256 桶直方图（按当前草稿的 gain 计算）。
///
/// 横轴不随图像内容变，但上限随 cap 变：左半段是 SDR 线性 0…1，右半段是 0…log2(cap) stops
/// （cap picker 选到哪一档就画到哪）。上限来自 recipe，不需要先扫一遍求最大亮度。
struct HistogramData: Sendable, Equatable {
    static let binCount = 256
    /// SDR 段在横轴里占的比例（剩下的是 HDR stop 段）。
    static let sdrFraction: Float = 0.5

    /// HDR 段的横轴上限（stops），`compute` 按当前 cap 写入。
    let hdrStops: Float

    let red: [Float]
    let green: [Float]
    let blue: [Float]
    let luma: [Float]

    /// 线性光值 → 横轴 0…1 的位置。
    static func axisPosition(for value: Float, hdrStops: Float) -> Float {
        guard value > 0 else { return 0 }
        if value <= 1 { return value * sdrFraction }
        guard hdrStops > 0 else { return 1 }
        let stops = min(log2(value), hdrStops)
        return sdrFraction + stops / hdrStops * (1 - sdrFraction)
    }

    /// 隔行隔列采样（`stride`）：直方图是统计量，没必要逐像素。
    static func compute(image: LinearImage, shape: HighlightShape, stride: Int = 2) -> HistogramData {
        let cap = shape.headroomCap
        let hdrStops = max(log2(cap), 0.001)
        var red = [Float](repeating: 0, count: binCount)
        var green = [Float](repeating: 0, count: binCount)
        var blue = [Float](repeating: 0, count: binCount)
        var luma = [Float](repeating: 0, count: binCount)

        func bin(_ value: Float) -> Int {
            let position = Self.axisPosition(for: min(value, cap), hdrStops: hdrStops)
            return min(max(Int(position * Float(binCount)), 0), binCount - 1)
        }

        image.pixels.withUnsafeBufferPointer { pixels in
            let width = image.size.width
            let height = image.size.height
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    let index = (y * width + x) * 4
                    let r0 = pixels[index]
                    let g0 = pixels[index + 1]
                    let b0 = pixels[index + 2]

                    let baseLuma = 0.2126 * r0 + 0.7152 * g0 + 0.0722 * b0
                    let gain = shape.gain(luma: baseLuma)

                    let r = min(r0 * gain, cap)
                    let g = min(g0 * gain, cap)
                    let b = min(b0 * gain, cap)
                    let l = 0.2126 * r + 0.7152 * g + 0.0722 * b

                    red[bin(r)] += 1
                    green[bin(g)] += 1
                    blue[bin(b)] += 1
                    luma[bin(l)] += 1

                    x += stride
                }
                y += stride
            }
        }

        // 四条曲线共用同一个归一化因子，相对高度才有意义。
        let peak = max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0, luma.max() ?? 0)
        if peak > 0 {
            red = red.map { $0 / peak }
            green = green.map { $0 / peak }
            blue = blue.map { $0 / peak }
            luma = luma.map { $0 / peak }
        }

        return HistogramData(hdrStops: hdrStops, red: red, green: green, blue: blue, luma: luma)
    }
}
