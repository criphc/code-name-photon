import CoreGraphics
import CoreImage
import Foundation

// Find a float-RGBA CGImage bitmapInfo that Core Image renders correctly.
let linP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let w = 8, h = 8
var pixels = [Float](repeating: 0, count: w * h * 4)
for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i] = 0.5; pixels[i+1] = 0.25; pixels[i+2] = 0.125; pixels[i+3] = 1 }
let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }

let combos: [(String, CGBitmapInfo)] = [
    ("floatComponents only", CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue)),
    ("float|premultipliedLast", CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)),
    ("float|noneSkipLast", CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)),
    ("float|premultipliedLast|byteOrder32Little", CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)),
    ("float|noneSkipLast|byteOrder32Little", CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)),
]
for (name, info) in combos {
    guard let provider = CGDataProvider(data: data as CFData),
          let cg = CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16,
                           space: linP3, bitmapInfo: info, provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent) else { print("\(name): CGImage nil"); continue }
    let ci = CIImage(cgImage: cg)
    var out = [Float](repeating: 0, count: 4)
    CIContext(options: [.workingColorSpace: linP3, .outputColorSpace: linP3]).render(ci, toBitmap: &out, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linP3)
    print("\(name): px=\(out)")
}
