# Goal

Compose a final **Adaptive HDR ("Ultra HDR") HEIC** from:

- **(a)** a 10-bit HEIC **SDR base image**, and
- **(b)** an **RGB gain map** (ISO 21496-1) produced by a custom external tool,

producing **(c)** a single HEIC whose base is 10-bit and whose gain map is stored at **half resolution**, using Apple's Core Image / ImageIO stack.

**Target:** macOS 27+, Apple Silicon only.

# Verdict

**Doable.** Everything required has existed since macOS 15 / iOS 18 (ISO 21496-1 "Adaptive HDR" support in ImageIO and Core Image), and macOS 27 only adds more encode surface. The exact target configuration — 10-bit HEIC SDR base + half-resolution RGB ISO 21496-1 gain map — is the same shape Apple's own camera/Photos pipeline writes since iOS 18. The widely-reported "inconsistency" is mostly historical and cross-platform; the macOS 27 + Apple Silicon target eliminates most of it (see Gotchas).

Note on naming: Apple brands ISO 21496-1 as **"Adaptive HDR"**. "Ultra HDR" strictly refers to Google's JPEG container (MPF + XMP); the gain-map math and metadata are the same ISO standard. On Apple platforms the natural container is HEIC, not the Ultra HDR JPEG.

# Background / standards

- ISO 21496-1 defines the gain-map formula, metadata (per-channel min/max gain, gamma, offset SDR/HDR, HDR capacity min/max), and storage in HEIF and JPEG. Apple and Google both adopted it (Android 15, Chrome, iOS 18, macOS 15+).
- In HEIF, the gain map is an auxiliary image item linked to the primary item (`auxl` reference, `tmap`/gain-map metadata describing how to convert pixels to linear gains).
- The base rendition here is SDR; gain map is the per-pixel log-ratio boost from SDR to HDR. RGB (3-channel) maps capture saturated-highlight color better than monochrome maps; ISO 21496-1 supports RGB, the older Apple (iOS 14.1-era `hdrgainmap`) format did not.
- Apple's own files: base HEIC + gain map at half (sometimes quarter) resolution, 8-bit map pixels; since iOS 18 the map is ISO 21496-1.

Key references:

- WWDC24 session "Use HDR for dynamic image experiences in your app" — canonical API walkthrough: https://developer.apple.com/videos/play/wwdc2024/10177/
- Juniper Photon, "Process Apple Gain Map: The ImageIO & the Core Image approaches": https://juniperphoton.substack.com/p/process-apple-gain-map-the-imageio
- Juniper Photon, "Pitfalls and workarounds when dealing with RGB HDR Gain Map using ImageIO": https://juniperphoton.substack.com/p/pitfalls-and-workarounds-when-dealing
- chemharuka/toGainMapHDR (open-source tool proving the exact combo: RGB ISO gain map, half-size, 10-bit HEIC): https://github.com/chemharuka/toGainMapHDR
- Adobe gain-map spec draft (metadata semantics): https://forum.affinity.serif.com/applications/core/interface/file/attachment.php?id=335943&key=db9e92dd06542d7ec428309d337820e2

# Path A — Core Image (simplest, try first)

`CIContext.writeHEIF10Representation` gives the 10-bit HEIC base; options attach the gain map:

```swift
try ciContext.writeHEIF10Representation(
    of: sdrBaseImage,                        // 10-bit SDR base as CIImage
    to: outputURL,
    colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
    options: [
        .hdrGainMapImage: gainMapCIImage,     // RGB gain map as CIImage
        .hdrGainMapAsRGB: true,               // 3-channel ISO 21496-1 gain map
        .lossyCompressionQuality: 0.9
    ]
)
```

Notes:

