import Foundation
import ImageIO
import CoreGraphics
import CoreImage

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "work/m0/verify/out/sdr-p3.heic"
let url = URL(fileURLWithPath: path)
let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
print("cgimage: \(img.width)x\(img.height) bps=\(img.bitsPerComponent) bpp=\(img.bitsPerPixel) cs=\(img.colorSpace?.name as Any) alpha=\(img.alphaInfo.rawValue)")
let linP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CIContext(options: [.workingColorSpace: linP3, .outputColorSpace: linP3, .cacheIntermediates: false])
let ci = CIImage(cgImage: img)
let w = img.width, h = img.height
let rowBytes = w * 16
var buf = [Float](repeating: 0, count: w * h * 4)
buf.withUnsafeMutableBytes { raw in
    ctx.render(ci, toBitmap: raw.baseAddress!, rowBytes: rowBytes, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: linP3)
}
var maxVal: Float = -1
var maxLoc = (0, 0, 0)
for y in 0..<h {
    for x in 0..<w {
        for c in 0..<3 {
            let v = buf[(y * w + x) * 4 + c]
            if v > maxVal { maxVal = v; maxLoc = (x, y, c) }
        }
    }
}
print("CI extLinearP3 max=\(maxVal) at \(maxLoc)")

// render to displayP3 gamma float: max should be <= 1 if no overshoot
let ctx2 = CIContext(options: [.workingColorSpace: p3, .outputColorSpace: p3, .cacheIntermediates: false])
var buf2 = [Float](repeating: 0, count: w * h * 4)
buf2.withUnsafeMutableBytes { raw in
    ctx2.render(ci, toBitmap: raw.baseAddress!, rowBytes: rowBytes, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: p3)
}
var max2: Float = -1
for i in stride(from: 0, to: buf2.count, by: 4) { for c in 0..<3 { if buf2[i + c] > max2 { max2 = buf2[i + c] } } }
print("CI displayP3 (gamma) max=\(max2)")

// raw 8-bit bytes via CGContext draw into displayP3
if let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: p3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
    cg.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = cg.data!.assumingMemoryBound(to: UInt8.self)
    var rawMax = 0
    for i in 0..<(w * h * 4) where i % 4 != 3 { if Int(p[i]) > rawMax { rawMax = Int(p[i]) } }
    print("raw 8-bit P3 max=\(rawMax)")
}
print("pixel at CI max loc: extLinP3=", (0..<4).map { buf[(maxLoc.1 * w + maxLoc.0) * 4 + $0] }, "gammaP3=", (0..<4).map { buf2[(maxLoc.1 * w + maxLoc.0) * 4 + $0] })
