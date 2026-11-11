import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

func lin(_ v: Double) -> Double { v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055, 2.4) }
// synthetic 1x1 mid-grey P3 encoded 0.5
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let val = UInt16(0.5*65535)
var px = [UInt16](repeating: val, count: 4)
px[3] = 65535
let img: CGImage = px.withUnsafeMutableBytes { raw in
    let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 16, bytesPerRow: 8, space: p3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    return ctx.makeImage()!
}
let url = URL(fileURLWithPath: "mid.png")
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil); _ = CGImageDestinationFinalize(dest)
let data = try! Data(contentsOf: url)
let src = CGImageSourceCreateWithData(data as CFData, nil)!
let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
var buf = [Float](repeating: -1, count: 4)
let linSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
buf.withUnsafeMutableBytes { raw in
    let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 32, bytesPerRow: 16, space: linSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
}
print("decoded linear", buf[0], "sRGB EOTF(0.5)=", lin(0.5), "diff", abs(Double(buf[0]) - lin(0.5)))
