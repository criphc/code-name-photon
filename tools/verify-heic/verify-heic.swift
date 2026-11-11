#!/usr/bin/env swift
//
//  verify-heic.swift — objective verifier for gain-map HEIC files.
//
//  Single-file Swift CLI (build with ./build.sh, no SwiftPM). It asserts the
//  container / ImageIO facts that matter for an Apple-delivered gain-map HEIC
//  and emits a deterministic JSON report. It never uses `sips` (sips silently
//  strips gain maps — see docs/reference/container.md).
//
//  Usage:
//    verify-heic <file.heic> [--base <sdr.tif>] [--expect-headroom <linear-float>]
//                [--expect-bit-depth <8|10>] [--expect-map-resolution <half|full>]
//                [--expect-orientation <int>] [--out <report.json>]
//
//  Exit codes: 0 = overall pass, 1 = any failure (including usage/IO errors).
//
//  M4 folds this logic into PhotonCore; keep the report schema stable.
//

import Foundation
import ImageIO
import CoreGraphics
import CoreImage
import CryptoKit

let toolName = "verify-heic"
let toolVersion = "0.1.0"

// MARK: - CLI

struct Options {
    var input = ""
    var base: String?
    var expectHeadroom: Double?
    var expectBitDepth: Int?
    var expectMapResolution: String?
    var expectOrientation: Int?
    var out: String?
}

func printUsage() {
    let usage = """
    usage: \(toolName) <file.heic> [--base <sdr.tif>] [--expect-headroom <linear-float>]
           [--expect-bit-depth <8|10>] [--expect-map-resolution <half|full>]
           [--expect-orientation <int>] [--out <report.json>]

    Objective ImageIO verifier for gain-map HEIC files (ISO 21496-1 / Apple legacy).
    Never uses sips. Exit 0 iff every applicable check passes, else 1.

    options:
      --base <path>              SDR base (TIFF or any ImageIO-readable image) to compare against
      --expect-headroom <float>  expected linear headroom (e.g. 2.5); adds the headroomWithin5pct check
      --expect-bit-depth <8|10>  require properties.depth to equal this (default: 8 or 10)
      --expect-map-resolution <half|full>
                                 require the ISO gain map to be half or full resolution
      --expect-orientation <int> require the EXIF/TIFF orientation tag to equal this
      --out <path>               write the JSON report here
      -h, --help                 show this help
      --version                  show the version
    """
    print(usage)
}

func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(("\(toolName): error: \(message)\n").data(using: .utf8)!)
    printUsage()
    exit(1)
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments
    args.removeFirst()
    var index = 0
    var sawInput = false
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "-h", "--help":
            printUsage()
            exit(0)
        case "--version":
            print("\(toolName) \(toolVersion)")
            exit(0)
        case "--base":
            guard index + 1 < args.count else { usageError("--base requires a value") }
            options.base = args[index + 1]
            index += 2
        case "--expect-headroom":
            guard index + 1 < args.count else { usageError("--expect-headroom requires a value") }
            guard let value = Double(args[index + 1]), value.isFinite, value > 0 else {
                usageError("--expect-headroom must be a positive finite linear float (e.g. 2.5)")
            }
            options.expectHeadroom = value
            index += 2
        case "--expect-bit-depth":
            guard index + 1 < args.count else { usageError("--expect-bit-depth requires a value") }
            guard let value = Int(args[index + 1]), value == 8 || value == 10 else {
                usageError("--expect-bit-depth must be 8 or 10")
            }
            options.expectBitDepth = value
            index += 2
        case "--expect-map-resolution":
            guard index + 1 < args.count else { usageError("--expect-map-resolution requires a value") }
            let value = args[index + 1]
            guard value == "half" || value == "full" else {
                usageError("--expect-map-resolution must be half or full")
            }
            options.expectMapResolution = value
            index += 2
        case "--expect-orientation":
            guard index + 1 < args.count else { usageError("--expect-orientation requires a value") }
            guard let value = Int(args[index + 1]) else {
                usageError("--expect-orientation must be an integer (EXIF orientation 1-8)")
            }
            options.expectOrientation = value
            index += 2
        case "--out":
            guard index + 1 < args.count else { usageError("--out requires a value") }
            options.out = args[index + 1]
            index += 2
        default:
            if arg.hasPrefix("--") {
                usageError("unknown option \(arg)")
            }
            if sawInput {
                usageError("unexpected argument \(arg) (only one input file is accepted)")
            }
            options.input = arg
            sawInput = true
            index += 1
        }
    }
    if !sawInput { usageError("missing input file") }
    return options
}

// MARK: - Small helpers

func n(_ value: CFString?) -> String? { value as String? }

func asInt(_ value: Any?) -> Int? {
    if let intValue = value as? Int { return intValue }
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) }
    return nil
}

func asDouble(_ value: Any?) -> Double? {
    if let doubleValue = value as? Double { return doubleValue }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

func asBool(_ value: Any?) -> Bool? {
    if let boolValue = value as? Bool { return boolValue }
    if let number = value as? NSNumber { return number.boolValue }
    return nil
}

func asString(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    return nil
}

func be16(_ bytes: [UInt8], _ offset: Int) -> Int {
    Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
}

func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
}

func be64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<8 { value = (value << 8) | UInt64(bytes[offset + i]) }
    return value
}

func fourCC(_ bytes: [UInt8], _ offset: Int) -> String {
    var text = ""
    for i in 0..<4 {
        let scalar = UnicodeScalar(bytes[offset + i])
        text.append(Character(scalar))
    }
    return text
}

func cString(_ bytes: [UInt8], _ offset: Int, _ end: Int) -> String {
    var data: [UInt8] = []
    var cursor = offset
    while cursor < end && bytes[cursor] != 0 {
        data.append(bytes[cursor])
        cursor += 1
    }
    return String(bytes: data, encoding: .utf8) ?? ""
}

func hexPrefix(_ data: Data, _ count: Int = 16) -> String {
    data.prefix(count).map { String(format: "%02x", $0) }.joined()
}

func formatDouble(_ value: Double, _ decimals: Int = 6) -> String {
    guard value.isFinite else { return "\(value)" }
    return String(format: "%.\(decimals)f", value)
}

/// Replace non-finite numbers with NSNull so JSONSerialization never throws.
func jsonSafe(_ value: Any) -> Any {
    switch value {
    case let boolValue as Bool:
        return boolValue
    case let doubleValue as Double:
        return doubleValue.isFinite ? doubleValue : NSNull()
    case let floatValue as Float:
        return floatValue.isFinite ? Double(floatValue) : NSNull()
    case let array as [Any]:
        return array.map(jsonSafe)
    case let dictionary as [String: Any]:
        var out: [String: Any] = [:]
        for (key, item) in dictionary { out[key] = jsonSafe(item) }
        return out
    case let number as NSNumber:
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        let doubleValue = number.doubleValue
        return doubleValue.isFinite ? number : NSNull()
    default:
        return value
    }
}

// MARK: - ISO BMFF container parsing (ftyp / meta / iinf / infe / pitm)

struct BoxInfo {
    let type: String
    let offset: Int
    let size: Int
    let headerSize: Int
}

func parseBoxes(_ bytes: [UInt8], start: Int, end: Int) -> [BoxInfo] {
    var boxes: [BoxInfo] = []
    var offset = start
    while offset + 8 <= end {
        let size32 = be32(bytes, offset)
        let type = fourCC(bytes, offset + 4)
        var size = Int(size32)
        var headerSize = 8
        if size32 == 1 {
            guard offset + 16 <= end else { break }
            size = Int(be64(bytes, offset + 8))
            headerSize = 16
            guard size >= headerSize else { break }
        } else if size32 == 0 {
            size = end - offset
        }
        guard size >= headerSize, offset + size <= end else { break }
        boxes.append(BoxInfo(type: type, offset: offset, size: size, headerSize: headerSize))
        offset += size
    }
    return boxes
}

func parseFTYP(_ bytes: [UInt8], _ box: BoxInfo) -> [String: Any] {
    let payload = box.offset + box.headerSize
    let end = box.offset + box.size
    guard payload + 8 <= end else { return ["error": "truncated ftyp"] }
    let major = fourCC(bytes, payload)
    let minor = be32(bytes, payload + 4)
    var brands: [String] = []
    var cursor = payload + 8
    while cursor + 4 <= end {
        brands.append(fourCC(bytes, cursor))
        cursor += 4
    }
    return [
        "majorBrand": major,
        "minorVersion": Int(minor),
        "compatibleBrands": brands,
    ]
}

