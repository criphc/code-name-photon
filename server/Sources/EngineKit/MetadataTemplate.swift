import CoreGraphics
import Foundation
import ImageIO

/// The ISO 21496-1 metadata the gain map needs, and the EXIF/GPS/orientation pass-through.
///
/// The ISO fields are cloned from a tiny checked-in HEIC (`Resources/iso-gainmap-template.heic`,
/// generated once with the external tool from a synthetic pair) and then set to the authored peak.
/// Building `ChannelMetadata` from scratch is possible but the clone is the documented, reliable
/// route (docs/plans/external-reference-hdr-heic-…, "Metadata fidelity").
enum MetadataTemplate {
    /// The gain-map metadata for one delivery: `AlternateHeadroom` and every channel's
    /// `GainMapMax` are `log2(authoredPeak)`, matching `GainMap`'s normalisation.
    static func isoGainMap(authoredPeak: Float) throws -> CGImageMetadata {
        guard let url = Bundle.module.url(forResource: "iso-gainmap-template", withExtension: "heic") else {
            throw PhotonError.invalidImage(reason: "missing ISO gain-map metadata template resource")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                  source, 0, kCGImageAuxiliaryDataTypeISOGainMap
              ) as? [CFString: Any]
        else {
            throw PhotonError.invalidImage(reason: "cannot read the ISO gain-map metadata template")
        }
        let template = aux[kCGImageAuxiliaryDataInfoMetadata] as! CGImageMetadata
        guard let metadata = CGImageMetadataCreateMutableCopy(template) else {
            throw PhotonError.invalidImage(reason: "cannot copy the ISO gain-map metadata template")
        }
        let logPeak = log2(Double(authoredPeak))
        guard CGImageMetadataSetValueWithPath(
            metadata, nil, "HDRToneMap:AlternateHeadroom" as CFString, NSNumber(value: logPeak)
        ) else {
            throw PhotonError.invalidImage(reason: "cannot set AlternateHeadroom in the gain-map metadata")
        }
        for index in 0..<3 {
            guard CGImageMetadataSetValueWithPath(
                metadata, nil,
                "HDRToneMap:ChannelMetadata[\(index)].GainMapMax" as CFString,
                NSNumber(value: logPeak)
            ) else {
                throw PhotonError.invalidImage(
                    reason: "cannot set ChannelMetadata[\(index)].GainMapMax in the gain-map metadata"
                )
            }
            // The rendition is base * gain with gain >= 1, so the map's range is [0, logPeak].
            // The template's GainMapMin can be negative (its synthetic HDR dipped below the
            // base); leaving it would make the decoder read every map value as a negative gain.
            guard CGImageMetadataSetValueWithPath(
                metadata, nil,
                "HDRToneMap:ChannelMetadata[\(index)].GainMapMin" as CFString,
                NSNumber(value: 0.0)
            ) else {
                throw PhotonError.invalidImage(
                    reason: "cannot set ChannelMetadata[\(index)].GainMapMin in the gain-map metadata"
                )
            }
        }
        return metadata
    }

    /// Rewraps the image metadata of an encoded HEIC with the filtered source EXIF/TIFF/GPS,
    /// preserving the base and any ISO gain map. Used for both the HDR file and the 8-bit SDR
    /// fallback, so the file non-HDR viewers see carries the same capture metadata.
    static func rewrap(encodedURL: URL, sourceURL: URL, to outputURL: URL) throws {
        guard let encoded = CGImageSourceCreateWithURL(encodedURL as CFURL, nil) else {
            throw PhotonError.writeFailed(
                path: encodedURL.path,
                reason: "cannot reopen the encoded HEIC for the metadata rewrap"
            )
        }
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw PhotonError.sourceUnreadable(
                path: sourceURL.path,
                reason: "cannot open the source for the metadata rewrap"
            )
        }
        let sourceMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let filtered = filteredSourceMetadata(sourceMetadata)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, "public.heic" as CFString, 1, nil
        ) else {
            throw PhotonError.writeFailed(
                path: outputURL.path,
                reason: "cannot create the metadata-rewrap destination"
            )
        }
        var options: [CFString: Any] = [:]
        if let filtered { options[kCGImageDestinationMetadata] = filtered }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(
            destination, encoded, options as CFDictionary, &error
        ) else {
            let reason = error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown error"
            throw PhotonError.writeFailed(
                path: outputURL.path,
                reason: "metadata rewrap failed: \(reason)"
            )
        }
    }

    /// Only EXIF, TIFF and GPS tags survive. XMP/IPTC/Photoshop tags are deliberately dropped
    /// (Capture One writes labels/ratings there; the delivery contract carries capture metadata,
    /// not the editor's sidecar). Orientation is a TIFF tag, so it passes through as-is.
    static func filteredSourceMetadata(_ source: CGImageMetadata?) -> CGImageMetadata? {
        guard let source else { return nil }
        let filtered = CGImageMetadataCreateMutable()
        let tags = CGImageMetadataCopyTags(source) as? [CGImageMetadataTag] ?? []
        var registered: Set<String> = []
        for tag in tags {
            let namespace = (CGImageMetadataTagCopyNamespace(tag) as String?) ?? ""
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
            guard !namespace.isEmpty, !name.isEmpty else { continue }
            let lower = namespace.lowercased()
            let prefix: String
            if lower.contains("tiff") {
                prefix = "tiff"
            } else if lower.contains("gps") {
                prefix = "gps"
            } else if lower.contains("exif") {
                prefix = "exif"
            } else {
                continue
            }
            if !registered.contains(namespace) {
                var error: Unmanaged<CFError>?
                _ = CGImageMetadataRegisterNamespaceForPrefix(
                    filtered, namespace as CFString, prefix as CFString, &error
                )
                registered.insert(namespace)
            }
            _ = CGImageMetadataSetTagWithPath(
                filtered, nil, "\(prefix):\(name)" as CFString, tag
            )
        }
        return filtered
    }
}
