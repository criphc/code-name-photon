import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let path = "/Users/criphc/Sites/llm-photon/work/m21-final/preview-base.png"
let data = try! Data(contentsOf: URL(fileURLWithPath: path))
let src = CGImageSourceCreateWithData(data as CFData, nil)!
print("count", CGImageSourceGetCount(src))
let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [String: Any]
print("props", props)
let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
print("bpc", cg.bitsPerComponent, "bpp", cg.bitsPerPixel, "alpha", cg.alphaInfo.rawValue, "cs", cg.colorSpace?.name as Any, "w", cg.width, "h", cg.height)
if let cs = cg.colorSpace {
    print("csname", cs.name as Any)
    print("icc", (cs.copyICCData() as Data?)?.count as Any)
}

// Convert to linear extended Display P3 Float32
let w = cg.width, h = cg.height
var buf = [Float](repeating: 0, count: w*h*4)
let srgb = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let ok: Bool = buf.withUnsafeMutableBytes { raw in
    guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w*16, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue) else { return false }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return true
}
print("ctx", ok)
// Also decode via CIContext RGBAf render
func px(_ x: Int, _ y: Int) -> (Float, Float, Float) {
    let i = (y*w + x)*4
    return (buf[i], buf[i+1], buf[i+2])
}
print("corner TL(0,0)", px(0,0))
print("corner TR(\(w-1),0)", px(w-1,0))
print("corner BL(0,\(h-1))", px(0,h-1))
print("center", px(w/2,h/2))
print("max", buf.max()!, "min", buf.min()!)
