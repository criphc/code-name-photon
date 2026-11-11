---
type: reference
owner: docs
updated: 2026-11-09
---

# Encoder

## The writer — in-process Core Image/ImageIO

`EngineKit.CoreImageHEICEncoder` is the only container writer (ADR-0012). It implements the
`HEICEncoder` protocol and consumes the already-rendered images, never the source or the grade:

- `HEICEncodeRequest`: `sdrBase` + `hdrRendition` (`LinearImage`), `authoredPeak`,
  `HEICEncodeOptions`, the source URL (metadata only, `nil` skips the rewrap), and the output URLs.
  `sdrOutputURL` is `nil` for every profile after the first: the 8-bit fallback is written once per
  delivery.
- `HEICEncodeResult`: the ImageIO read-back `facts`, the gain map's width/height/kind, and per-step
  timings (gain map, encode, rewrap, fallback, total).

Path A is the verified call:

```swift
CIContext.writeHEIF10Representation(of:to:colorSpace:options:)      // 10-bit base
CIContext.writeHEIFRepresentation(of:to:format:colorSpace:options:) // 8-bit base
// options: .hdrGainMapImage = the map CIImage
//          .hdrGainMapAsRGB = (mapKind == .isoRGB)
//          kCGImageDestinationLossyCompressionQuality = quality
```

- **Path B is not the route.** `CGImageDestinationAddAuxiliaryDataInfo` with a raw RGB8 map and
  `kCGImageAuxiliaryDataTypeISOGainMap` fails `CGImageDestinationFinalize` on macOS 27; changing
  `kCGImagePropertyPixelFormat` (EXIF 2 / fourCC) does not help. Do not build the aux by hand.
- **The base must be 3-sample.** An RGBA `CIImage` makes `writeHEIFRepresentation` write an alpha
  channel, which the `alpha` check rejects; `SDRBaseCGImage.make` / `make8Bit` produce 3-sample
  images.
- **The float bitmap must be provider-backed.** A `CIImage` must own its buffer:
  `CIImage(bitmapData:)` neither copies nor keeps the `Data` alive, so a filter evaluated later can
  read freed memory — the preview path hit exactly this (one run in four decoded 25 % RMSE away with
  a 149× HDR peak; a use-after-free *is* the nondeterminism). Build the image through a `CGImage`
  whose `CGDataProvider` retains the data; the float bitmap needs
  `floatComponents | premultipliedLast | byteOrder32Little` (without `byteOrder32Little` Core Image
  reads float RGBA as zeros). All writers go through `ImageBuffers.swift`/`SDRBaseCGImage`; do not
  add a new `CIImage(bitmapData:)` call.
- **No staging TIFF.** The encoder takes the in-memory `LinearImage`s; the external tool's TIFF
  handoff is gone.

## Profiles

`HEICEncodeOptions` is one output profile: `bitDepth` (8/10), `quality` (0…1), `mapResolution`
(`full`/`half`), `mapKind` (`iso-rgb`/`iso-mono`). The recipe's `encoder` block is the default
profile; field ranges and the v2 defaults (10-bit, half-res, ISO RGB) are documented once in
[recipe.md](recipe.md).

`profileName` is `"{depth}-{resolution}-{rgb|mono}"` (`10-half-rgb`, `8-full-mono`); it is the
report key and the artifact suffix (`{stem}-hdr-10-half-rgb.heic`).

- **8 vs 10-bit is the base only.** 10-bit costs ~25 % more bytes for cleaner SDR gradients; the
  gain map is the precision bottleneck either way.
- **half vs full is the gain map.** `half` averages each 2×2 block before the ratio (Apple's shape,
  base/2); `full` uses every pixel. Half is the default: ~1/4 the map bytes and it passes the
  half-res `previewAgreement` band.
- **iso-rgb vs iso-mono is `.hdrGainMapAsRGB`.** RGB writes `420f`, mono writes `L008`; both carry
  the same ISO `tmap` + ISO aux.

