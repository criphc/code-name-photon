import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// Build a 4x4 16-bit Display P3 image: top two rows pure red (encoded), bottom two rows pure green.
let w = 4, h = 4
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
var rgba16 = [UInt16](repeating: 0, count: w*h*4)
for y in 0..<h {
    for x in 0..<w {
        let i = (y*w + x)*4
        if y < 2 { rgba16[i] = 65535; rgba16[i+1] = 0; rgba16[i+2] = 0 }     // red top
        else { rgba16[i] = 0; rgba16[i+1] = 65535; rgba16[i+2] = 0 }          // green bottom
        rgba16[i+3] = 65535
    }
}
let cgSrc: CGImage = rgba16.withUnsafeMutableBytes { raw -> CGImage in
    let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w*8, space: p3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return ctx.makeImage()!
}
// write PNG 16-bit P3
let url = URL(fileURLWithPath: "synthetic16p3.png")
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, cgSrc, nil)
print("write", CGImageDestinationFinalize(dest))
// read back
let data = try! Data(contentsOf: url)
let src = CGImageSourceCreateWithData(data as CFData, nil)!
let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
print("read bpc", cg.bitsPerComponent, "bpp", cg.bitsPerPixel, "alpha", cg.alphaInfo.rawValue, "cs", cg.colorSpace?.name as Any)

// CGContext draw to linear float
let lin = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
var buf = [Float](repeating: -1, count: w*h*4)
buf.withUnsafeMutableBytes { raw in
    let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w*16, space: lin, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
}
for y in 0..<h {
    let i = (y*w + 0)*4
    print("row", y, String(format: "%.4f %.4f %.4f a=%.2f", buf[i], buf[i+1], buf[i+2], buf[i+3]))
}
