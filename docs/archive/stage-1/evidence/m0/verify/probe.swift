import Foundation
import ImageIO
import CoreGraphics
import CoreImage

// scratch probe for ImageIO API behaviour (not part of the deliverable)

func s(_ v: CFString?) -> String { (v as String?) ?? "nil" }

func describeCGImage(_ img: CGImage, _ label: String) {
    print("\(label): \(img.width)x\(img.height) bps=\(img.bitsPerComponent) bpp=\(img.bitsPerPixel) cs=\(s(img.colorSpace?.name)) alpha=\(img.alphaInfo.rawValue) float=\(img.bitmapInfo.contains(.floatComponents)) headroom=\(img.contentHeadroom) calc=\(img.calculatedContentHeadroom) avg=\(img.contentAverageLightLevel)")
}

func ciStats(_ image: CIImage, _ label: String, cap: Double?) {
    let linP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    let ctx = CIContext(options: [.workingColorSpace: linP3, .outputColorSpace: linP3, .cacheIntermediates: false])
    let w = Int(image.extent.width.rounded())
    let h = Int(image.extent.height.rounded())
    let rowBytes = w * 16
    var peak: Float = -Float.greatestFiniteMagnitude
    var sum: Double = 0
    var count: Double = 0
    var above1: Double = 0
    var aboveCap: Double = 0
    var nanCount = 0
    let strip = 256
    var y = 0
    var buf = [Float](repeating: 0, count: rowBytes * strip / 4)
    while y < h {
        let rows = min(strip, h - y)
        buf.withUnsafeMutableBytes { raw in
            ctx.render(image,
                       toBitmap: raw.baseAddress!,
                       rowBytes: rowBytes,
                       bounds: CGRect(x: 0, y: y, width: w, height: rows),
                       format: .RGBAf,
                       colorSpace: linP3)
        }
        for i in 0..<(rows * w * 4) {
            if i % 4 == 3 { continue }
            let v = buf[i]
            if v.isNaN { nanCount += 1; continue }
            if v > peak { peak = v }
            sum += Double(v)
            count += 1
            if v > 1.0 { above1 += 1 }
            if let cap, v > Float(cap) { aboveCap += 1 }
        }
        y += rows
    }
    print("\(label): peak=\(peak) mean=\(sum / max(count, 1)) frac>1=\(above1 / max(count, 1)) frac>cap=\(aboveCap / max(count, 1)) nan=\(nanCount) ext=\(image.extent)")
}

func dumpValue(_ value: CFTypeRef, depth: Int, path: String) {
    let typeID = CFGetTypeID(value)
    if typeID == CGImageMetadataTagGetTypeID() {
        dumpTag(value as! CGImageMetadataTag, parent: path, depth: depth)
    } else if typeID == CFArrayGetTypeID() {
        let arr = value as! [AnyObject]
        print(String(repeating: "  ", count: depth) + "\(path) [array \(arr.count)]")
        for (i, item) in arr.enumerated().prefix(40) {
            dumpValue(item as CFTypeRef, depth: depth + 1, path: "\(path)[\(i)]")
        }
    } else if typeID == CFDictionaryGetTypeID() {
        let dict = value as! [AnyHashable: Any]
        print(String(repeating: "  ", count: depth) + "\(path) {dict \(dict.count)}")
        for (k, v) in dict.prefix(40) {
            dumpValue(v as CFTypeRef, depth: depth + 1, path: "\(path).\(k)")
        }
    } else if typeID == CFStringGetTypeID() {
        print(String(repeating: "  ", count: depth) + "\(path) = \(value as! String)")
    } else if typeID == CFBooleanGetTypeID() {
        print(String(repeating: "  ", count: depth) + "\(path) = \(CFBooleanGetValue(value as! CFBoolean))")
    } else if typeID == CFNumberGetTypeID() {
        var d = 0.0
        if CFNumberGetValue(value as! CFNumber, .doubleType, &d) {
            print(String(repeating: "  ", count: depth) + "\(path) = \(d)")
        }
    } else if typeID == CFDataGetTypeID() {
        let data = value as! Data
        print(String(repeating: "  ", count: depth) + "\(path) <data \(data.count) bytes> \(data.prefix(16).map { String(format: "%02x", $0) }.joined())")
    } else {
        print(String(repeating: "  ", count: depth) + "\(path) = <\(typeID)> \(CFCopyDescription(value) as String)")
    }
}

func dumpTag(_ tag: CGImageMetadataTag, parent: String, depth: Int) {
    let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
    let name = (CGImageMetadataTagCopyName(tag) as String?) ?? "?"
    let path = parent.isEmpty ? (prefix.isEmpty ? name : "\(prefix):\(name)") : "\(parent)/\(prefix.isEmpty ? name : "\(prefix):\(name)")"
    if let value = CGImageMetadataTagCopyValue(tag) {
        dumpValue(value, depth: depth, path: path)
    } else {
        print(String(repeating: "  ", count: depth) + "\(path) = <nil>")
    }
}