## Gain map

ISO 21496-1: per-channel `log2(HDR / SDR)`, normalised to `[0, log2(authoredPeak)]`, quantised to
8-bit RGB:

```
q = round(clamp(log2(max(hdr/sdr, 1)), 0, maxLogGain) / maxLogGain * 255)
```

- `maxLogGain = log2(authoredPeak)`; the metadata's `GainMapMax` is the same value, so the decoder's
  gain is the authored one.
- Half-res averages the 2×2 block of both images before the ratio; odd edges use the available
  samples.
- CPU, parallel over rows. A Core Image kernel/vImage version is a later optimisation, not a
  correctness requirement.

## Metadata

- **ISO fields:** `MetadataTemplate.isoGainMap(authoredPeak:)` clones
  `Resources/iso-gainmap-template.heic` and sets `HDRToneMap:AlternateHeadroom` and every
  `ChannelMetadata[i].GainMapMax` to `log2(authoredPeak)`, and `GainMapMin` to 0.
- **Source fields:** after the HEIF write, `CGImageDestinationCopyImageSource` copies the encoded
  file (and the 8-bit fallback) and replaces only the image metadata with the filtered source metadata. The gain map and the
  base bit depth survive the rewrap.
- **Filter:** only EXIF, TIFF and GPS tags survive. XMP/IPTC/Photoshop tags are dropped (Capture One
  labels/ratings are editor sidecars, not capture metadata).
- **Orientation:** a TIFF tag, passed through as-is. The decoder assumes 1 and has no rotation
  branch.
- **No source URL:** skip the rewrap and atomically replace the temp file.

## Invariants

- **Display P3 only.** A non-P3 source is `unsupportedSource` at decode; never silently clamp.
- **No alpha.** The base is 3-sample RGB; the `alpha` check reads both the SDR and HDR decodes.
- **Authored peak ≥ 1.05** before encoding; below that there is no headroom to advertise.
- **The recipe cap is the only headroom control.** The cap is applied to the HDR pixels before
  encoding; the writer advertises exactly `log2(authoredPeak)`. Cap range is still 1…8 (3 stops);
  4-stop/16 is not in v2.
- **Read-back gate.** `EncodedHEICValidator.validate` asserts ISO aux present, no alpha, dimensions,
  HDR decode, and returns the facts. A structural failure is `encoderOutputInvalid`, not a report
  check.
- **SDR fallback.** `{stem}-sdr.heic` is an 8-bit HEIC of the same base, no auxiliary data, the same filtered capture metadata, written
  once per delivery by the first profile. It is the file non-HDR viewers see, and every profile
  shares it.
- **Atomic install.** The encoder writes the HDR file to a hidden temp beside the final path; the
  rewrap (or `AtomicFile.replace`) is the only step that creates the final file. The pipeline
  installs the set with `AtomicFile` (temp + `rename(2)`), never remove+move.
- **Determinism.** Same machine + same OS: byte-identical. Across OS: accept pixel-level (base
  bit-exact, HDR decode ΔE 0, metadata equal) and pin the OS in the test.
- **Never judge HDR with `sips`/Finder/Export.** They silently strip the gain map
  ([container.md](container.md)).
- **One writer per output.** Do not run two encodes into the same output directory concurrently.

## Oracle

`tools/toGainMapHDR` is a local, time-boxed differential oracle only (ADR-0012): compare base,
headroom and pixels against the new engine. It is not in CI, not a `make test` prerequisite, and not
a delivery dependency. Legacy recipes with `encoder.tool: "toGainMapHDR"` still decode; new recipes
use `"coreimage"`.

## Wiring

`DeliveryPipeline` depends on the `HEICEncoder` protocol and defaults to `CoreImageHEICEncoder`;
`appctl deliver --encoder PATH` swaps in `ExternalToolEncoder` for the migration oracle. The
pipeline renders the base/HDR once, encodes and verifies once per requested profile, and installs
the set only when every profile passes ([deliver.md](deliver.md)).