- **Gain-map resolution = the extent of the CIImage you pass.** Downsample to exactly half width/height yourself (e.g. `CILanczosScaleTransform` or area average) before passing. If the extent is wrong (full-res map), iOS 18 Photos showed zoom artifacts; half-res is also what Apple writes.
- **Metadata comes from the gain-map CIImage's properties.** When a gain map is loaded from an existing ISO file via `CIImage(contentsOf: url, options: [.auxiliaryHDRGainMap: true])`, its ISO metadata (gamma, offsets, gain min/max, capacity) rides along in `properties` and is reused on save. A gain map produced by a custom tool has no such properties — **attach them explicitly** (e.g. `imageBySettingProperties(...)`), ideally cloned from a known-good iPhone reference file. Otherwise Core Image may write defaults that don't match the custom map's math. This is the main fidelity risk of Path A.
- `writeHEIFRepresentation` (8-bit) exists too; the 10-bit variant is `writeHEIF10Representation` (macOS 12+).
- Reading the gain map back as CIImage: `CIImage(contentsOf: url, options: [.auxiliaryHDRGainMap: true])`. Combine for display with `imageByApplyingGainMap(_:headroom:)`.

# Path B — ImageIO (full control; best match for a custom gain-map tool)

`CGImageDestination` lets you supply your own gain-map pixels and metadata byte-exactly:

```swift
guard let dest = CGImageDestinationCreateWithURL(
    outputURL as CFURL, AVFileType.heic as CFString, 1, nil
) else { throw ... }

// 1) Base: a 10-bit (or 16-bit half-float) SDR CGImage
CGImageDestinationAddImage(dest, baseCGImage, [
    kCGImageDestinationLossyCompressionQuality: 0.9
] as CFDictionary)

// 2) Gain map: raw RGB pixels + description + ISO metadata
var aux: [CFString: Any] = [
    kCGImageAuxiliaryDataInfoData: gainMapPixels,          // CFData, half-res RGB
    kCGImageAuxiliaryDataInfoDataDescription: [
        "PixelFormat": "RGB8" /* or L8 for mono */,
        "Width": w / 2, "Height": h / 2,
        "BytesPerRow": stride
    ],
    kCGImageAuxiliaryDataInfoMetadata: isoGainMapMetadata,  // CGImageMetadata: gamma, offsets, gain min/max, capacity
    kCGImageAuxiliaryDataInfoColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
]
CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeISOGainMap, aux as CFDictionary)

CGImageDestinationFinalize(dest)
```

Notes:

- Use **`kCGImageAuxiliaryDataTypeISOGainMap`** (macOS 15+), not the older `kCGImageAuxiliaryDataTypeHDRGainMap` (Apple pre-ISO format).
- There is **no `hdrGainMapAsRGB` equivalent** on the ImageIO path — channel count is determined by the pixel format in the data description (`RGB8` vs `L8`).
- 10-bit base works: pass a 10/16-bit CGImage; ImageIO's HEVC encoder on Apple Silicon encodes 10-bit HEVC (hardware). `toGainMapHDR -d 10 -H` produces exactly this shape.
- If the gain-map metadata dictionary is built from scratch, the CGImageMetadata must encode the ISO 21496-1 fields (per-channel gamma, offsetSDR/offsetHDR, gain min/max, HDR capacity min/max, base-is-SDR flag). Easiest reliable route: extract the metadata object from a reference iPhone HEIC and mutate values.

# New macOS 26/27 ImageIO encode options (be aware, don't depend yet)

The ImageIO headers in the macOS 27 SDK add a whole HDR encode surface:

- `kCGImageDestinationEncodeRequest` (`kCGImageDestinationEncodeToSDR` / `ToISOHDR` / `ToISOGainmap`)
- `kCGImageDestinationEncodeGenerateGainMapWithBaseImage` — generate the gain map during encode (exists since macOS 16, value type undocumented; reportedly refuses a CGImage base as of macOS 27)
- `kCGImageDestinationEncodeGainMapSubsampleFactor` — subsample factor for a generated map
- `kCGImageDestinationEncodeBasePixelFormatRequest` / `kCGImageDestinationEncodeGainMapPixelFormatRequest`
- `kCGImageDestinationEncodeBaseIsSDR`, `kCGImageDestinationEncodeIsBaseImage`, `kCGImageDestinationEncodeBaseColorSpace` / `AlternateColorSpace`, `kCGImageDestinationEncodeTonemapMode`

These are sparsely documented; pin behavior by testing rather than assuming. Relevant only if you want ImageIO to compute the gain map itself — not needed when the map comes from the custom tool.

# Gotchas (the "inconsistent across OSes and hardware" part)