func parseIINF(_ bytes: [UInt8], _ box: BoxInfo) -> (entryCount: Int?, items: [[String: Any]], error: String?) {
    let payload = box.offset + box.headerSize
    let end = box.offset + box.size
    guard payload + 4 <= end else { return (nil, [], "truncated iinf header") }
    let version = Int(bytes[payload])
    var cursor = payload + 4
    var entryCount: Int?
    if version == 0 {
        guard cursor + 2 <= end else { return (nil, [], "truncated iinf entry_count") }
        entryCount = be16(bytes, cursor)
        cursor += 2
    } else {
        guard cursor + 4 <= end else { return (nil, [], "truncated iinf entry_count") }
        entryCount = Int(be32(bytes, cursor))
        cursor += 4
    }
    let children = parseBoxes(bytes, start: cursor, end: end)
    var items: [[String: Any]] = []
    for child in children where child.type == "infe" {
        let childPayload = child.offset + child.headerSize
        let childEnd = child.offset + child.size
        guard childPayload + 4 <= childEnd else { continue }
        let infeVersion = Int(bytes[childPayload])
        var p = childPayload + 4
        var itemID: Int?
        var itemType: String?
        if infeVersion < 2 {
            // version 0/1: item_ID(16) + item_protection_index(16) + name/content strings
            guard p + 4 <= childEnd else { continue }
            itemID = be16(bytes, p)
            p += 2
            itemType = cString(bytes, p + 2, childEnd)
        } else if infeVersion == 2 {
            // version 2: item_ID(16) + item_protection_index(16) + item_type(32) + item_name
            guard p + 8 <= childEnd else { continue }
            itemID = be16(bytes, p)
            p += 4
            itemType = fourCC(bytes, p)
            p += 4
        } else {
            // version 3: item_ID(32) + item_protection_index(16) + item_type(32) + item_name
            guard p + 10 <= childEnd else { continue }
            itemID = Int(be32(bytes, p))
            p += 6
            itemType = fourCC(bytes, p)
            p += 4
        }
        var item: [String: Any] = [:]
        if let itemID { item["itemID"] = itemID }
        if let itemType, !itemType.isEmpty { item["itemType"] = itemType }
        items.append(item)
    }
    return (entryCount, items, nil)
}

func parsePITM(_ bytes: [UInt8], _ box: BoxInfo) -> Int? {
    let payload = box.offset + box.headerSize
    let end = box.offset + box.size
    guard payload + 4 <= end else { return nil }
    let version = Int(bytes[payload])
    if version == 0 {
        guard payload + 6 <= end else { return nil }
        return be16(bytes, payload + 4)
    }
    guard payload + 8 <= end else { return nil }
    return Int(be32(bytes, payload + 4))
}

func containerReport(bytes: [UInt8]) -> [String: Any] {
    var report: [String: Any] = [:]
    let topLevel = parseBoxes(bytes, start: 0, end: bytes.count)
    let ftypBox = topLevel.first { $0.type == "ftyp" }
    report["isISOBaseMedia"] = ftypBox != nil
    if let ftypBox {
        report["ftyp"] = parseFTYP(bytes, ftypBox)
    } else {
        report["ftyp"] = NSNull()
    }
    report["topLevelBoxes"] = topLevel.prefix(32).map { ["type": $0.type, "size": $0.size] }
    report["topLevelBoxCount"] = topLevel.count
    let heifBrands: Set<String> = ["heic", "heix", "hevc", "heim", "heis", "hevm", "hevs", "mif1", "msf1"]
    var isHEIF = false
    if let ftyp = report["ftyp"] as? [String: Any] {
        let major = (ftyp["majorBrand"] as? String) ?? ""
        let compatible = (ftyp["compatibleBrands"] as? [String]) ?? []
        isHEIF = heifBrands.contains(major) || compatible.contains(where: { heifBrands.contains($0) })
    }
    report["inputIsHEIF"] = isHEIF

    var itemCount: Int?
    var primaryItemID: Int?
    var items: [[String: Any]] = []
    var metaError: String?

    if let metaBox = topLevel.first(where: { $0.type == "meta" }) {
        let payload = metaBox.offset + metaBox.headerSize
        let end = metaBox.offset + metaBox.size
        guard payload + 4 <= end else {
            metaError = "truncated meta box"
            report["itemCount"] = NSNull()
            report["primaryItemID"] = NSNull()
            report["items"] = []
            report["itemTypeCounts"] = [:]
            report["tmapItemPresent"] = false
            return report
        }
        let children = parseBoxes(bytes, start: payload + 4, end: end)
        if let iinfBox = children.first(where: { $0.type == "iinf" }) {
            let parsed = parseIINF(bytes, iinfBox)
            if let error = parsed.error { metaError = error }
            if let count = parsed.entryCount { itemCount = count }
            else if !parsed.items.isEmpty { itemCount = parsed.items.count }
            items = parsed.items
        } else {
            metaError = "meta box has no iinf item info box"
        }
        if let pitmBox = children.first(where: { $0.type == "pitm" }) {
            primaryItemID = parsePITM(bytes, pitmBox)
        }
        report["metaChildTypes"] = children.map { $0.type }
    } else {
        metaError = "no top-level meta box (not an ISO BMFF image container?)"
    }

    report["itemCount"] = itemCount.map { $0 } ?? NSNull()
    report["infeCount"] = items.count
    if let declared = itemCount, declared != items.count {
        report["itemCountMismatch"] = true
        report["itemCountNote"] = "iinf entry_count=\(declared) but \(items.count) infe entries were parsed"
    }
    if let metaError { report["itemCountError"] = metaError }
    report["primaryItemID"] = primaryItemID.map { $0 } ?? NSNull()
    report["items"] = items

    var typeCounts: [String: Int] = [:]
    for item in items {
        let type = (item["itemType"] as? String) ?? "(none)"
        typeCounts[type, default: 0] += 1
    }
    report["itemTypeCounts"] = typeCounts
    report["tmapItemPresent"] = typeCounts.keys.contains("tmap")
    if let ftyp = report["ftyp"] as? [String: Any],
       let brands = ftyp["compatibleBrands"] as? [String] {
        report["tmapBrandPresent"] = brands.contains("tmap")
    } else {
        report["tmapBrandPresent"] = false
    }
    return report
}

// MARK: - CGImageMetadata -> JSON (generic recursive tag walk)

func jsonScalar(_ value: CFTypeRef) -> Any {
    let typeID = CFGetTypeID(value as AnyObject)
    if typeID == CFStringGetTypeID() { return value as! String }
    if typeID == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) }
    if typeID == CFNumberGetTypeID() {
        if CFNumberIsFloatType((value as! CFNumber)) {
            var doubleValue = 0.0
            CFNumberGetValue((value as! CFNumber), .doubleType, &doubleValue)
            return doubleValue
        }
        var intValue: Int64 = 0
        CFNumberGetValue((value as! CFNumber), .sInt64Type, &intValue)
        return Int(intValue)
    }
    if typeID == CFDataGetTypeID() {
        let data = value as! Data
        return ["kind": "data", "byteCount": data.count, "hexPrefix": hexPrefix(data)]
    }
    if typeID == CFURLGetTypeID() { return (value as! CFURL) as URL }
    return CFCopyDescription(value) as String
}

struct MetadataWalk {
    var tagLeaves: [[String: Any]] = []
    var totalTags = 0
    var truncated = false
    var maxLeaves = 500
    var maxDepth = 16
    var maxArrayItems = 64

    mutating func walk(_ metadata: CGImageMetadata) {
        guard let topTags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return }
        for tag in topTags {
            addTag(tag, parentPath: nil, depth: 1)
            if truncated { break }
        }
    }

    private mutating func appendLeaf(_ leaf: [String: Any]) {
        if tagLeaves.count >= maxLeaves {
            truncated = true
            return
        }
        tagLeaves.append(leaf)
    }

    mutating func addTag(_ tag: CGImageMetadataTag, parentPath: String?, depth: Int) {
        totalTags += 1
        guard depth <= maxDepth else { truncated = true; return }
        let namespace = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? ""
        let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
        let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
        let component = prefix.isEmpty ? name : "\(prefix):\(name)"
        let path = parentPath.map { "\($0)/\(component)" } ?? component
        var leaf: [String: Any] = [
            "path": path,
            "namespace": namespace,
            "name": name,
        ]
        if !prefix.isEmpty { leaf["prefix"] = prefix }

        guard let value = CGImageMetadataTagCopyValue(tag) else {
            leaf["kind"] = "nil"
            appendLeaf(leaf)
            return
        }
        let typeID = CFGetTypeID(value as AnyObject)
        if typeID == CGImageMetadataTagGetTypeID() {
            addTag(value as! CGImageMetadataTag, parentPath: path, depth: depth + 1)
        } else if typeID == CFArrayGetTypeID() {
            let array = value as! [AnyObject]
            leaf["kind"] = "array"
            leaf["count"] = array.count
            appendLeaf(leaf)
            for (index, item) in array.enumerated() {
                if index >= maxArrayItems { truncated = true; break }
                addValue(item, path: "\(path)[\(index)]", depth: depth + 1)
            }
        } else if typeID == CFDictionaryGetTypeID() {
            let dictionary = value as! [AnyHashable: Any]
            leaf["kind"] = "dictionary"
            leaf["count"] = dictionary.count
            appendLeaf(leaf)
            for (key, item) in dictionary {
                addValue(item as AnyObject, path: "\(path).\(key)", depth: depth + 1)
            }
        } else {
            leaf["kind"] = "scalar"
            leaf["value"] = jsonScalar(value)
            appendLeaf(leaf)
        }
    }

    mutating func addValue(_ value: AnyObject, path: String, depth: Int) {
        guard depth <= maxDepth else { truncated = true; return }
        let typeID = CFGetTypeID(value)
        if typeID == CGImageMetadataTagGetTypeID() {
            addTag(value as! CGImageMetadataTag, parentPath: path, depth: depth)
        } else if typeID == CFArrayGetTypeID() {
            let array = value as! [AnyObject]
            appendLeaf(["path": path, "kind": "array", "count": array.count])
            for (index, item) in array.enumerated() {
                if index >= maxArrayItems { truncated = true; break }
                addValue(item, path: "\(path)[\(index)]", depth: depth + 1)
            }
        } else if typeID == CFDictionaryGetTypeID() {
            let dictionary = value as! [AnyHashable: Any]
            appendLeaf(["path": path, "kind": "dictionary", "count": dictionary.count])
            for (key, item) in dictionary {
                addValue(item as AnyObject, path: "\(path).\(key)", depth: depth + 1)
            }
        } else {
            appendLeaf(["path": path, "kind": "scalar", "value": jsonScalar(value)])
        }
    }
}

