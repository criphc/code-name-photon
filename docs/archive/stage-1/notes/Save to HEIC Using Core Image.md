# Save to HEIC Using Core Image

*Created: 11/1/2026, 4:02:47 PM*

---

**You**

what save to heic options do i have using apple’s core image?

---

**Assistant**

## The four Core Image entry points

Core Image exposes HEIF only through `CIContext`, in a "returns `Data`" and a "writes to `URL`" flavour, each in an 8-bit and a 10-bit variant:

| API | Output | Availability | Pixel format |
|---|---|---|---|
| `heifRepresentation(of:format:colorSpace:options:)` → `Data?` | HEIF | iOS 11 / macOS 10.13.4 [^1] | you pass a `CIFormat` [^2] |
| `writeHEIFRepresentation(of:to:format:colorSpace:options:)` | file | iOS 11 / macOS 10.13.4 [^1] | you pass a `CIFormat` [^1] |
| `heif10Representation(of:colorSpace:options:)` → `Data` | HEIF10 | iOS 15 / macOS 12 [^3] | fixed 10-bit, no `CIFormat` argument [^2] |
| `writeHEIF10Representation(of:to:colorSpace:options:)` | file | iOS 15 / macOS 12 [^3] | fixed 10-bit [^3] |

Constraints that bite in practice:

