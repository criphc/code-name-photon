import CoreImage
import CryptoKit
import Foundation

// Which Core Image operation is broken on its first use in a process?
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let decoded = try SourceDecoder.decode(url: source)
let base = try ToneMapper.sdrBase(from: decoded.linear, toneMap: .c1MatchV1)
let target = PreviewRenderer.targetSize(for: base.size, longEdge: 2560)
let linP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let bounds = CGRect(x: 0, y: 0, width: target.width, height: target.height)
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "plain"

func freshContext() -> CIContext {
    CIContext(options: [.workingColorSpace: linP3, .outputColorSpace: linP3, .cacheIntermediates: false])
}

func report(_ image: CIImage, _ name: String) {
    var pixels = [Float](repeating: 0, count: target.pixelCount * 4)
    let context = freshContext()
    context.render(image, toBitmap: &pixels, rowBytes: target.width * 16, bounds: bounds, format: .RGBAf, colorSpace: linP3)
    let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16)
    let mean = pixels.withUnsafeBufferPointer { b in
        stride(from: 0, to: b.count, by: 4).reduce(Float(0)) { $0 + b[$1] + b[$1 + 1] + b[$1 + 2] } / Float(target.pixelCount * 3)
    }
    print("\(name): sha=\(hash) meanRGB=\(mean)")
}

// A tiny unrelated Lanczos render, discarded: does it absorb the first-use problem?
func warmLanczos() {
    let small = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
    let scaled = small.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.5, kCIInputAspectRatioKey: 1.0])
    var pixels = [Float](repeating: 0, count: 16 * 16 * 4)
    freshContext().render(scaled, toBitmap: &pixels, rowBytes: 16 * 16, bounds: CGRect(x: 0, y: 0, width: 8, height: 8), format: .RGBAf, colorSpace: linP3)
}

switch mode {
case "warm":
    warmLanczos()
    report(PreviewRenderer.lanczos(PreviewRenderer.ciImage(base), to: target), "warmed-lanczos")
case "identity":
    // bitmapData-backed image with no filter at all
    let ci = PreviewRenderer.ciImage(base)
    report(ci, "identity-bitmap")
default:
    report(PreviewRenderer.lanczos(PreviewRenderer.ciImage(base), to: target), "plain-lanczos")
}
