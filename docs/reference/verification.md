---
type: reference
owner: docs
updated: 2026-11-07
---

# Container Verification

## Verifying the container — ImageIO only

- Gate on `kCGImageAuxiliaryDataTypeISOGainMap`. A plain SDR HEIC also "succeeds" `DecodeToHDR`
  (8 bpc, headroom 1.0), so success alone is not proof of HDR.
- `contentHeadroom` on the **HDR** decode is the authoritative advertised headroom.
  `calculatedContentHeadroom` is pixel-derived (+0.02…+0.14 on the M0 control files, +0.245 on the
  delivered trial file) and on an SDR decode it is not a headroom at all — report it as a cross-check only.
- A pure SDR P3 image renders at peak **1.14–1.19** in extended linear P3 (ColorSync overshoot), so
  "fraction of samples > 1.0" is not "authored above white". The useful ratio is
  `hdrDecode peak / sdrDecode peak`.
- `fixtures/media/reference/IMG_7097.HEIC` is a positive control: it carries both an ISO aux (mono `L008`,
  2016×1512, `AlternateHeadroom` 2.46875 → 5.5356×) and an Apple `HDRGainMap` aux.
- `tools/verify-heic` (`build.sh`; usage below) makes the ImageIO assertion in one call (ISO
  aux, headroom, alpha, dimensions, base drift, JSON report). It is the independent cross-check at
  acceptance — it is deliberately **not** one of the delivery report's checks, which are produced by
  `EngineKit` and unit-tested ([deliver.md](deliver.md)). The 5 % headroom match is a **gate** in the
  delivery report too (ADR-0012 reclaimed the ADR-0011 warning); `verify-heic` keeps its own strict,
  independent assertion of the same match.
- Exit codes are not evidence: the external oracle exits 0 on several failure modes
  ([encoder.md](encoder.md)); the v2 writer throws, but every acceptance run still asserts the aux
  item, the headroom and the dimensions.

## verify-heic: usage

```bash
verify-heic <file.heic> [--base <sdr.tif>] [--expect-headroom <linear-float>] \
    [--expect-bit-depth <8|10>] [--expect-map-resolution <half|full>] \
    [--expect-orientation <int>] [--out <report.json>]
```

| example | what it exercises |
|---|---|
| `verify-heic out.heic` | container, aux, SDR/HDR decode, alpha, fallback, bit depth, map resolution, orientation |
| `verify-heic out.heic --expect-headroom 2.5` | adds the headroom ≤5 % check |
| `verify-heic out.heic --expect-bit-depth 10 --expect-map-resolution half --expect-orientation 1` | pins the base bit depth, gain-map resolution and orientation tag |
| `verify-heic out.heic --base sdr.tif --expect-headroom 2.5 --out out.verify.json` | full acceptance-style verification incl. base preservation |

```bash
# acceptance-style call
tools/verify-heic/bin/verify-heic \
    out/R0003777-P3-hdr-10-half-rgb.heic \
    --base work/<source sha>/sdr.tif \
    --expect-headroom 2.5 \
    --out /tmp/verify.json
```

`--base` accepts any ImageIO-readable image (TIFF/PNG/HEIC/JPEG). It is compared
pixel-for-pixel against the HEIC SDR decode in the same 8-bit Display P3 bitmap.

## Checks

| check | pass condition | when |
|---|---|---|
| `heifContainer` | input is an ISO BMFF/HEIF container (HEIC brands) | always |
| `isoAuxPresent` | `kCGImageAuxiliaryDataTypeISOGainMap` exists | always |
| `baseBitDepth` | `properties.depth` is 8 or 10 (or equals `--expect-bit-depth`) | always |
| `gainMapResolution` | ISO aux dims are **full** (== SDR decode) or **half** (`\|2*aux - base\| <= 2` per axis), or equal `--expect-map-resolution`; fails when the ISO aux is absent | always |
| `metadataOrientation` | EXIF dictionary and orientation tag exist, and equal `--expect-orientation` when supplied | always |
| `dimsMatch` | SDR decode dims == `--base` dims (else primary-image props) | always |
| `noAlpha` | SDR **and** HDR decodes have no alpha channel | always |
| `hdrDecodeSucceeded` | `kCGImageSourceDecodeToHDR` returns an image | always |
| `headroomWithin5pct` | measured headroom within 5 % of `--expect-headroom` (strict here; the delivery report gates the same 5 % match — ADR-0012) | only with `--expect-headroom` |
| `basePreserved` | mode-aware: **uniform** base → meanAbsDiff == 0, maxAbsDiff == 0, decoded variance == 0 (strict); **photo** base → \|meanSignedDiff\| ≤ 0.5, meanAbsDiff ≤ 2.5, absDiffP99 ≤ 16 | only with `--base` |
| `sdrFallbackPresent` | plain decode (no HDR request) succeeds with non-zero dims | always |