func metadataReport(_ value: Any?, summarizeGainMap: Bool = true) -> [String: Any] {
    guard let value else { return ["present": false] }
    if CFGetTypeID(value as AnyObject) == CGImageMetadataGetTypeID() {
        let metadata = value as! CGImageMetadata
        var walker = MetadataWalk()
        walker.walk(metadata)
        var report: [String: Any] = [
            "present": true,
            "kind": "CGImageMetadata",
            "totalTags": walker.totalTags,
            "truncated": walker.truncated,
        ]
        report["tags"] = walker.tagLeaves
        if summarizeGainMap {
            report["gainMap"] = gainMapSummary(walker.tagLeaves)
        } else {
            report["headroomTags"] = walker.tagLeaves.filter { leaf in
                let name = (leaf["name"] as? String) ?? ""
                let path = (leaf["path"] as? String) ?? ""
                return name.localizedCaseInsensitiveContains("headroom")
                    || path.localizedCaseInsensitiveContains("gainmap")
                    || path.localizedCaseInsensitiveContains("tonemap")
            }
        }
        return report
    }
    // Some formats hand back a plain dictionary instead of CGImageMetadata.
    if CFGetTypeID(value as AnyObject) == CFDictionaryGetTypeID() {
        var walker = MetadataWalk()
        walker.addValue(value as AnyObject, path: "metadata", depth: 1)
        var report: [String: Any] = [
            "present": true,
            "kind": "dictionary",
            "totalTags": walker.totalTags,
            "truncated": walker.truncated,
            "tags": walker.tagLeaves,
        ]
        if summarizeGainMap { report["gainMap"] = gainMapSummary(walker.tagLeaves) }
        return report
    }
    return ["present": true, "kind": "other", "description": CFCopyDescription(value as CFTypeRef) as String]
}

/// Pull the ISO 21496-1 headroom / per-channel gain-map parameters out of a
/// generic tag walk, without assuming a single fixed tag path.
func gainMapSummary(_ leaves: [[String: Any]]) -> [String: Any] {
    var topLevel: [String: Any] = [:]
    var channels: [Int: [String: Any]] = [:]
    for leaf in leaves {
        let name = (leaf["name"] as? String) ?? ""
        let path = (leaf["path"] as? String) ?? ""
        guard let value = leaf["value"], !(value is NSNull), name != "" else { continue }
        if let range = path.range(of: "ChannelMetadata[") {
            let tail = path[range.upperBound...]
            let digits = tail.prefix { $0.isNumber }
            if let index = Int(digits) {
                channels[index, default: [:]][name] = value
                continue
            }
        }
        topLevel[name] = value
    }
    var summary: [String: Any] = [:]
    for (key, value) in topLevel { summary[key] = value }
    if !channels.isEmpty {
        var channelArray: [[String: Any]] = []
        for index in channels.keys.sorted() { channelArray.append(channels[index]!) }
        summary["channels"] = channelArray
        let maxValues = channelArray.compactMap { asDouble($0["GainMapMax"]) }
        let minValues = channelArray.compactMap { asDouble($0["GainMapMin"]) }
        let gammaValues = channelArray.compactMap { asDouble($0["Gamma"]) }
        if let maxValue = maxValues.max() { summary["gainMapMax"] = maxValue }
        if let minValue = minValues.min() { summary["gainMapMin"] = minValue }
        if let gammaValue = gammaValues.first { summary["gamma"] = gammaValue }
        summary["channelCount"] = channelArray.count
    }
    if let alternate = asDouble(summary["AlternateHeadroom"]) {
        summary["alternateHeadroomLog2"] = alternate
        summary["alternateHeadroomLinear"] = pow(2.0, alternate)
    }
    if let base = asDouble(summary["BaseHeadroom"]) {
        summary["baseHeadroomLog2"] = base
        summary["baseHeadroomLinear"] = pow(2.0, base)
    }
    return summary
}

// MARK: - Auxiliary data report

func pixelFormatReport(_ raw: Int?) -> Any {
    guard let raw else { return NSNull() }
    let value = UInt32(bitPattern: Int32(raw))
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
    ]
    var fourCCString = ""
    for byte in bytes {
        if byte >= 0x20 && byte < 0x7F { fourCCString.append(Character(UnicodeScalar(byte)))
        } else { fourCCString.append("?") }
    }
    return [
        "raw": Int(value),
        "fourCC": fourCCString,
        "hex": String(format: "0x%08X", value),
    ]
}

func auxReport(_ source: CGImageSource, type: CFString, label: String) -> [String: Any] {
    var report: [String: Any] = ["label": label, "typeConstant": type as String]
    guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) as? [CFString: Any] else {
        report["present"] = false
        return report
    }
    report["present"] = true
    report["infoKeys"] = info.keys.map { $0 as String }.sorted()

    if let data = info[kCGImageAuxiliaryDataInfoData] as? Data {
        report["dataBytes"] = data.count
        report["dataPrefixHex"] = hexPrefix(data, 16)
    } else {
        // Known ImageIO quirk: metadata keys can be returned while the raw data
        // key is omitted (e.g. "Unsupported AuxiliaryData format '420f'").
        report["dataBytes"] = NSNull()
        report["dataOmittedByImageIO"] = true
    }

    if let description = info[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any] {
        var plain: [String: Any] = [:]
        for (key, value) in description { plain[key as String] = jsonSafe(value) }
        report["dataDescription"] = plain
        report["pixelFormat"] = pixelFormatReport(asInt(plain[kCGImagePropertyPixelFormat as String]))
        if let width = asInt(plain[kCGImagePropertyWidth as String]) { report["auxWidth"] = width }
        if let height = asInt(plain[kCGImagePropertyHeight as String]) { report["auxHeight"] = height }
        if let rowBytes = asInt(plain[kCGImagePropertyBytesPerRow as String]) { report["auxBytesPerRow"] = rowBytes }
    } else {
        report["dataDescription"] = NSNull()
    }

    if let colorSpace = info[kCGImageAuxiliaryDataInfoColorSpace] {
        var colorSpaceReport: [String: Any] = [:]
        let colorSpaceDescription = CFCopyDescription(colorSpace as CFTypeRef) as String
        colorSpaceReport["description"] = colorSpaceDescription
        if CFGetTypeID(colorSpace as AnyObject) == CGColorSpace.typeID {
            if let name = (colorSpace as! CGColorSpace).name { colorSpaceReport["name"] = name as String }
        }
        report["colorSpace"] = colorSpaceReport
    } else {
        report["colorSpace"] = NSNull()
    }

    if let metadata = info[kCGImageAuxiliaryDataInfoMetadata] {
        report["metadata"] = metadataReport(metadata)
    } else {
        report["metadata"] = ["present": false]
    }
    return report
}

/// Best numeric headroom advertised by an aux report, in linear units.
func auxLinearHeadroom(_ aux: [String: Any]) -> Double? {
    guard let metadata = aux["metadata"] as? [String: Any],
          let gainMap = metadata["gainMap"] as? [String: Any] else { return nil }
    if let linear = asDouble(gainMap["alternateHeadroomLinear"]), linear > 0 { return linear }
    // Apple HDRGainMap metadata stores the linear headroom directly.
    if let raw = asDouble(gainMap["HDRGainMapHeadroom"]), raw > 0 { return raw }
    return nil
}

// MARK: - CGImage description

func alphaInfoName(_ info: CGImageAlphaInfo) -> String {
    switch info {
    case .none: return "none"
    case .premultipliedLast: return "premultipliedLast"
    case .premultipliedFirst: return "premultipliedFirst"
    case .last: return "last"
    case .first: return "first"
    case .noneSkipLast: return "noneSkipLast"
    case .noneSkipFirst: return "noneSkipFirst"
    case .alphaOnly: return "alphaOnly"
    @unknown default: return "unknown(\(info.rawValue))"
    }
}

func hasAlpha(_ info: CGImageAlphaInfo) -> Bool {
    switch info {
    case .none, .noneSkipLast, .noneSkipFirst: return false
    default: return true
    }
}

func describeDecodedImage(_ image: CGImage?) -> [String: Any] {
    guard let image else { return ["decoded": false] }
    var report: [String: Any] = [
        "decoded": true,
        "width": image.width,
        "height": image.height,
        "bitsPerComponent": image.bitsPerComponent,
        "bitsPerPixel": image.bitsPerPixel,
        "colorSpaceName": image.colorSpace?.name as String? ?? NSNull(),
        "alphaInfo": alphaInfoName(image.alphaInfo),
        "alphaInfoRaw": image.alphaInfo.rawValue,
        "hasAlpha": hasAlpha(image.alphaInfo),
        "isFloat": image.bitmapInfo.contains(.floatComponents),
        "contentHeadroom": Double(image.contentHeadroom),
        "calculatedContentHeadroom": Double(image.calculatedContentHeadroom),
    ]
    if #available(macOS 26.0, *) {
        report["contentAverageLightLevel"] = Double(image.contentAverageLightLevel)
    }
    return report
}

