import Foundation
import ImageIO
import CoreImage
import CoreGraphics
import UniformTypeIdentifiers

let url = URL(fileURLWithPath: "/Users/criphc/Sites/llm-photon/samples/sources/R0003777.tif")
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { fatalError("no src") }
let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
print("props:", props)
guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("no img") }
print("cg bits:", cg.bitsPerComponent, "bpp:", cg.bitsPerPixel, "cs:", cg.colorSpace?.name as Any, "model:", cg.colorSpace?.model.rawValue as Any)
if let cs = cg.colorSpace {
    print("cs desc:", cs.name as Any, cs.numberOfComponents)
}

let ci = CIImage(contentsOf: url, options: [.expandToHDR: true])!
print("ci extent:", ci.extent, "cs:", ci.colorSpace as Any, "props keys:", ci.properties.keys.sorted())

let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let ctx = CIContext(options: [.workingColorSpace: linearP3, .outputColorSpace: linearP3, .cacheIntermediates: false])
// render 1x1 at origin
func sample(_ x: CGFloat, _ y: CGFloat) -> [Float] {
    var px = [Float](repeating: 0, count: 4)
    ctx.render(ci, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: linearP3)
    return px
}
for (x,y) in [(0,0),(100,100),(3000,2000),(5999,3999)] {
    print("ci px", x, y, sample(CGFloat(x), CGFloat(y)))
}

// direct 16-bit pixel read from CGImage for comparison
if let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) {
    let stride = cg.bytesPerRow
    func raw(_ x: Int, _ y: Int) -> [UInt16] {
        let off = y*stride + x*6
        return [UInt16(p[off])<<8 | UInt16(p[off+1]), UInt16(p[off+2])<<8 | UInt16(p[off+3]), UInt16(p[off+4])<<8 | UInt16(p[off+5])]
    }
    for (x,y) in [(0,0),(100,100),(3000,2000),(5999,3999)] {
        print("raw16", x, y, raw(x,y))
    }
}

// write float TIFF test
let hdrURL = URL(fileURLWithPath: "/Users/criphc/Sites/llm-photon/work/probe/hdr_test.tif")
let testCI = CIImage(color: CIColor(red: 0.5, green: 0.25, blue: 4.0, alpha: 1.0)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
do {
    try ctx.writeTIFFRepresentation(of: testCI, to: hdrURL, format: .RGBAf, colorSpace: linearP3, options: [:])
    print("wrote float tif")
} catch { print("writeTIFF err:", error) }
if let s2 = CGImageSourceCreateWithURL(hdrURL as CFURL, nil),
   let p2 = CGImageSourceCopyPropertiesAtIndex(s2, 0, nil) as? [CFString: Any] {
    print("hdr tif props:", p2)
}
if let back = CIImage(contentsOf: hdrURL, options: [.expandToHDR: true]) {
    print("readback extent", back.extent, "cs", back.colorSpace as Any)
    var px = [Float](repeating: 0, count: 4)
    ctx.render(back, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linearP3)
    print("readback px:", px)
}