`basePreserved` renders both images to 8-bit Display P3 via `CIContext` and
reports per-channel `meanAbsDiff` / `meanSignedDiff` / `maxAbsDiff` /
`fractionNonZero`, p50/p90/p99/p99.9/max absolute-difference percentiles, a diff
histogram, and the variance of both the supplied base and the decoded HEIC base.
The pass rule is **auto-detected from the supplied base**, and the verdict is
self-describing in the JSON (`baseCheck.baseMode`, `baseCheck.baseThresholds`,
and the same fields inside `checks.basePreserved`):

- **`uniform`** (supplied base variance == 0, e.g. the M0 synthetic grey base):
  stays pixel-strict — `meanAbsDiff == 0`, `maxAbsDiff == 0`, decoded-base
  variance `== 0`. This is the M0 synthetic assertion; do not relax it.
- **`photo`** (real image): 8-bit 4:2:0 HEVC cannot preserve per-pixel maxima at
  sharp coloured edges, so the pass rule is distribution-based — no tone-curve
  drift (`|meanSignedDiff| <= 0.5`), small mean error (`meanAbsDiff <= 2.5`), and
  `absDiffP99 <= 16`. p99.9 and `maxAbsDiff` are reported as diagnostics only;
  they are never pass conditions.

The LSB stats answer "did the base drift / get re-graded?". The delivery report
adds ΔE2000 (see [deliver.md](deliver.md), `baseDeltaE`) for colour accuracy; that is a
different question and a different metric, not a replacement for these drift
checks.

Exit codes: `0` = overall pass; `1` = any failure, including usage errors
(`0` iff overall pass, as specified).

## Report JSON

Deterministic except for `tool.generatedAt`; pretty-printed, sorted keys.
Top-level keys:

- `tool` — name/version, host OS, parsed arguments.
- `file` — path, `sizeBytes`, `sha256`, ImageIO type, image count.
- `container` — bytes-parsed `ftyp` (major brand, minor version, compatible
  brands), `isISOBaseMedia`, `inputIsHEIF`, top-level boxes, `itemCount` +
  `infeCount` (from `meta/iinf/infe`), `primaryItemID` (from `pitm`),
  `itemTypeCounts`, `tmapItemPresent`, `tmapBrandPresent`.
- `primaryImage` — width/height/depth/colorModel/profileName/isFloat/orientation
  from ImageIO properties plus decoded bps/bpp/alphaInfo/hasAlpha.
- `sdrDecode` — dims, bps, bpp, color space name, `contentHeadroom`,
  `calculatedContentHeadroom`, alpha info, isFloat, and the same `measured`
  signal block as `hdrDecode` (the SDR baseline: saturated P3 colours can measure
  peak > 1.0 here without any HDR, see below).
- `aux` — `isoGainMap` and `hdrGainMap` objects: presence, `infoKeys`, raw data
  size/prefix, data description (pixel format decoded to fourCC, width/height/
  bytesPerRow), color space description/name, and a **generic recursive walk** of
  the `CGImageMetadata` tags (`metadata.tags`) plus a headroom summary
  (`metadata.gainMap`: `AlternateHeadroom`/`BaseHeadroom` raw + linear, per-channel
  `GainMapMax`/`GainMapMin`/`Gamma`/offsets, `BaseColorIsWorkingColor`,
  `channelCount`). Convenience: `aux.isoAuxLinearHeadroom`,
  `aux.hdrGainMapLinearHeadroom`, `aux.*.dataOmittedByImageIO`.