// MARK: - Core Image rendering (HDR signal + base comparison)

let linearDisplayP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

func makeRenderContext() -> CIContext {
    CIContext(options: [
        .workingColorSpace: linearDisplayP3,
        .outputColorSpace: linearDisplayP3,
        .cacheIntermediates: false,
    ])
}

struct HDRSignal {
    var peak: Double = -.infinity
    var minValue: Double = .infinity
    var mean: Double = 0
    var sampleCount: Double = 0
    var fractionAboveOne: Double = 0
    var fractionAboveCap: Double? = nil
    var fractionAboveContentHeadroom: Double? = nil
    var nanCount: Int = 0
}

/// Render the image to linear extended Display P3 float and measure the HDR
/// signal. Strips keep peak memory bounded on full-resolution images.
func measureHDRSignal(_ image: CGImage, context: CIContext, cap: Double?,
                      contentHeadroom: Double) -> ([String: Any], HDRSignal) {
    let ciImage = CIImage(cgImage: image)
    let width = image.width
    let height = image.height
    let rowBytes = width * 16
    let stripRows = max(1, min(256, height))
    var buffer = [Float](repeating: 0, count: rowBytes * stripRows / MemoryLayout<Float>.size)
    var signal = HDRSignal()
    var aboveOne: Double = 0
    var aboveCap: Double = 0
    var aboveHeadroom: Double = 0
    let capValue = cap.flatMap { Float($0) }
    let headroomValue = contentHeadroom > 0 ? Float(contentHeadroom) : nil
    var y = 0
    while y < height {
        let rows = min(stripRows, height - y)
        buffer.withUnsafeMutableBytes { raw in
            context.render(ciImage,
                           toBitmap: raw.baseAddress!,
                           rowBytes: rowBytes,
                           bounds: CGRect(x: 0, y: y, width: width, height: rows),
                           format: .RGBAf,
                           colorSpace: linearDisplayP3)
        }
        for row in 0..<rows {
            let rowBase = row * width * 4
            for x in 0..<width {
                let base = rowBase + x * 4
                for channel in 0..<3 {
                    let value = buffer[base + channel]
                    if value.isNaN {
                        signal.nanCount += 1
                        continue
                    }
                    let doubleValue = Double(value)
                    if doubleValue > signal.peak { signal.peak = doubleValue }
                    if doubleValue < signal.minValue { signal.minValue = doubleValue }
                    signal.mean += doubleValue
                    signal.sampleCount += 1
                    if doubleValue > 1.0 { aboveOne += 1 }
                    if let capValue, value > capValue { aboveCap += 1 }
                    if let headroomValue, value > headroomValue { aboveHeadroom += 1 }
                }
            }
        }
        y += rows
    }
    if signal.sampleCount > 0 {
        signal.mean /= signal.sampleCount
        signal.fractionAboveOne = aboveOne / signal.sampleCount
        if cap != nil { signal.fractionAboveCap = aboveCap / signal.sampleCount }
        if headroomValue != nil { signal.fractionAboveContentHeadroom = aboveHeadroom / signal.sampleCount }
    }
    var report: [String: Any] = [
        "method": "CIContext.render -> RGBAf, extendedLinearDisplayP3, \(stripRows)-row strips",
        "renderWidth": width,
        "renderHeight": height,
        "pixelCount": width * height,
        "sampleCount": signal.sampleCount,
        "peak": signal.peak.isFinite ? signal.peak : NSNull(),
        "min": signal.minValue.isFinite ? signal.minValue : NSNull(),
        "mean": signal.mean,
        "fractionAboveOne": signal.fractionAboveOne,
        "nanCount": signal.nanCount,
    ]
    if let fraction = signal.fractionAboveCap {
        report["cap"] = cap ?? NSNull()
        report["fractionAboveCap"] = fraction
    } else {
        report["cap"] = NSNull()
        report["fractionAboveCap"] = NSNull()
    }
    if let fraction = signal.fractionAboveContentHeadroom {
        report["fractionAboveContentHeadroom"] = fraction
        report["contentHeadroomUsedAsCap"] = contentHeadroom
    }
    return (report, signal)
}

struct BaseComparison {
    var available = false
    var meanSignedDiff: Double = 0
    var absDiffP50 = 0
    var absDiffP90 = 0
    var absDiffP99 = 0
    var absDiffP99_9 = 0
    var absDiffMax = 0
    var reason: String?
    var baseWidth = 0
    var baseHeight = 0
    var dimsMatch = false
    var perChannel: [String: [String: Any]] = [:]
    var meanAbsDiff: Double = 0
    var maxAbsDiff: Int = 0
    var fractionNonZero: Double = 0
    var decodedBaseVariance: [String: Any] = [:]
    var baseVariance: [String: Any] = [:]
    var baseUniform = false
    var histogram: [String: Int] = [:]
    var alphaNote: String?
}

/// Render the HEIC SDR decode and the supplied base image to the same 8-bit
/// Display P3 bitmap with a CIContext and compare them pixel by pixel.
func compareBase(decoded: CGImage, baseImage: CGImage, context: CIContext) -> BaseComparison {
    var comparison = BaseComparison()
    comparison.available = true
    let width = decoded.width
    let height = decoded.height
    comparison.baseWidth = baseImage.width
    comparison.baseHeight = baseImage.height
    comparison.dimsMatch = (decoded.width == baseImage.width && decoded.height == baseImage.height)
    if !comparison.dimsMatch {
        comparison.available = false
        comparison.reason = "dimension mismatch: HEIC SDR decode \(width)x\(height) vs base \(baseImage.width)x\(baseImage.height)"
        return comparison
    }
    let decodedHasAlpha = hasAlpha(decoded.alphaInfo)
    let baseHasAlpha = hasAlpha(baseImage.alphaInfo)
    if decodedHasAlpha != baseHasAlpha {
        comparison.alphaNote = "alpha differs (HEIC SDR hasAlpha=\(decodedHasAlpha), base hasAlpha=\(baseHasAlpha)); alpha channel ignored in diff"
    }

    let ciDecoded = CIImage(cgImage: decoded)
    let ciBase = CIImage(cgImage: baseImage)
    let rowBytes = width * 4
    let stripRows = max(1, min(256, height))
    var decodedBuffer = [UInt8](repeating: 0, count: rowBytes * stripRows)
    var baseBuffer = [UInt8](repeating: 0, count: rowBytes * stripRows)

    var channelSums = [Double](repeating: 0, count: 3)
    var channelSignedSums = [Double](repeating: 0, count: 3)
    var channelMax = [Int](repeating: 0, count: 3)
    var channelNonZero = [Double](repeating: 0, count: 3)
    var decodedSums = [Double](repeating: 0, count: 3)
    var decodedSumSquares = [Double](repeating: 0, count: 3)
    var baseSums = [Double](repeating: 0, count: 3)
    var baseSumSquares = [Double](repeating: 0, count: 3)
    var histogram = ["0": 0, "1": 0, "2": 0, ">2": 0]
    var absDiffCounts = [Int](repeating: 0, count: 256)
    let channelNames = ["r", "g", "b"]

    var y = 0
    while y < height {
        let rows = min(stripRows, height - y)
        decodedBuffer.withUnsafeMutableBytes { raw in
            context.render(ciDecoded, toBitmap: raw.baseAddress!, rowBytes: rowBytes,
                           bounds: CGRect(x: 0, y: y, width: width, height: rows),
                           format: .RGBA8, colorSpace: displayP3)
        }
        baseBuffer.withUnsafeMutableBytes { raw in
            context.render(ciBase, toBitmap: raw.baseAddress!, rowBytes: rowBytes,
                           bounds: CGRect(x: 0, y: y, width: width, height: rows),
                           format: .RGBA8, colorSpace: displayP3)
        }
        for row in 0..<rows {
            for x in 0..<width {
                let base = (row * width + x) * 4
                for channel in 0..<3 {
                    let decodedValue = Int(decodedBuffer[base + channel])
                    let baseValue = Int(baseBuffer[base + channel])
                    let diff = abs(decodedValue - baseValue)
                    channelSums[channel] += Double(diff)
                    channelSignedSums[channel] += Double(decodedValue - baseValue)
                    if diff > channelMax[channel] { channelMax[channel] = diff }
                    if diff != 0 { channelNonZero[channel] += 1 }
                    decodedSums[channel] += Double(decodedValue)
                    decodedSumSquares[channel] += Double(decodedValue * decodedValue)
                    baseSums[channel] += Double(baseValue)
                    baseSumSquares[channel] += Double(baseValue * baseValue)
                    absDiffCounts[diff] += 1
                    switch diff {
                    case 0: histogram["0"]! += 1
                    case 1: histogram["1"]! += 1
                    case 2: histogram["2"]! += 1
                    default: histogram[">2"]! += 1
                    }
                }
            }
        }
        y += rows
    }

    let pixelCount = Double(width * height)
    var channelReports: [String: [String: Any]] = [:]
    var totalDiff: Double = 0
    var totalNonZero: Double = 0
    var overallMax = 0
    for channel in 0..<3 {
        totalDiff += channelSums[channel]
        totalNonZero += channelNonZero[channel]
        if channelMax[channel] > overallMax { overallMax = channelMax[channel] }
        channelReports[channelNames[channel]] = [
            "meanAbsDiff": channelSums[channel] / pixelCount,
            "meanSignedDiff": channelSignedSums[channel] / pixelCount,
            "maxAbsDiff": channelMax[channel],
            "fractionNonZero": channelNonZero[channel] / pixelCount,
        ]
    }
    let sampleCount = pixelCount * 3
    let decodedMean = decodedSums.reduce(0, +) / sampleCount
    let decodedSumSq = decodedSumSquares.reduce(0, +)
    let decodedVariance = decodedSumSq / sampleCount - decodedMean * decodedMean
    let baseMean = baseSums.reduce(0, +) / sampleCount
    let baseSumSq = baseSumSquares.reduce(0, +)
    let baseVariance = baseSumSq / sampleCount - baseMean * baseMean
    comparison.perChannel = channelReports
    comparison.meanAbsDiff = totalDiff / sampleCount
    comparison.meanSignedDiff = channelSignedSums.reduce(0, +) / sampleCount
    comparison.maxAbsDiff = overallMax
    comparison.fractionNonZero = totalNonZero / sampleCount
    comparison.histogram = histogram
    comparison.decodedBaseVariance = [
        "overall": decodedVariance,
        "overallNormalized": decodedVariance / (255.0 * 255.0),
        "mean": decodedMean,
        "perChannel": [
            "r": decodedSumSquares[0] / pixelCount - pow(decodedSums[0] / pixelCount, 2),
            "g": decodedSumSquares[1] / pixelCount - pow(decodedSums[1] / pixelCount, 2),
            "b": decodedSumSquares[2] / pixelCount - pow(decodedSums[2] / pixelCount, 2),
        ],
    ]
    comparison.baseVariance = [
        "overall": baseVariance,
        "overallNormalized": baseVariance / (255.0 * 255.0),
        "mean": baseMean,
    ]
    comparison.baseUniform = (baseVariance == 0.0)
    // Distribution of per-sample absolute differences (LSB). Percentiles are
    // nearest-rank over all RGB samples; p99.9/max are diagnostics only.
    func percentile(_ percent: Double) -> Int {
        guard sampleCount > 0 else { return 0 }
        let rank = max(1, Int((percent / 100.0 * sampleCount).rounded(.up)))
        var cumulative = 0
        for (value, count) in absDiffCounts.enumerated() {
            cumulative += count
            if cumulative >= rank { return value }
        }
        return 255
    }
    comparison.absDiffP50 = percentile(50)
    comparison.absDiffP90 = percentile(90)
    comparison.absDiffP99 = percentile(99)
    comparison.absDiffP99_9 = percentile(99.9)
    comparison.absDiffMax = overallMax
    return comparison
}

