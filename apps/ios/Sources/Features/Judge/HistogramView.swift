import SwiftUI

/// 直方图：RGB 三色线 + luma 线（带填充）。
/// 横轴：左半 SDR 线性，右半 0…cap stops（上限跟着 cap 走），每个整数 stop 一条虚线。
struct HistogramView: View {
    let data: HistogramData?
    /// `data` 还没算完时用当前 cap 的 stops 画刻度。
    let hdrStops: Float

    var body: some View {
        Canvas { context, size in
            let axisStops = self.axisStops
            if axisStops >= 1 {
                for stop in 1...Int(axisStops) {
                    let fraction = HistogramData.sdrFraction
                        + Float(stop) / axisStops * (1 - HistogramData.sdrFraction)
                    let x = size.width * CGFloat(fraction)
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0))
                    line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line,
                                   with: .color(.primary.opacity(0.28)),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }

            // SDR 白（线性 1.0）的分界。
            let sdrX = size.width * CGFloat(HistogramData.sdrFraction)
            var sdrLine = Path()
            sdrLine.move(to: CGPoint(x: sdrX, y: 0))
            sdrLine.addLine(to: CGPoint(x: sdrX, y: size.height))
            context.stroke(sdrLine, with: .color(.primary.opacity(0.4)), lineWidth: 1)

            guard let data else { return }

            let lumaLine = path(data.luma, in: size)
            var fill = lumaLine
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(.primary.opacity(0.15)))

            context.stroke(path(data.red, in: size), with: .color(.red.opacity(0.8)), lineWidth: 1.5)
            context.stroke(path(data.green, in: size), with: .color(.green.opacity(0.8)), lineWidth: 1.5)
            context.stroke(path(data.blue, in: size), with: .color(.blue.opacity(0.8)), lineWidth: 1.5)
            context.stroke(lumaLine, with: .color(.primary.opacity(0.8)), lineWidth: 1.5)
        }
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue("HDR range up to \(axisStops, format: .number.precision(.fractionLength(1))) stops")
        .accessibilityIdentifier("adjustments.histogram")
    }

    private var axisStops: Float { data?.hdrStops ?? hdrStops }

    /// bin 在横轴上均匀分布（轴本身已经是 stop 刻度）。
    private func path(_ bins: [Float], in size: CGSize) -> Path {
        var path = Path()
        for index in bins.indices {
            let x = size.width * (CGFloat(index) + 0.5) / CGFloat(bins.count)
            let y = size.height * (1 - CGFloat(min(max(bins[index], 0), 1)))
            if path.isEmpty {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

#Preview("Histogram — cap 3.0 st") {
    HistogramView(data: sampleData(hdrStops: 3), hdrStops: 3)
        .frame(width: 560, height: 160)
        .padding()
}

#Preview("Histogram — cap 1.5 st") {
    HistogramView(data: sampleData(hdrStops: 1.5), hdrStops: 1.5)
        .frame(width: 560, height: 160)
        .padding()
}

private func sampleData(hdrStops: Float) -> HistogramData {
    HistogramData(
        hdrStops: hdrStops,
        red: (0..<256).map { index in
            let x = Float(index) / 255
            return exp(-pow((x - 0.2) / 0.12, 2)) + 0.5 * exp(-pow((x - 0.75) / 0.08, 2))
        },
        green: (0..<256).map { index in
            let x = Float(index) / 255
            return exp(-pow((x - 0.3) / 0.15, 2)) + 0.4 * exp(-pow((x - 0.7) / 0.1, 2))
        },
        blue: (0..<256).map { index in
            let x = Float(index) / 255
            return 0.8 * exp(-pow((x - 0.45) / 0.2, 2))
        },
        luma: (0..<256).map { index in
            let x = Float(index) / 255
            return exp(-pow((x - 0.35) / 0.18, 2)) + 0.35 * exp(-pow((x - 0.65) / 0.06, 2))
        }
    )
}
