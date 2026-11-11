import Foundation
import ImageIO
import CoreGraphics
import CoreImage

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "work/lead-smoke/out/hdr.heic"
let url = URL(fileURLWithPath: path)
let src = CGImageSourceCreateWithURL(url as CFURL, nil)!

func statsCI(_ img: CGImage, _ label: String, working: CGColorSpace, out: CGColorSpace, fmt: CIFormat) {
    let ctx = CIContext(options: [.workingColorSpace: working, .outputColorSpace: out, .cacheIntermediates: false])
    let w = img.width, h = img.height
    let bpp = fmt == .RGBAf ? 16 : 4
    var peak = [Float](repeating: -1, count: 4)
    var lower = [Float](repeating: 9, count: 4)
    let ci = CIImage(cgImage: img)
    let rowBytes = w * bpp
    var y = 0
    let strip = 256
    var buf = [UInt8](repeating: 0, count: max(rowBytes * strip, rowBytes))
    var minv = [Double](repeating: .infinity, count: 4)
    var minLoc = [(Int, Int)](repeating: (-1, -1), count: 4)
    var maxv = [Double](repeating: -.infinity, count: 4)
    while y < h {
        let rows = min(strip, h - y)
        if fmt == .RGBAf {
            buf.withUnsafeMutableBytes { raw in
                ctx.render(ci, toBitmap: raw.baseAddress!, rowBytes: rowBytes,
                           bounds: CGRect(x: 0, y: y, width: w, height: rows),
                           format: .RGBAf, colorSpace: out)
            }
            let f = buf.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            for r in 0..<rows {
                for x in 0..<w {
                    for c in 0..<4 {
                        let v = Double(f[(r * w + x) * 4 + c])
                        if v < minv[c] { minv[c] = v; minLoc[c] = (x, y + r) }
                        if v > maxv[c] { maxv[c] = v }
                    }
                }
            }
        } else {
            buf.withUnsafeMutableBytes { raw in
                ctx.render(ci, toBitmap: raw.baseAddress!, rowBytes: rowBytes,
                           bounds: CGRect(x: 0, y: y, width: w, height: rows),
                           format: .RGBA8, colorSpace: out)
            }
            for i in 0..<(rows * w * 4) {
                let v = Double(buf[i])
                let c = i % 4
                if v < minv[c] { minv[c] = v; minLoc[c] = (0, 0) }
                if v > maxv[c] { maxv[c] = v }
            }
        }
        y += rows
    }
    _ = peak; _ = lower
    print("\(label): min=\(minv) at \(minLoc) max=\(maxv)")
}

let sdr = CGImageSourceCreateImageAtIndex(src, 0, nil)!
print("sdr cs=\(sdr.colorSpace?.name as Any) headroom=\(sdr.contentHeadroom) bps=\(sdr.bitsPerComponent) bpp=\(sdr.bitsPerPixel) bmi=\(sdr.bitmapInfo.rawValue) alpha=\(sdr.alphaInfo.rawValue)")

let linP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
statsCI(sdr, "plain->linP3 RGBAf", working: linP3, out: linP3, fmt: .RGBAf)
statsCI(sdr, "plain->P3 RGBA8", working: p3, out: p3, fmt: .RGBA8)
statsCI(sdr, "plain->p3working RGBA8", working: p3, out: p3, fmt: .RGBA8)

let toSDR: [CFString: Any] = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR]
if let s2 = CGImageSourceCreateImageAtIndex(src, 0, toSDR as CFDictionary) {
    print("DecodeToSDR bps=\(s2.bitsPerComponent) bpp=\(s2.bitsPerPixel) cs=\(s2.colorSpace?.name as Any) headroom=\(s2.contentHeadroom) calc=\(s2.calculatedContentHeadroom)")
    statsCI(s2, "toSDR->linP3", working: linP3, out: linP3, fmt: .RGBAf)
}
let noLuma: [CFString: Any] = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToSDR, kCGImageSourceGenerateImageSpecificLumaScaling: false]
if let s3 = CGImageSourceCreateImageAtIndex(src, 0, noLuma as CFDictionary) {
    print("DecodeToSDR(noLuma) bps=\(s3.bitsPerComponent) bpp=\(s3.bitsPerPixel) cs=\(s3.colorSpace?.name as Any) headroom=\(s3.contentHeadroom) calc=\(s3.calculatedContentHeadroom)")
    statsCI(s3, "toSDR(noLuma)->linP3", working: linP3, out: linP3, fmt: .RGBAf)
}
// CGContext path (no Core Image) to check raw values
if let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) {
    let w = sdr.width, h = sdr.height
    let rowBytes = w * 16
    var buf = [Float](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { raw in
        if let cg = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: rowBytes, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue) {
            cg.draw(sdr, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
    var maxv = [Float](repeating: -1, count: 4)
    for i in stride(from: 0, to: buf.count, by: 4) {
        for c in 0..<4 { if buf[i + c] > maxv[c] { maxv[c] = buf[i + c] } }
    }
    print("CGContext draw -> extLinP3 max=\(maxv)")
}