/// Pass-rule thresholds for `basePreserved`, split by the character of the
/// supplied base. Uniform bases stay pixel-strict (the M0 synthetic assertion);
/// real photographs are judged by distribution because 8-bit 4:2:0 HEVC cannot
/// preserve per-pixel maxima at sharp coloured edges.
func baseThresholds(uniform: Bool) -> [String: Any] {
    if uniform {
        return [
            "baseMode": "uniform",
            "passRule": "meanAbsDiff == 0 && maxAbsDiff == 0 && decodedBaseVariance == 0",
            "meanAbsDiffMax": 0.0,
            "maxAbsDiffMax": 0,
            "decodedBaseVarianceMax": 0.0,
            "diagnosticsOnly": ["p99", "p99_9"],
        ]
    }
    return [
        "baseMode": "photo",
        "passRule": "|meanSignedDiff| <= 0.5 && meanAbsDiff <= 2.5 && absDiffP99 <= 16",
        "meanSignedDiffAbsMax": 0.5,
        "meanAbsDiffMax": 2.5,
        "absDiffP99Max": 16,
        "diagnosticsOnly": ["p99_9", "maxAbsDiff", "perChannel"],
    ]
}

func baseComparisonReport(_ comparison: BaseComparison, basePath: String,
                          baseSourceInfo: [String: Any], baseImage: CGImage?) -> [String: Any] {
    var report: [String: Any] = [
        "available": comparison.available,
        "basePath": basePath,
        "meanAbsDiff": comparison.meanAbsDiff,
        "meanSignedDiff": comparison.meanSignedDiff,
        "maxAbsDiff": comparison.maxAbsDiff,
        "fractionNonZero": comparison.fractionNonZero,
        "baseMode": comparison.baseUniform ? "uniform" : "photo",
        "baseThresholds": baseThresholds(uniform: comparison.baseUniform),
        "percentiles": [
            "p50": comparison.absDiffP50,
            "p90": comparison.absDiffP90,
            "p99": comparison.absDiffP99,
            "p99_9": comparison.absDiffP99_9,
            "max": comparison.absDiffMax,
        ],
        "perChannel": comparison.perChannel,
        "diffHistogram": comparison.histogram,
        "fractionAboveTwo": Double(comparison.histogram[">2"] ?? 0) / max(1.0, Double(comparison.histogram.values.reduce(0, +))),
        "decodedBaseVariance": comparison.decodedBaseVariance,
        "baseVariance": comparison.baseVariance,
        "baseUniform": comparison.baseUniform,
        "rendering": "both images rendered to 8-bit Display P3 (RGBA8) via CIContext",
    ]
    if !comparison.available {
        report["reason"] = comparison.reason ?? "unavailable"
        return report
    }
    report["baseWidth"] = comparison.baseWidth
    report["baseHeight"] = comparison.baseHeight
    report["dimsMatch"] = comparison.dimsMatch
    if let note = comparison.alphaNote { report["alphaNote"] = note }
    if let baseImage {
        report["baseImage"] = describeDecodedImage(baseImage)
    }
    if let sourceInfo = baseSourceInfo["properties"] as? [String: Any] {
        report["baseProperties"] = sourceInfo
    }
    return report
}

// MARK: - Primary image properties

func propertiesReport(_ properties: [CFString: Any]) -> [String: Any] {
    var report: [String: Any] = [:]
    if let width = asInt(properties[kCGImagePropertyPixelWidth]) { report["width"] = width }
    if let height = asInt(properties[kCGImagePropertyPixelHeight]) { report["height"] = height }
    if let depth = asInt(properties[kCGImagePropertyDepth]) { report["depth"] = depth }
    if let colorModel = properties[kCGImagePropertyColorModel] { report["colorModel"] = jsonSafe(colorModel) }
    if let profileName = properties[kCGImagePropertyProfileName] { report["profileName"] = jsonSafe(profileName) }
    if let isFloat = asBool(properties[kCGImagePropertyIsFloat]) { report["isFloat"] = isFloat }
    if let hasAlphaProperty = asBool(properties[kCGImagePropertyHasAlpha]) { report["hasAlphaProperty"] = hasAlphaProperty }
    if let orientation = asInt(properties[kCGImagePropertyOrientation]) { report["orientation"] = orientation }
    report["exifPresent"] = properties[kCGImagePropertyExifDictionary] != nil
    report["tiffPresent"] = properties[kCGImagePropertyTIFFDictionary] != nil
    if let imageCount = asInt(properties[kCGImagePropertyImageCount]) { report["imageCount"] = imageCount }
    if let colorSpaceName = properties[kCGImagePropertyNamedColorSpace] { report["namedColorSpace"] = jsonSafe(colorSpaceName) }
    if let pixelFormat = asInt(properties[kCGImagePropertyPixelFormat]) { report["pixelFormat"] = pixelFormat }
    if let canvasWidth = asInt(properties[kCGImagePropertyHEICSCanvasPixelWidth]) { report["heicsCanvasWidth"] = canvasWidth }
    if let canvasHeight = asInt(properties[kCGImagePropertyHEICSCanvasPixelHeight]) { report["heicsCanvasHeight"] = canvasHeight }
    if let auxiliaryData = properties[kCGImagePropertyAuxiliaryData] {
        report["propertyAuxiliaryData"] = jsonSafe(auxiliaryData)
    }
    if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
        if let orientation = asInt(tiff[kCGImagePropertyTIFFOrientation]) {
            if report["orientation"] == nil { report["orientation"] = orientation }
        }
    }
    return report
}

// MARK: - Main