1. **Gain-map size mismatch.** Map must be exactly half width/height of the base (same aspect). Full-res or arbitrary-size maps caused Photos artifacts on iOS 18. If width/height is odd, one row/column is cropped.
2. **Metadata fidelity.** Core Image silently reuses whatever ISO metadata is attached to the gain-map CIImage; missing/mismatched metadata (gamma/offset/min-max/capacity) makes the HDR render wrong even though the file "works". Explicitly set and verify.
3. **Asymmetric read-back.** `CGImageSourceCopyAuxiliaryDataInfoAtIndex` on an ISO gain-map file returns only 3 keys — `kCGImageAuxiliaryDataInfoData` (the bitmap) is missing. To get the map pixels, read via Core Image (`.auxiliaryHDRGainMap` option). Reading the ISO map from HEIC works on macOS 15+; older OSes only see the legacy Apple gain map.
4. **OS-version drift.** Gain-map decode behavior measurably changed between macOS 15 and macOS 27 (reader caveats are pinned per-OS in projects like HDRView). Validate on the actual minimum OS; don't extrapolate from macOS 15 results.
5. **JPEG side note (only if you also emit Ultra HDR JPEG).** macOS ImageIO fails to decode XMP-only Ultra HDR JPEGs (CGImageSource returns nil); files carrying ISO 21496-1 metadata decode fine. Apple's own JPEGs carry both XMP + ISO.
6. **Hardware.** Apple Silicon: every AS Mac has hardware 10-bit HEVC encode — non-issue. Intel Macs may lack it (out of target scope anyway).
7. **Photos/Photos-library behavior:** Photos stores gain-map HEIC/JPEG byte-for-byte (no re-encode on import), so what you write is what renders there.

# Recommended validation loop

1. **Round-trip decode:** read the written file with `kCGImageSourceDecodeToHDR`, render to extended-linear Display P3 half-float, and numerically compare against the intended HDR rendition (this is the harness XDRemux and HDRView use). Also check `CGImageGetContentHeadroom`.
2. **Probe metadata:** `exiftool` (look for the ISO gain-map aux item and metadata); Adobe's Gain Map Demo app should report "ISO 21496-1"; for JPEG outputs, `ultrahdr_app` from libultrahdr 2.x.
3. **Visual:** open in Photos and Preview on macOS 27 on an HDR display; confirm highlight behavior and that SDR fallback (non-HDR display) shows the base correctly.
4. **Regression pin:** decode results differ per OS — record which macOS version each measurement was made on.

# Suggested implementation order

1. Prototype with Path A (`writeHEIF10Representation` + `.hdrGainMapAsRGB: true`, half-res map, metadata cloned from an iPhone reference file).
2. If the custom tool's map doesn't round-trip faithfully (metadata defaults mismatch), switch to Path B and pass pixels + metadata explicitly.
3. Wire the validation loop above into CI; pin macOS version in test caveats.

# Reference projects worth mining

- https://github.com/chemharuka/toGainMapHDR — converts HDR inputs to Adaptive HDR HEIC with RGB ISO gain maps, half-size maps (`-H`), 10-bit (`-d 10`); validates the whole approach.
- https://juniperphoton.substack.com/p/process-apple-gain-map-the-imageio and https://juniperphoton.substack.com/p/pitfalls-and-workarounds-when-dealing — the most complete practitioner write-ups of both ImageIO and Core Image paths, including the ISO read-back pitfalls.
- https://developer.apple.com/videos/play/wwdc2024/10177/ — WWDC24 session with the canonical read/edit/save strategies (SDR+Gain strategy is the one used here).
- https://github.com/wkjarosz/hdrview/pull/240 — per-writer/per-OS gain-map round-trip test methodology.
- https://github.com/21Z121Z1/XDRemux/pull/68 — measured the macOS 27 SDK HEIF HDR encode surface and Core Image gain-map prototypes.
- https://github.com/anton-belkin/ActionFootagePlayer/pull/118 — cross-checks custom-written ISO gain maps against Core Image's own HEIC output (~2% agreement) and notes the macOS 27 `kCGImageDestinationEncodeGenerateGainMapWithBaseImage` CGImage-base refusal.
- https://github.com/darktable-org/darktable/pull/21458 — Ultra HDR JPEG via libultrahdr; documents the macOS ImageIO XMP-vs-ISO decode failure mode.