func dumpMetadata(_ mdAny: Any?, _ label: String) {
    guard let mdAny else { print("\(label): nil"); return }
    if CFGetTypeID(mdAny as AnyObject) == CGImageMetadataGetTypeID() {
        let md = mdAny as! CGImageMetadata
        guard let tags = CGImageMetadataCopyTags(md) as? [CGImageMetadataTag] else {
            print("\(label): no tags"); return
        }
        print("\(label): \(tags.count) top-level tags")
        for t in tags { dumpTag(t, parent: "", depth: 1) }
    } else {
        dumpValue(mdAny as AnyObject, depth: 1, path: label)
    }
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "work/lead-smoke/out/hdr.heic"
let url = URL(fileURLWithPath: path)
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { fatalError("no source") }
print("=== \(path)")
print("count=\(CGImageSourceGetCount(src)) type=\(s(CGImageSourceGetType(src))) primaryIndex=\(CGImageSourceGetPrimaryImageIndex(src))")

if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
    print("--- properties keys: \(props.keys.map { $0 as String }.sorted())")
    for k in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyColorModel, kCGImagePropertyProfileName, kCGImagePropertyIsFloat, kCGImagePropertyHasAlpha, kCGImagePropertyOrientation, kCGImagePropertyImageCount, kCGImagePropertyNamedColorSpace, kCGImagePropertyPixelFormat, kCGImagePropertyHEICSCanvasPixelWidth, kCGImagePropertyHEICSCanvasPixelHeight] {
        if let v = props[k] { print("  \(k as String) = \(v)") }
    }
    if let aux = props[kCGImagePropertyAuxiliaryData] {
        print("  auxData = \(aux)")
    }
    if let images = props[kCGImagePropertyImages] as? [[CFString: Any]] {
        print("  images count=\(images.count)")
        for (i, im) in images.enumerated() {
            print("    image[\(i)] keys=\(im.keys.map { $0 as String }.sorted())")
        }
    }
} else { print("no properties") }

func auxDump(_ type: CFString, _ label: String) {
    guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, type) as? [CFString: Any] else {
        print("--- aux \(label): nil"); return
    }
    print("--- aux \(label): keys=\(info.keys.map { $0 as String })")
    if let data = info[kCGImageAuxiliaryDataInfoData] as? Data {
        print("  data=\(data.count) bytes prefix=\(data.prefix(16).map { String(format: "%02x", $0) }.joined())")
    }
    if let desc = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any] {
        print("  desc=\(desc.map { "\($0.key as String)=\($0.value)" })")
    }
    if let cs = info[kCGImageAuxiliaryDataInfoColorSpace] {
        print("  cs=\(CFCopyDescription(cs as CFTypeRef) as String)")
        if CFGetTypeID(cs as AnyObject) == CGColorSpace.typeID {
            print("  cs.name=\(s((cs as! CGColorSpace).name))")
        }
    }
    dumpMetadata(info[kCGImageAuxiliaryDataInfoMetadata], "  metadata")
}
auxDump(kCGImageAuxiliaryDataTypeISOGainMap, "ISOGainMap")
auxDump(kCGImageAuxiliaryDataTypeHDRGainMap, "HDRGainMap")

if let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil) {
    dumpMetadata(md, "--- imageMetadata")
} else { print("--- imageMetadata: nil") }

if let sdr = CGImageSourceCreateImageAtIndex(src, 0, nil) {
    describeCGImage(sdr, "SDR decode")
    ciStats(CIImage(cgImage: sdr), "SDR ciStats", cap: nil)
} else { print("SDR decode failed") }

var opts: [CFString: Any] = [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR]
if let hdr = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) {
    describeCGImage(hdr, "HDR decode")
    ciStats(CIImage(cgImage: hdr), "HDR ciStats (plain init)", cap: nil)
    ciStats(CIImage(cgImage: hdr, options: [.expandToHDR: true]), "HDR ciStats (expandToHDR)", cap: nil)
} else { print("HDR decode failed (default)") }

opts[kCGImageSourceGenerateImageSpecificLumaScaling] = false
if let hdr = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) {
    describeCGImage(hdr, "HDR decode (lumaScaling=false)")
    ciStats(CIImage(cgImage: hdr), "HDR ciStats (lumaScaling=false, plain init)", cap: nil)
    ciStats(CIImage(cgImage: hdr, options: [.expandToHDR: true]), "HDR ciStats (lumaScaling=false, expandToHDR)", cap: nil)
} else { print("HDR decode failed (lumaScaling=false)") }

if let img = CIImage(contentsOf: url, options: [.expandToHDR: true]) {
    print("CIImage(contentsOf, expandToHDR): ext=\(img.extent) cs=\(s(img.colorSpace?.name)) headroom=\(img.contentHeadroom)")
    ciStats(img, "CIImage(contentsOf) stats", cap: nil)
} else { print("CIImage(contentsOf, expandToHDR) nil") }