func main() -> Never {
    let options = parseOptions()
    let inputURL = URL(fileURLWithPath: options.input)
    let inputAbsolutePath = inputURL.standardizedFileURL.path

    guard FileManager.default.fileExists(atPath: inputAbsolutePath) else {
        FileHandle.standardError.write("\(toolName): error: file not found: \(options.input)\n".data(using: .utf8)!)
        exit(1)
    }

    let data: Data
    do {
        data = try Data(contentsOf: inputURL, options: [.mappedIfSafe])
    } catch {
        FileHandle.standardError.write("\(toolName): error: cannot read \(options.input): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

    guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else {
        FileHandle.standardError.write("\(toolName): error: ImageIO cannot open \(options.input)\n".data(using: .utf8)!)
        exit(1)
    }
    let imageCount = CGImageSourceGetCount(source)
    let primaryIndex = CGImageSourceGetPrimaryImageIndex(source)

    var report: [String: Any] = [:]
    report["tool"] = [
        "name": toolName,
        "version": toolVersion,
        "generatedAt": ISO8601DateFormatter().string(from: Date()),
        "hostOS": ProcessInfo.processInfo.operatingSystemVersionString,
        "arguments": [
            "input": options.input,
            "base": options.base ?? NSNull(),
            "expectHeadroom": options.expectHeadroom ?? NSNull(),
            "expectBitDepth": options.expectBitDepth ?? NSNull(),
            "expectMapResolution": options.expectMapResolution ?? NSNull(),
            "expectOrientation": options.expectOrientation ?? NSNull(),
            "out": options.out ?? NSNull(),
        ] as [String: Any],
    ]
    report["file"] = [
        "path": options.input,
        "absolutePath": inputAbsolutePath,
        "sizeBytes": data.count,
        "sha256": sha256,
        "imageCount": imageCount,
        "primaryImageIndex": primaryIndex,
        "imageIOType": (CGImageSourceGetType(source) as String?) ?? NSNull(),
    ] as [String: Any]

    let bytes = [UInt8](data)
    report["container"] = containerReport(bytes: bytes)

    // --- primary / plain SDR decode
    let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    let propertiesSummary = propertiesReport(properties)
    report["properties"] = propertiesSummary

    let sdrImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    var sdrDecode = describeDecodedImage(sdrImage)
    // Baseline for HDR-signal interpretation: the same CI render of the plain
    // SDR decode. Saturated P3 colours can measure >1.0 here without any HDR
    // (ColorSync conversion overshoot), so M4 must compare HDR against this.
    if let sdrImage {
        let context = makeRenderContext()
        let (signal, _) = measureHDRSignal(sdrImage, context: context, cap: nil, contentHeadroom: 0)
        sdrDecode["measured"] = signal
    }
    report["sdrDecode"] = sdrDecode

    var primaryImage: [String: Any] = [:]
    for (key, value) in propertiesSummary { primaryImage[key] = value }
    if let sdrDecodeWidth = sdrDecode["width"] { primaryImage["decodedWidth"] = sdrDecodeWidth }
    if let sdrDecodeHeight = sdrDecode["height"] { primaryImage["decodedHeight"] = sdrDecodeHeight }
    if let sdrBps = sdrDecode["bitsPerComponent"] { primaryImage["bitsPerComponent"] = sdrBps }
    if let sdrBpp = sdrDecode["bitsPerPixel"] { primaryImage["bitsPerPixel"] = sdrBpp }
    if let sdrAlpha = sdrDecode["alphaInfo"] { primaryImage["alphaInfo"] = sdrAlpha }
    if let sdrAlphaRaw = sdrDecode["alphaInfoRaw"] { primaryImage["alphaInfoRaw"] = sdrAlphaRaw }
    if let sdrHasAlpha = sdrDecode["hasAlpha"] { primaryImage["hasAlpha"] = sdrHasAlpha }
    if let sdrIsFloat = sdrDecode["isFloat"] { primaryImage["isFloatDecoded"] = sdrIsFloat }
    // `isFloat` at primary-image level is the decoded truth (ImageIO omits the
    // kCGImagePropertyIsFloat property for many integer formats).
    primaryImage["isFloat"] = sdrDecode["isFloat"] ?? (propertiesSummary["isFloat"] ?? false)
    report["primaryImage"] = primaryImage

    // --- image-level metadata (XMP/EXIF-ish; also where Apple legacy headroom can live)
    var imageMetadataReport: [String: Any] = ["present": false]
    if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
        imageMetadataReport = metadataReport(metadata, summarizeGainMap: false)
    }
    report["imageMetadata"] = imageMetadataReport

    // --- auxiliary data
    let isoAux = auxReport(source, type: kCGImageAuxiliaryDataTypeISOGainMap, label: "isoGainMap")
    let hdrAux = auxReport(source, type: kCGImageAuxiliaryDataTypeHDRGainMap, label: "hdrGainMap")
    report["aux"] = [
        "isoGainMap": isoAux,
        "hdrGainMap": hdrAux,
        "isoAuxPresent": asBool(isoAux["present"]) ?? false,
        "hdrGainMapAuxPresent": asBool(hdrAux["present"]) ?? false,
        "isoAuxLinearHeadroom": auxLinearHeadroom(isoAux) ?? NSNull(),
        "hdrGainMapLinearHeadroom": auxLinearHeadroom(hdrAux) ?? NSNull(),
    ] as [String: Any]

    // --- HDR decode
    var hdrDecode: [String: Any] = [:]
    var hdrImage: CGImage?
    var hdrError: String?
    do {
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
        ]
        if let image = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions as CFDictionary) {
            hdrImage = image
        } else {
            let isoPresent = asBool(isoAux["present"]) ?? false
            let hdrAuxPresent = asBool(hdrAux["present"]) ?? false
            hdrError = "CGImageSourceCreateImageAtIndex returned nil with kCGImageSourceDecodeRequest=kCGImageSourceDecodeToHDR "
                + "(ImageIO exposes no NSError here; isoAux=\(isoPresent), hdrGainMapAux=\(hdrAuxPresent))"
        }
    }
    if let hdrImage {
        hdrDecode = describeDecodedImage(hdrImage)
        hdrDecode["success"] = true
        let looksHDR = hdrImage.bitsPerComponent > 8 || Double(hdrImage.contentHeadroom) > 1.0
        hdrDecode["isHDRContent"] = looksHDR
        hdrDecode["decodeOptions"] = ["kCGImageSourceDecodeRequest": "kCGImageSourceDecodeToHDR"]
        let context = makeRenderContext()
        let (signal, _) = measureHDRSignal(hdrImage, context: context, cap: options.expectHeadroom,
                                          contentHeadroom: Double(hdrImage.contentHeadroom))
        var signalReport = signal
        let sdrPeak = asDouble((sdrDecode["measured"] as? [String: Any])?["peak"])
        if let hdrPeak = asDouble(signalReport["peak"]), let sdrPeak, sdrPeak > 0 {
            signalReport["peakOverSdrPeak"] = hdrPeak / sdrPeak
        }
        hdrDecode["measured"] = signalReport
    } else {
        hdrDecode = ["success": false, "error": hdrError ?? "HDR decode failed"]
    }
    report["hdrDecode"] = hdrDecode

    // --- base comparison
    var baseCheck: [String: Any] = ["available": false, "reason": "no --base supplied"]
    var baseImage: CGImage?
    var baseComparison: BaseComparison?
    if let basePath = options.base {
        let baseURL = URL(fileURLWithPath: basePath)
        let baseAbsolutePath = baseURL.standardizedFileURL.path
        var baseSourceInfo: [String: Any] = ["path": basePath, "absolutePath": baseAbsolutePath]
        if FileManager.default.fileExists(atPath: baseAbsolutePath) {
            if let baseSource = CGImageSourceCreateWithURL(baseURL as CFURL, nil) {
                baseSourceInfo["imageIOType"] = (CGImageSourceGetType(baseSource) as String?) ?? NSNull()
                baseSourceInfo["imageCount"] = CGImageSourceGetCount(baseSource)
                if let baseProperties = CGImageSourceCopyPropertiesAtIndex(baseSource, 0, nil) as? [CFString: Any] {
                    baseSourceInfo["properties"] = propertiesReport(baseProperties)
                }
                baseImage = CGImageSourceCreateImageAtIndex(baseSource, 0, nil)
                if baseImage == nil {
                    baseCheck = ["available": false, "reason": "ImageIO could not decode base image \(basePath)",
                                 "basePath": basePath]
                }
            } else {
                baseCheck = ["available": false, "reason": "ImageIO could not open base image \(basePath)",
                             "basePath": basePath]
            }
        } else {
            baseCheck = ["available": false, "reason": "base file not found: \(basePath)", "basePath": basePath]
        }
        if let sdrImage, let baseImage {
            let context = makeRenderContext()
            let comparison = compareBase(decoded: sdrImage, baseImage: baseImage, context: context)
            baseComparison = comparison
            baseCheck = baseComparisonReport(comparison, basePath: basePath,
                                             baseSourceInfo: baseSourceInfo, baseImage: baseImage)
            baseCheck["baseSource"] = baseSourceInfo
        }
    }
    report["baseCheck"] = baseCheck

    // --- checks
    var checks: [String: [String: Any]] = [:]
    var failures: [String] = []
    var skipped: [String] = []

    let containerInfo = report["container"] as? [String: Any]
    let inputIsHEIF = asBool(containerInfo?["inputIsHEIF"]) ?? false
    checks["heifContainer"] = [
        "pass": inputIsHEIF,
        "detail": inputIsHEIF
            ? "ISO BMFF container with HEIF brand(s)"
            : "input is not a HEIF/ISO BMFF image (major brand \(asString(((containerInfo?["ftyp"] as? [String: Any])?["majorBrand"])) ?? "n/a")); verify-heic only certifies HEIC deliverables",
    ]

    let isoPresent = asBool(isoAux["present"]) ?? false
    let hdrAuxPresent = asBool(hdrAux["present"]) ?? false
    checks["isoAuxPresent"] = [
        "pass": isoPresent,
        "detail": isoPresent
            ? "kCGImageAuxiliaryDataTypeISOGainMap present"
            : "kCGImageAuxiliaryDataTypeISOGainMap absent (Apple legacy HDRGainMap present: \(hdrAuxPresent))",
    ]

    let sdrWidth = asInt(sdrDecode["width"]) ?? 0
    let sdrHeight = asInt(sdrDecode["height"]) ?? 0
    let expectedWidth: Int
    let expectedHeight: Int
    let dimsSource: String
    if let baseImage {
        expectedWidth = baseImage.width
        expectedHeight = baseImage.height
        dimsSource = "--base image"
    } else {
        expectedWidth = asInt(propertiesSummary["width"]) ?? 0
        expectedHeight = asInt(propertiesSummary["height"]) ?? 0
        dimsSource = "primary image properties"
    }
    let dimsMatch = sdrWidth > 0 && sdrHeight > 0 && sdrWidth == expectedWidth && sdrHeight == expectedHeight
    checks["dimsMatch"] = [
        "pass": dimsMatch,
        "detail": "HEIC SDR decode \(sdrWidth)x\(sdrHeight) vs \(dimsSource) \(expectedWidth)x\(expectedHeight)",
        "expectedWidth": expectedWidth,
        "expectedHeight": expectedHeight,
        "actualWidth": sdrWidth,
        "actualHeight": sdrHeight,
        "expectedSource": dimsSource,
    ]

    // --- explicit v2 assertions: base bit depth, gain-map resolution, orientation
    let baseDepth = asInt(propertiesSummary["depth"])
    let depthPass: Bool
    if let expectDepth = options.expectBitDepth {
        depthPass = baseDepth == expectDepth
    } else {
        depthPass = baseDepth == 8 || baseDepth == 10
    }
    let depthExpected = options.expectBitDepth.map { "\($0)" } ?? "8 or 10"
    checks["baseBitDepth"] = [
        "pass": depthPass,
        "detail": "properties.depth=\(baseDepth.map { "\($0)" } ?? "missing"); expected \(depthExpected)",
        "actualDepth": baseDepth.map { $0 as Any } ?? NSNull(),
        "expectedBitDepth": options.expectBitDepth.map { $0 as Any } ?? NSNull(),
        "allowedDepths": [8, 10],
    ]

    let isoAuxWidth = asInt(isoAux["auxWidth"])
    let isoAuxHeight = asInt(isoAux["auxHeight"])
    var mapResolution: String?
    if let isoAuxWidth, let isoAuxHeight, sdrWidth > 0, sdrHeight > 0 {
        if isoAuxWidth == sdrWidth && isoAuxHeight == sdrHeight {
            mapResolution = "full"
        } else if abs(isoAuxWidth * 2 - sdrWidth) <= 2 && abs(isoAuxHeight * 2 - sdrHeight) <= 2 {
            mapResolution = "half"
        }
    }
    let mapPass: Bool
    if let expectMap = options.expectMapResolution {
        mapPass = mapResolution == expectMap
    } else {
        mapPass = mapResolution != nil
    }
    let mapExpected = options.expectMapResolution ?? "half or full"
    let mapDetail: String
    if isoPresent {
        mapDetail = "ISO aux \(isoAuxWidth.map { "\($0)" } ?? "?")x\(isoAuxHeight.map { "\($0)" } ?? "?") "
            + "vs base \(sdrWidth)x\(sdrHeight) -> \(mapResolution ?? "neither half nor full"); expected \(mapExpected)"
    } else {
        mapDetail = "ISO gain-map aux absent; expected \(mapExpected)"
    }
    checks["gainMapResolution"] = [
        "pass": mapPass,
        "detail": mapDetail,
        "actualResolution": mapResolution ?? NSNull(),
        "expectedResolution": options.expectMapResolution ?? NSNull(),
        "auxWidth": isoAuxWidth.map { $0 as Any } ?? NSNull(),
        "auxHeight": isoAuxHeight.map { $0 as Any } ?? NSNull(),
        "baseWidth": sdrWidth,
        "baseHeight": sdrHeight,
        "halfTolerancePixels": 2,
    ]

    let exifPresent = asBool(propertiesSummary["exifPresent"]) ?? false
    let orientationValue = asInt(propertiesSummary["orientation"])
    var orientationPass = exifPresent && orientationValue != nil
    if let expectOrientation = options.expectOrientation {
        orientationPass = orientationPass && orientationValue == expectOrientation
    }
    let orientationExpected = options.expectOrientation.map { "\($0)" } ?? "orientation tag present (any value)"
    checks["metadataOrientation"] = [
        "pass": orientationPass,
        "detail": "EXIF present=\(exifPresent), orientation=\(orientationValue.map { "\($0)" } ?? "missing"); "
            + "expected \(orientationExpected)",
        "exifPresent": exifPresent,
        "tiffPresent": asBool(propertiesSummary["tiffPresent"]) ?? false,
        "actualOrientation": orientationValue.map { $0 as Any } ?? NSNull(),
        "expectedOrientation": options.expectOrientation.map { $0 as Any } ?? NSNull(),
    ]

    let sdrHasAlpha = asBool(sdrDecode["hasAlpha"]) ?? false
    let hdrHasAlpha = asBool(hdrDecode["hasAlpha"]) ?? false
    let noAlpha = !sdrHasAlpha && !hdrHasAlpha
    checks["noAlpha"] = [
        "pass": noAlpha,
        "detail": "SDR decode hasAlpha=\(sdrHasAlpha) (\(asString(sdrDecode["alphaInfo"]) ?? "?")), "
            + "HDR decode hasAlpha=\(hdrHasAlpha) (\(asString(hdrDecode["alphaInfo"]) ?? "n/a"))",
        "sdrHasAlpha": sdrHasAlpha,
        "hdrHasAlpha": hdrHasAlpha,
    ]

    let hdrDecodeSucceeded = hdrImage != nil
    let hdrLooksHDR = asBool(hdrDecode["isHDRContent"]) ?? false
    checks["hdrDecodeSucceeded"] = [
        "pass": hdrDecodeSucceeded,
        "detail": hdrDecodeSucceeded
            ? "kCGImageSourceDecodeToHDR succeeded (\(asInt(hdrDecode["width"]) ?? 0)x\(asInt(hdrDecode["height"]) ?? 0), "
                + "\(asInt(hdrDecode["bitsPerComponent"]) ?? 0)bpc, contentHeadroom=\(formatDouble(asDouble(hdrDecode["contentHeadroom"]) ?? 0, 4)))"
                + (hdrLooksHDR ? "" : " [returned SDR content: no gain map / headroom <= 1.0]")
            : (hdrError ?? "HDR decode failed"),
        "isHDRContent": hdrLooksHDR,
    ]

    if let expectHeadroom = options.expectHeadroom {
        let hdrContentHeadroom = asDouble(hdrDecode["contentHeadroom"]) ?? 0
        let hdrCalculatedHeadroom = asDouble(hdrDecode["calculatedContentHeadroom"]) ?? 0
        let auxHeadroom = auxLinearHeadroom(isoAux) ?? auxLinearHeadroom(hdrAux)
        var measured: Double?
        var measurementSource = "none"
        if hdrContentHeadroom > 0 {
            measured = hdrContentHeadroom
            measurementSource = "hdrDecode.contentHeadroom"
        } else if let auxHeadroom {
            measured = auxHeadroom
            measurementSource = "aux metadata (alternate headroom -> linear)"
        } else if hdrCalculatedHeadroom > 0 {
            measured = hdrCalculatedHeadroom
            measurementSource = "hdrDecode.calculatedContentHeadroom"
        }
        var pass = false
        var relativeError: Any = NSNull()
        if let measured {
            let error = abs(measured / expectHeadroom - 1.0)
            relativeError = error
            pass = error <= 0.05
        }
        checks["headroomWithin5pct"] = [
            "pass": pass,
            "detail": "expected \(formatDouble(expectHeadroom, 4)) linear, measured "
                + "\(measured.map { formatDouble($0, 4) } ?? "n/a") (\(measurementSource)); tolerance 5%",
            "expected": expectHeadroom,
            "measured": measured ?? NSNull(),
            "measurementSource": measurementSource,
            "relativeError": relativeError,
            "tolerance": 0.05,
            "contentHeadroom": hdrContentHeadroom,
            "calculatedContentHeadroom": hdrCalculatedHeadroom,
            "auxHeadroomLinear": auxHeadroom ?? NSNull(),
        ]
    } else {
        skipped.append("headroomWithin5pct (no --expect-headroom supplied)")
    }

    if let baseComparison, baseComparison.available {
        let baseMode = baseComparison.baseUniform ? "uniform" : "photo"
        let thresholds = baseThresholds(uniform: baseComparison.baseUniform)
        let decodedVariance = asDouble(baseComparison.decodedBaseVariance["overall"]) ?? 0.0
        let pass: Bool
        let detail: String
        if baseComparison.baseUniform {
            // M0 synthetic assertion: an exactly uniform base must survive
            // encode/decode unchanged. Anything else is a real failure.
            pass = baseComparison.meanAbsDiff == 0
                && baseComparison.maxAbsDiff == 0
                && decodedVariance == 0
            detail = "uniform base: meanAbsDiff=\(formatDouble(baseComparison.meanAbsDiff, 4)) (==0), "
                + "maxAbsDiff=\(baseComparison.maxAbsDiff) (==0), decodedBaseVariance="
                + "\(formatDouble(decodedVariance, 4)) (==0); p99=\(baseComparison.absDiffP99), "
                + "p99.9=\(baseComparison.absDiffP99_9) (diagnostics)"
        } else {
            // Real photograph: 8-bit 4:2:0 HEVC cannot preserve per-pixel maxima,
            // so judge drift by distribution (bias, mean, p99) and report
            // p99.9/max as diagnostics only.
            pass = abs(baseComparison.meanSignedDiff) <= 0.5
                && baseComparison.meanAbsDiff <= 2.5
                && baseComparison.absDiffP99 <= 16
            detail = "photo base: |meanSignedDiff|=\(formatDouble(abs(baseComparison.meanSignedDiff), 4)) (<=0.5), "
                + "meanAbsDiff=\(formatDouble(baseComparison.meanAbsDiff, 4)) (<=2.5), "
                + "absDiffP99=\(baseComparison.absDiffP99) (<=16), "
                + "p99.9=\(baseComparison.absDiffP99_9) / maxAbsDiff=\(baseComparison.maxAbsDiff) (diagnostics), "
                + "fractionNonZero=\(formatDouble(baseComparison.fractionNonZero, 4))"
        }
        checks["basePreserved"] = [
            "pass": pass,
            "detail": detail,
            "baseMode": baseMode,
            "baseThresholds": thresholds,
            // `thresholds` kept as an alias for reports written before M0-B2.
            "thresholds": thresholds,
            "meanAbsDiff": baseComparison.meanAbsDiff,
            "meanSignedDiff": baseComparison.meanSignedDiff,
            "absDiffP50": baseComparison.absDiffP50,
            "absDiffP90": baseComparison.absDiffP90,
            "absDiffP99": baseComparison.absDiffP99,
            "absDiffP99_9": baseComparison.absDiffP99_9,
            "maxAbsDiff": baseComparison.maxAbsDiff,
            "fractionNonZero": baseComparison.fractionNonZero,
            "fractionAboveTwo": (baseComparison.histogram[">2"] ?? 0) > 0,
            "baseUniform": baseComparison.baseUniform,
            "decodedBaseVariance": decodedVariance,
        ]
    } else if options.base != nil {
        checks["basePreserved"] = [
            "pass": false,
            "detail": "base comparison unavailable: \(asString(baseCheck["reason"]) ?? "unknown reason")",
            "baseMode": NSNull(),
            "baseThresholds": NSNull(),
        ]
    } else {
        skipped.append("basePreserved (no --base supplied)")
    }

    let sdrFallbackPresent = sdrImage != nil && sdrWidth > 0 && sdrHeight > 0
    checks["sdrFallbackPresent"] = [
        "pass": sdrFallbackPresent,
        "detail": sdrFallbackPresent
            ? "plain CGImageSourceCreateImageAtIndex decoded \(sdrWidth)x\(sdrHeight)"
            : "plain SDR decode failed or has zero dimensions",
    ]

    for (name, check) in checks {
        if asBool(check["pass"]) == false {
            failures.append("\(name): \(asString(check["detail"]) ?? "failed")")
        }
    }
    let pass = failures.isEmpty
    report["checks"] = checks
    report["overall"] = [
        "pass": pass,
        "checkCount": checks.count,
        "passedCount": checks.count - failures.count,
        "failures": failures.sorted(),
        "skippedChecks": skipped.sorted(),
    ]

    // --- write JSON report
    let safeReport = jsonSafe(report) as! [String: Any]
    guard JSONSerialization.isValidJSONObject(safeReport) else {
        FileHandle.standardError.write("\(toolName): error: internal error, report is not valid JSON\n".data(using: .utf8)!)
        exit(1)
    }
    let jsonData: Data
    do {
        jsonData = try JSONSerialization.data(withJSONObject: safeReport,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    } catch {
        FileHandle.standardError.write("\(toolName): error: cannot serialize report: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    if let outPath = options.out {
        let outURL = URL(fileURLWithPath: outPath)
        do {
            try jsonData.write(to: outURL)
        } catch {
            FileHandle.standardError.write("\(toolName): error: cannot write report to \(outPath): \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    // --- human summary
    let ftyp = (report["container"] as? [String: Any])?["ftyp"] as? [String: Any]
    let majorBrand = asString(ftyp?["majorBrand"]) ?? "n/a"
    let brands = (ftyp?["compatibleBrands"] as? [String]) ?? []
    let itemCount = asInt(((report["container"] as? [String: Any])?["itemCount"])) ?? 0
    let isoHeadroom = asDouble((report["aux"] as? [String: Any])?["isoAuxLinearHeadroom"])
    let hdrAuxHeadroom = asDouble((report["aux"] as? [String: Any])?["hdrGainMapLinearHeadroom"])
    let auxWidth = asInt(isoAux["auxWidth"])
    let auxHeight = asInt(isoAux["auxHeight"])
    let pixelFormat = ((isoAux["pixelFormat"] as? [String: Any])?["fourCC"] as? String) ?? "n/a"
    let profile = asString(primaryImage["profileName"]) ?? "n/a"
    let orientation = asInt(primaryImage["orientation"]) ?? 0
    let hdrMeasured = hdrDecode["measured"] as? [String: Any]
    let hdrPeak = asDouble(hdrMeasured?["peak"])
    let hdrMean = asDouble(hdrMeasured?["mean"])
    let hdrFrac = asDouble(hdrMeasured?["fractionAboveOne"])
    let sdrHeadroom = asDouble(sdrDecode["contentHeadroom"])
    let sdrCalc = asDouble(sdrDecode["calculatedContentHeadroom"])

    print("\(toolName) v\(toolVersion) — \(options.input)")
    print("  file        \(data.count) bytes  sha256=\(sha256)")
    print("  container   major=\(majorBrand) brands=[\(brands.joined(separator: ", "))] items=\(itemCount)")
    print("  base image  \(sdrWidth)x\(sdrHeight) \(asString(primaryImage["colorModel"]) ?? "?") "
        + "\(asInt(primaryImage["bitsPerComponent"]) ?? 0)bpc/\(asInt(primaryImage["bitsPerPixel"]) ?? 0)bpp "
        + "profile=\(profile) orientation=\(orientation) alpha=\(asString(sdrDecode["alphaInfo"]) ?? "?")")
    if isoPresent {
        print("  aux ISO     present \(auxWidth.map { "\($0)" } ?? "?")x\(auxHeight.map { "\($0)" } ?? "?") "
            + "fmt=\(pixelFormat) altHeadroom=\(isoHeadroom.map { formatDouble($0, 4) } ?? "?")x"
            + (asBool(isoAux["dataOmittedByImageIO"]) == true ? " [ImageIO omitted aux data bytes]" : ""))
    } else {
        print("  aux ISO     ABSENT")
    }
    print("  aux HDRGain \(hdrAuxPresent ? "present headroom=\(hdrAuxHeadroom.map { formatDouble($0, 4) } ?? "?")x" : "absent")")
    print("  sdrDecode   \(sdrWidth)x\(sdrHeight) \(asInt(sdrDecode["bitsPerComponent"]) ?? 0)bpc "
        + "contentHeadroom=\(sdrHeadroom.map { formatDouble($0, 4) } ?? "?") calcHeadroom=\(sdrCalc.map { formatDouble($0, 4) } ?? "?")")
    if hdrDecodeSucceeded {
        print("  hdrDecode   OK \(asInt(hdrDecode["width"]) ?? 0)x\(asInt(hdrDecode["height"]) ?? 0) "
            + "\(asInt(hdrDecode["bitsPerComponent"]) ?? 0)bpc contentHeadroom=\(formatDouble(asDouble(hdrDecode["contentHeadroom"]) ?? 0, 4)) "
            + "calc=\(formatDouble(asDouble(hdrDecode["calculatedContentHeadroom"]) ?? 0, 4))")
        if let hdrPeak, let hdrMean, let hdrFrac {
            print("              measured peak=\(formatDouble(hdrPeak, 4)) mean=\(formatDouble(hdrMean, 4)) "
                + "frac>1=\(formatDouble(hdrFrac * 100, 2))%")
        }
    } else {
        print("  hdrDecode   FAILED (\(hdrError ?? "unknown"))")
    }
    if let baseComparison, baseComparison.available {
        let baseMode = baseComparison.baseUniform ? "uniform" : "photo"
        print("  baseCheck   mode=\(baseMode) meanAbsDiff=\(formatDouble(baseComparison.meanAbsDiff, 4)) "
            + "meanSignedDiff=\(formatDouble(baseComparison.meanSignedDiff, 4)) "
            + "p99=\(baseComparison.absDiffP99) p99.9=\(baseComparison.absDiffP99_9) "
            + "maxAbsDiff=\(baseComparison.maxAbsDiff) "
            + "fracNonZero=\(formatDouble(baseComparison.fractionNonZero, 4)) "
            + "decodedVariance=\(formatDouble(asDouble(baseComparison.decodedBaseVariance["overall"]) ?? 0, 4))"
            + (baseComparison.baseUniform ? " (uniform base -> strict)" : " (photo base -> distribution)"))
    }
    let checkNames = checks.keys.sorted()
    let checkLine = checkNames.map { name in
        "\(name)=\((asBool(checks[name]?["pass"]) == true) ? "PASS" : "FAIL")"
    }.joined(separator: " ")
    print("  checks      \(checkLine)")
    if !skipped.isEmpty {
        print("  skipped     \(skipped.sorted().joined(separator: "; "))")
    }
    print("  result      \(pass ? "PASS" : "FAIL")")
    if pass {
        print("  report      \(options.out ?? "(not written; use --out <path>)")")
    } else {
        for failure in failures.sorted() { print("    failure: \(failure)") }
        if let outPath = options.out { print("  report      \(outPath)") }
    }
    exit(pass ? 0 : 1)
}

main()
