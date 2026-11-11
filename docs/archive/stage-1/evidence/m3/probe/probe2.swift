import Foundation
import ImageIO
import CoreGraphics
import CoreImage

let path = "/Users/criphc/Sites/llm-photon/work/m21-final/preview-base.png"
let data = try! Data(contentsOf: URL(fileURLWithPath: path))
let src = CGImageSourceCreateWithData(data as CFData, nil)!
let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let w = min(cg.width, 8), h = min(cg.height, 4)
// crop first 8x4
let crop = cg.cropping(to: CGRect(x: 0, y: 0, width: w, height: h))!
print("cropped bpc", crop.bitsPerComponent, "bpp", crop.bitsPerPixel)

let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
func tryCtx(_ name: String, _ bitmapInfo: UInt32) {
    var buf = [Float](repeating: -99, count: w*h*4)
    let ok = buf.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w*16, space: space, bitmapInfo: bitmapInfo) else { print(name, "ctx nil"); return false }
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    print(name, "ok", ok, "first", buf[0..<8].map { String(format: "%.4g", $0) }.joined(separator: ","), "max", buf.max()!, "min", buf.min()!)
}

let alphaPremulLast = CGImageAlphaInfo.premultipliedLast.rawValue
let alphaNoneSkipLast = CGImageAlphaInfo.noneSkipLast.rawValue
tryCtx("float+premulLast", alphaPremulLast | CGBitmapInfo.floatComponents.rawValue)
tryCtx("float+premulLast+LE", alphaPremulLast | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
tryCtx("float+premulLast+BE", alphaPremulLast | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
tryCtx("float+noneSkipLast", alphaNoneSkipLast | CGBitmapInfo.floatComponents.rawValue)
tryCtx("float+noneSkipLast+LE", alphaNoneSkipLast | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

// CIContext render RGBAf
let ci = CIImage(cgImage: crop)
let ctxCI = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
var buf2 = [Float](repeating: -99, count: w*h*4)
buf2.withUnsafeMutableBytes { raw in
    ctxCI.render(ci, toBitmap: raw.baseAddress!, rowBytes: w*16, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAf, colorSpace: space)
}
print("CI RGBAf", buf2[0..<8].map { String(format: "%.4g", $0) }.joined(separator: ","), "max", buf2.max()!, "min", buf2.min()!)