- The colour space **must** conform to the RGB or monochrome `CGColorSpaceModel` and be compatible with the pixel format [^1]. So Display P3, sRGB, BT.2020, extended linear, and gray all work; CMYK does not.
- The image must be non-empty with a finite `extent` — apply `clampedToExtent()` + `cropped(to:)` after filters that produce infinite extents [^f0af5b#60].
- There is **no 16-bit HEIF path**. `writeHEIFRepresentation` with `RGBAh`/`RGBAf` still lands at 8-bit, and `HEIF10` is the ceiling; for 16-bit you have to leave HEIF (PNG or OpenEXR) [^4] [^5]. There is also no AVIF representation method in `CIContext` at all — the export family is TIFF, JPEG, PNG, HEIF, HEIF10, OpenEXR only [^2].

## What you can actually pass in `options`

The parameter is typed `[CIImageRepresentationOption : Any]` [^1], and that struct is a thin `RawRepresentable` wrapper over string keys [^6], so it accepts both Core Image's own constants and plain ImageIO/CGImageDestination keys (bridged through `rawValue`).

Core Image–specific keys:

| Option | Use |
|---|---|
| `.hdrImage` | writes an HDR HEIF (10-bit / HLG or PQ) |
| `.hdrGainMapImage` | embeds a gain-map channel into a HEIF (or JPEG) [^6] |
| `.hdrGainMapAsRGB` | makes that gain map chromatic rather than monochrome [^6] |
| `.depthImage` / `.disparityImage` | embeds depth or disparity auxiliary images [^6] |
| `.avDepthData`, `.avPortraitEffectsMatte` | embeds AVFoundation depth/matte payloads [^6] |
| `.portraitEffectsMatteImage`, `.semanticSegmentationHairMatteImage`, `…SkinMatteImage`, `…TeethMatteImage`, `…GlassesMatteImage`, `…SkyMatteImage` | embeds mattes as auxiliary images [^6] |

Plus the ImageIO key `kCGImageDestinationLossyCompressionQuality` (a `Float` 0…1) for the quality/bitrate trade-off. Apple documents that key explicitly for the JPEG representation method [^7], and it is the same CGImageDestination property that the HEIC encoder consumes, so it is what everyone uses for HEIF too — but note Apple's HEIF page itself only says "a dictionary with additional options for export" [^1], so treat quality control as uniform ImageIO behaviour rather than a HEIF-specific documented option. Because the dictionary is keyed by `CIImageRepresentationOption`, you must wrap string keys:

```swift
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!])

let quality = CIImageRepresentationOption(
    rawValue: kCGImageDestinationLossyCompressionQuality as String
)

// 8-bit HEIC with alpha, quality 0.8
try ctx.writeHEIFRepresentation(
    of: image,
    to: url,                       // .../photo.heic
    format: .RGBA8,
    colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
    options: [quality: 0.8]
)

// 10-bit HDR HEIC
try ctx.writeHEIF10Representation(
    of: image,
    to: url,
    colorSpace: CGColorSpace(name: CGColorSpace.itur_2100_HLG)!,
    options: [quality: 0.9, .hdrImage: true]
)
```

For 8-bit, `.RGBA8` (or `.BGRA8`) is the sane choice: it preserves an alpha channel, and HEIC does support alpha on Apple platforms. `.RGB8`/`.RGBh` on a HEIF write is where people hit "diagonal lines"/blank-output oddities with cropped or infinite-extent images [^8].

## Where Core Image stops and ImageIO begins

The `CIContext` HEIF methods are a convenience wrapper over `CGImageDestination`. They give you **no way to attach EXIF/GPS/TIFF metadata** (orientation, capture date, lens, maker notes) and no access to the container-level knobs. If you need those, render the `CIImage` to a `CGImage` and write it yourself:

```swift
guard let cgImage = ctx.createCGImage(image, from: image.extent,
                                      format: .RGBA8,
                                      colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!) else { return }

let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil)!
let props: [CFString: Any] = [
    kCGImageDestinationLossyCompressionQuality: 0.8,
    kCGImagePropertyOrientation: 6,
    kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:01 12:00:00"]
]
CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
CGImageDestinationFinalize(dest)
```

That route also unlocks HEICS image sequences (via `CGImageDestinationCreateWithURL` with a count > 1 and the `heics` type), custom tiles, and `CGImageDestinationAddAuxiliaryDataInfo` for gain maps built outside Core Image. Everything Core Image's own HEIF writer can do is reachable there; the reverse is not true.

**Practical summary:** `.RGBA8` + Display P3 + `kCGImageDestinationLossyCompressionQuality` for normal photos; `writeHEIF10Representation` + `.hdrImage` for 10-bit HDR; `.hdrGainMapImage` if you need backward-compatible SDR/HDR in one file; switch to ImageIO the moment you need metadata or container control; and don't try to get 16-bit out of HEIF at all.

**References**

[^1]: [writeheifrepresentation(of:to:format:colorspace:options:).md](https://developer.apple.com/documentation/coreimage/cicontext/writeheifrepresentation(of:to:format:colorspace:options:).md) (9%)
[^2]: [cicontext.md](https://developer.apple.com/documentation/coreimage/cicontext.md) (50%)
[^3]: [writeheif10representation(of:to:colorspace:options:).md](https://developer.apple.com/documentation/coreimage/cicontext/writeheif10representation(of:to:colorspace:options:).md) (4%)
[^4]: [How to export 16-bit HEIF images in Swift? - Stack Overflow](https://stackoverflow.com/questions/57483720/how-to-export-16-bit-heif-images-in-swift) (5%)
[^5]: [How do I export a 16 bit PNG in macOS using the ciContext ...](https://stackoverflow.com/questions/77532501/how-do-i-export-a-16-bit-png-in-macos-using-the-cicontext-writepngrepresentation) (1%)
[^6]: [ciimagerepresentationoption.md](https://developer.apple.com/documentation/coreimage/ciimagerepresentationoption.md) (28%)
[^7]: [jpegRepresentation(of:colorSpace:options:)](https://developer.apple.com/documentation/coreimage/cicontext/jpegrepresentation(of:colorspace:options:)) (2%)
[^8]: [Core Image ciContext.writeHEIFRepresentation ...](https://stackoverflow.com/questions/68124487/core-image-cicontext-writeheifrepresentation-generates-images-with-diagonal-li) (2%)

---

**You**

what exactly is a 10-bit HDR HEIC file consisted of

---

**Assistant**

## Two different files get called "10-bit HDR HEIC"

They share a container, and almost nothing else:

| | **True 10-bit HEIC** (`heix`) | **Apple gain-map HEIC** (iPhone "HDR") |
|---|---|---|
| Bits | 10 per sample in one HEVC bitstream | 8-bit base + 8-bit monochrome gain map |
| Brand | `heix` (Main 10 / range extensions) [^1] [^2] | `heic` (Main / Main Still, 8-bit) [^1] |
| HDR carrier | PQ or HLG transfer in `colr` | proprietary auxiliary item + XMP headroom |
| Where you meet it | Canon/Sony/Nikon `.HIF`, `CIContext.writeHEIF10Representation` | every iPhone photo since iOS 14 |

The first byte range of `ftyp` tells you which you have: a file whose major brand is `heic` cannot legally hold 10-bit data, so a real 10-bit file is `heix` with compatible brands `mif1`, `heix`, `miaf` [^1].

## Dialect 1: an actual 10-bit HDR HEIC

It is an ISO-BMFF file with exactly three top-level boxes — `ftyp`, `meta`, `mdat` — in a real sample 36 bytes, ~74 KB and ~6.7 MB respectively [^3] [^3]:

```
ftyp   heix / mif1, heix, miaf
meta
├── hdlr        'pict'
├── pitm        primary item ID
├── iinf        one infe per item: hvc1 | grid | iden | Exif | mime | hvc2
├── iref        dimg (tiles→grid), auxl (aux→main), cdsc (XMP→image), thmb
├── iprp
│   ├── ipco    ispe, hvcC, colr, pixi, clli, mdcv, auxC, irot/imir
│   └── ipma    item → property associations (with essential flags)
├── iloc        byte offsets/lengths into mdat
└── idat        occasionally, for tiny property payloads / grid descriptors
mdat           the HEVC bitstreams, Exif blob, XMP blobs
```

Nothing is stored "as an image" — the picture is a set of items, and the one you see is whichever item `pitm` names, possibly a `grid` that composes tiles. Apple-style encoders tile anything large: one sample is 36 `hvc1` tiles behind a 6×6 `grid` item, referenced by `dimg` [^3] [^3].

### The five things that make it "10-bit HDR"

| Element | Where | What it says |
|---|---|---|
| `hvcC` | `ipco` | `general_profile_idc = 2` (Main 10), `chroma_format = 1` (4:2:0), `bit_depth_luma/chroma = 10` — the field is *minus 8*, so stored as 2 [^3] |
| `hvcC` arrays | `ipco` | VPS + SPS + PPS NAL units, so a decoder can start on any item with no external setup — identical in format to an HEVC video sample entry [^2] |
| `colr` | `ipco` | `nclx`: primaries 9 (BT.2020), transfer 16 (PQ) or 18 (HLG), matrix, full-range flag — or an ICC profile instead [^2] |
| `clli` | `ipco` | MaxCLL / MaxFALL in cd/m², for brightness scaling [^2] |
| `mdcv` | `ipco` | mastering primaries, white point, min/max luminance, as the reference for tone mapping [^2] |

Optional additions in the same family: `cclv` (content colour volume), `amve` (ambient viewing environment), `ndwt` (nominal diffuse white — the "this level is paper white" hint), `reve` [^2]. `pixi` redundantly declares components and bit depth [^2]. `clli`/`mdcv`/`pasp` are item properties that libheif, for instance, only attaches to the pixel image rather than to composed items — a known source of "metadata vanished after I built a grid" bugs [^4].

Note the bit budget honestly: 10-bit 4:2:0 means 10-bit luma and 10-bit chroma at quarter resolution, ~15 bits/pixel against 12 for 8-bit 4:2:0. Sony's cameras offer 10-bit 4:2:0 *or* 4:2:2 [^1]; at 4:2:2 HEVC range extensions are in play and the `heix` brand covers that too [^2].

### What the HEVC payload actually is

One intra-coded picture per item — no P/B frames, no timing, no audio, no edit lists. Each tile or item is a single coded picture, which is precisely why it can be both "a photo" and "a video sample" without re-encoding [^2]. Alpha doesn't exist inside that bitstream: it's a second monochrome auxiliary item linked with `auxl` and an `auxC` URN, so a 10-bit-with-alpha HEIC is two bitstreams, and the alpha plane's depth is independent of the colour plane's.

### The 10-bit → light mapping

With PQ, sample value is an absolute luminance code (0 = 0 cd/m², 1023 ≈ 10 000 cd/m²). With HLG, it's relative and scene-referred, so the display applies its own system gamma — which is why Nikon fixes HEIF colour space to BT.2100 in HLG mode [^1]. A file that signals 10-bit + BT.2020 + PQ and *omits* `clli`/`mdcv` is legal but leaves the tone mapper guessing; that's the usual state of a file produced by a naive encoder.

## Dialect 2: what an iPhone HDR HEIC is made of

Structurally the same shell, but the HDR lives in a *second image*:

- Base item: 8-bit HEVC, Display P3, ordinary photo.
- Gain-map item: `auxC` = `urn:com:apple:photo:2020:aux:hdrgainmap`, single-channel, untagged, **1/4 resolution**, Rec.709 transfer [^5] [^6].
- `iref` carries `auxl` from gain map → base, so the gain map is not a second picture you can accidentally show [^3].
- A separate XMP item, linked by `cdsc`, holds `HDRGainMap:HDRGainMapVersion` and `HDRGainMap:HDRGainMapHeadroom` — e.g. headroom 3.482, meaning HDR can be ~3.5× (about 1.8 stops) brighter than the SDR base [^3].

The Inspector's capability list makes the distinction concrete: an HDR gain map, `clli`/`mdcv` light-level metadata, and a PQ/HLG transfer in `nclx` are three separate features, any of which can be absent [^7]. Apple's format deliberately has the last two absent — it degrades perfectly to SDR on old viewers, which true 10-bit PQ does not. ISO/IEC 23008-12 Amendment 1 later standardised its own gain-map/tone-map mechanism (`tmap` derived item), distinct from Apple's URN [^8].

## What it does not contain

- **No 16-bit anything.** HEIF tops out at 10-bit for HEVC; `RGBAh` into `writeHEIFRepresentation` still exits 8-bit.
- **No per-pixel dynamic metadata**, no Dolby Vision, no dual-layer SDR/HDR base — only static `clli`/`mdcv` plus, if present, a gain-map image.
- **No alpha inside the colour stream** (separate auxiliary item), and no 10-bit alpha guarantee.
- **No ICC profile usually** — an `nclx` triple instead, which is why HDR HEICs look wrong in readers that only honour ICC.

## Practical checks

```bash
xxd -l 32 photo.heic        # ftyp: heic → 8-bit, heix → 10-bit candidate
heif-info photo.heic        # items, hvcC profile, bit depth, aux types
heif-convert --with-aux photo.heic out.jpg   # spills out the hdrgainmap too
```

Or open [heic.fyi's inspector](https://heic.fyi/heic-inspector), which prints brands, HEVC profile/tier/level, chroma format, bit depth, NAL length size, and each item's `auxC` URN in one pass [^7].

**The one-line answer:** a 10-bit HDR HEIC is an ISOBMFF container (`ftyp`/`meta`/`mdat`) whose `heix`-branded items are intra-coded HEVC Main 10 pictures — usually tiled behind a `grid` — each described by an `hvcC` claiming 10-bit 4:2:0 and a `colr` `nclx` claiming BT.2020 with PQ or HLG, optionally refined by `clli`/`mdcv`; unless it's an iPhone file, in which case it is an 8-bit SDR photo plus a quarter-resolution 8-bit gain map and an XMP headroom number.

**References**

[^1]: [HEIC vs HEIF: what's the difference? — heic.fyi](https://heic.fyi/learn/heic-vs-heif) (18%)
[^2]: [HEIF Technical Information - High Efficiency Image File Format](https://nokiatech.github.io/heif/technical.html) (34%)
[^3]: [HEIC Container Structure | chemharuka/toGainMapHDR | DeepWiki](https://deepwiki.com/chemharuka/toGainMapHDR/5.4-heic-container-structure) (28%)
[^4]: [Image metadata (clli, mdcv, pasp, ...) should be assignable to](https://github.com/strukturag/libheif/issues/1598) (2%)
[^5]: [docs.developer.apple.com](https://docs.developer.apple.com/tutorials/data/documentation/appkit/applying-apple-hdr-effect-to-your-photos.md) (2%)
[^6]: [Applying Apple HDR effect to your photos](https://developer.apple.com/documentation/appkit/applying-apple-hdr-effect-to-your-photos) (2%)
[^7]: [HEIC Inspector: Depth Maps, Gain Maps, Items — heic.fyi](https://heic.fyi/heic-inspector) (13%)
[^8]: [heic/CHANGELOG.md at main - imazen](https://github.com/imazen/heic/blob/main/CHANGELOG.md) (1%)

---

**You**

can i just add a gain map to a 10-bit sdr heic and have a heic that is 10-bit base + 8-bit gain map?

---

**Assistant**

I'll check the actual constraints in the standards and in the shipping tooling before answering, because "legal per spec" and "works in practice" diverge sharply here.## Verdict

**Legally, yes. Practically, it isn't an "add" — and the compatibility argument that motivates gain maps mostly evaporates.**

Nothing in the gain-map machinery requires the base to be 8-bit or to be SDR. The `tmap` derived item simply references a base image and a gain map; `dimg` identifies the inputs, and the base is whatever you coded [^1] [^1]. A 10-bit SDR base is just a base whose HDR headroom is 1.0. Real tooling ships exactly your configuration: `HDR2gainmap` writes a **10-bit `RGB10` Display P3 HEIC base with an embedded gain map**, generated through Core Image, plus Maker Apple keys 33/48 carrying the clamped headroom [^2]. libheif's `tmap` writer goes further and hardcodes the encoded bit depth to 10 bits [^3] — so a 10-bit base is arguably the *native* case there, not the exotic one.

## Why you can't just append the gain map

A HEIC gain map isn't a trailing chunk like an APP segment. There are two bindings, and both live entirely in `meta`:

| | ISO 21496-1 (`tmap`) | Apple legacy aux |
|---|---|---|
| Primary item | the `tmap` derived item | the base image |
| Ref from gain map → base | `dimg` | `auxl` |
| Metadata | `tmap` item property (nclx only, no ICC, in libheif's implementation) [^3] | XMP `HDRGainMapHeadroom`, or Maker Apple keys 33/48 [^2] |
| SDR fallback | `altr` entity group — unaware readers pick the base [^1] | implicit: `pitm` already points at the base |

So the surgery is: new `infe` entries in `iinf`, a `dimg`/`auxl` entry in `iref`, `auxC` + `ispe` + `colr` + `pixi` in `ipco` with `ipma` associations (or a `tmap` property), amended `iloc` offsets, a changed/added `pitm`, and an `altr` group. `ftyp` compatible brands may need `miaf`. Appending the gain map's HEVC bitstream to `mdat` is the trivial part; growing `meta` shifts every `iloc` offset if `meta` precedes `mdat`, which it always does in practice. In other words: it's a full rewrap, not a patch. And there's no CLI that adds a gain map to an existing file — `heif-enc` re-encodes; libheif's gain-map API is behind `-DWITH_EXPERIMENTAL_GAIN_MAP=1` and takes you through a decode/encode cycle [^3].

## Apple's stack does accept the combination — inconsistently

The workable Apple path is: encode a throwaway HEIC from (SDR base + HDR) so Core Image **generates** the gain map for you, extract it as an auxiliary image, then write the final 10-bit HEIC with base + explicit gain map + headroom metadata [^2]. But the tool that does this has to *verify* the output and fall back, because `writeHEIFRepresentation` and `writeHEIF10Representation` don't behave the same across machines and OS versions — on macOS 15.x the `heif` strategy works and `heif10` fails; other builds reportedly invert that [^2] [^2]. That is your real risk: the encoder may silently drop the auxiliary image, which is why verification (Adobe's Gain Map Demo App, or a box-level check) is mandatory rather than optional.

Writing goes through `CGImageDestinationAddAuxiliaryDataInfo` with `kCGImageAuxiliaryDataTypeISOGainMap` [^4]. Reading it back is worse: `CGImageSourceCopyAuxiliaryDataInfoAtIndex` can return the three keys but omit `kCGImageAuxiliaryDataInfoData` entirely, logging `Unsupported AuxiliaryData format '420f'` — the workaround is `CIImage(contentsOf:options:[.auxiliaryHDRGainMap: true])` [^4]. So round-tripping your own file through ImageIO may fail even when the file is fine.

## What actually breaks

- **SDR fallback stops being a fallback.** The whole point of base+gain map is that ancient viewers display the base. A 10-bit base is Main 10 / `heix`-family; decoders that only do 8-bit HEVC refuse the file outright rather than showing an SDR rendition. You've traded "degrades gracefully" for "needs a newer decoder anyway" — and those newer decoders are precisely the ones that could have handled a real PQ file.
- **Headroom signalling is undocumented on the Apple path.** Maker Apple keys 33/48 are reverse-engineered, not specified [^2]; the documented Apple gain map is an 8-bit single-channel map with XMP headroom [^5]. That's a metadata contract you're maintaining by hand.
- **Precision doesn't improve where it counts.** The gain map is the HDR bottleneck, not the base: an 8-bit, usually quarter-resolution, single-channel multiplier still quantises the highlight reconstruction. A 10-bit base buys you clean gradients and less banding *in the SDR rendition*, and slightly less error when the gain is large — not a better HDR image than 8-bit base + 8-bit gain map of the same headroom.
- **~25% larger files** for the 10-bit HEVC base, on top of the gain map.

## What I'd actually do

| Goal | Best container |
|---|---|
| HDR with graceful SDR fallback, maximum reach | 8-bit Display P3 base + gain map (what iPhones ship) |
| 10-bit SDR quality *and* HDR, standards-clean | 10-bit base + **`tmap`** (ISO 21496-1), with `altr` so ignorant readers take the base — not the legacy Apple aux URN |
| HDR end-to-end, no fallback needed | 10-bit PQ/HLG HEIC, no gain map at all — simplest file, one image |

If your source is already a 10-bit SDR render and you want HDR highlights, the `tmap` route is defensible and matches how libheif emits it (base at 10 bits, nclx only — no ICC, so plan for BT.2020/P3 `nclx` signalling) [^3]. If your source is an 8-bit SDR image, adding a gain map on a 10-bit base is pure overhead: re-encoding an 8-bit base to 10 bits invents no information, and the gain map you'd attach was derived from that same 8-bit base anyway.

**References**

[^1]: [HEIF Technical Information - High Efficiency Image File Format](https://nokiatech.github.io/heif/technical.html) (14%)
[^2]: [vastunghia/HDR2gainmap GitHub Repo](https://github.com/vastunghia/HDR2gainmap) (29%)
[^3]: [Add support for handling 'tmap' items by ram-mohan · Pull Request #1503 · strukturag/libheif · GitHub](https://github.com/strukturag/libheif/pull/1503) (29%)
[^4]: [Pitfalls and workarounds when dealing with RGB HDR Gain Map using ImageIO](https://juniperphoton.substack.com/p/pitfalls-and-workarounds-when-dealing) (23%)
[^5]: [Applying Apple HDR effect to your photos](https://developer.apple.com/documentation/appkit/applying-apple-hdr-effect-to-your-photos) (6%)

---