- `imageMetadata` — image-level metadata tags (headroom-related ones filtered into
  `headroomTags`).
- `hdrDecode` — `success`, error string on failure, dims, bps, bpp, color space,
  `contentHeadroom`, `calculatedContentHeadroom`, `isHDRContent`, and the measured
  signal: `peak`, `mean`, `fractionAboveOne`, `fractionAboveCap` (with
  `--expect-headroom`), `fractionAboveContentHeadroom`, `peakOverSdrPeak`,
  `nanCount`.
- `baseCheck` — availability/reason, base source info, `baseMode`
  (`uniform`/`photo`) and `baseThresholds` (pass rule + numeric limits +
  `diagnosticsOnly`), per-channel and overall diff stats (`meanAbsDiff`,
  `meanSignedDiff`, `maxAbsDiff`, `fractionNonZero`), `percentiles`
  (`p50`/`p90`/`p99`/`p99_9`/`max`), `diffHistogram`, `fractionAboveTwo`,
  `baseUniform`, variance of the supplied base and of the decoded HEIC base,
  `alphaNote` when alpha differs.
- `checks` — every applicable check as `{pass, detail, ...thresholds/values}`.
- `overall` — `pass`, counts, sorted `failures`, `skippedChecks`.

Measurement details: the HDR signal is rendered with
`CIContext.render(..., format: .RGBAf, colorSpace: extendedLinearDisplayP3)` in
256-row strips (bounded memory on 24 MP files); `peak`/`mean`/fractions are over
RGB samples, alpha excluded.

## ImageIO observations the pipeline relies on

- `kCGImageSourceDecodeToHDR` returns **10 bpc / 32 bpp** for ISO tmap HEICs and
  **16 bpc** for some tool-generated variants; the decoded `CGImage.colorSpace`
  is **nil** — do not rely on it, read `contentHeadroom` instead.
- `CGImage.contentHeadroom` for these files equals `2^HDRToneMap:AlternateHeadroom`
  (e.g. 3.9844 for AlternateHeadroom 1.994353); `calculatedContentHeadroom`
  (macOS 26) is pixel-derived and slightly higher/different (4.0029 there).
  For the **SDR** decode `calculatedContentHeadroom` is not a headroom at all
  (it reports ~0.50 for a mid-grey base) — only trust `contentHeadroom` on the
  HDR decode.
- On ISO tmap files written by the encoder, `CGImageSourceCopyAuxiliaryDataInfoAtIndex`
  returns the metadata/data-description/colour-space keys but **omits
  `kCGImageAuxiliaryDataInfoData`** for the `'420f'` map (ImageIO logs
  "Unsupported AuxiliaryData format '420f'"). The aux is still real: trust the
  metadata + successful `DecodeToHDR`. `IMG_7097.HEIC`'s `L008` map does return data.
- Plain SDR HEICs still "succeed" at `DecodeToHDR`, returning the SDR image at
  headroom 1.0 — use `isHDRContent`/`isoAuxPresent`, not just `success`.
- The measured signal is a **relative** measurement. Rendering pure 8-bit SDR
  Display P3 through ColorSync to extended linear P3 overshoots white for
  saturated colours (an ordinary SDR photo measured peak ≈ 1.19 on this machine;
  a plain SDR test HEIC ≈ 1.14). So `fractionAboveOne` is not "authored above
  white" on its own, and rendered `peak` can exceed `contentHeadroom` (real M0
  file: contentHeadroom 2.5, measured peak 2.92, SDR baseline 1.19 →
  `peakOverSdrPeak` 2.45). Use `contentHeadroom`/`AlternateHeadroom` as the
  headroom truth; use `measured` to compare SDR vs HDR and to find clipping.
- ImageIO also exposes ISO gain-map aux data for **Apple JPEG gain maps**
  (`fixtures/media/reference/IMG_7473.JPG`), which is why `verify-heic` additionally
  asserts the HEIF container: verify the delivered bytes, not just the pixels.

## Relation to the app

This tool is the independent ImageIO cross-check; `EngineKit` implements its own
checks and the delivery report is the gate ([deliver.md](deliver.md)). Keep this tool's
report schema stable — the acceptance runs used it to cross-check the
installed delivery.
