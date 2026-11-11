# M0-A fact sheet — what `toGainMapHDR -b` actually writes

*Task `task-1` / M0 "synthetic base+HDR pair + encoder fact matrix". Generated on macOS 27.2 (M1 Max), macOS 26 SDK, encoder `tools/toGainMapHDR/bin/toGainMapHDR`.*

All numbers below are from this directory (`work/m0/synthetic/`). Raw evidence: `logs/probe.json` (ImageIO facts),
`logs/out-*/{heif-info.txt,heif-info-dump.txt,exiftool.txt,xxd.txt}` (container tool output), `logs/out-*.log`
(encoder stdout/stderr), `report.json` (curated machine-readable version of this file).

---

## 0. What was built

**Input pair (deterministic; `make_pair.swift`; re-running produces identical sha256):**

| file | format | pixels | meaning | sha256 |
|---|---|---|---|---|
| `base.tif` | 16-bit RGB, ICC **Display P3**, 4 719 630 B | 1024×768 | uniform mid-grey, **linear 0.499986** (read-back linear-P3 min=mean=max=0.499986, variance ≈ 0) | `753c6aa0fbc9d190…` |
| `hdr.tif` | 32-bit float RGB, ICC **"Display P3 Linear"**, 12 584 462 B | 1024×768 | horizontal linear ramp **0.021943 → 3.998057** linear P3 (requested peak 4.0) | `a7976a36f23fcfce…` |

Read-back verification inside `make_pair.swift`: base is uniform linear 0.5 (var < 1e-12), HDR peak = **3.998057 > 3.9**, right edge ≈ 4.0 → the float/HDR values survived the TIFF round-trip. Authored-peak intent: **4.0 linear**.

**Encoder runs** (each into its own pre-created `out-*` dir; output file is always `<dir>/hdr.heic`; exit code 0 for all):

```bash
toGainMapHDR hdr.tif out-b-r25   -b base.tif -R 2.5 -d 8 -q 0.85 -c p3
toGainMapHDR hdr.tif out-b-r15   -b base.tif -R 1.5 -d 8 -q 0.85 -c p3
toGainMapHDR hdr.tif out-b-r6    -b base.tif -R 6   -d 8 -q 0.85 -c p3
toGainMapHDR hdr.tif out-nob-r25   -R 2.5 -d 8 -q 0.85 -c p3      # no -b
toGainMapHDR hdr.tif out-b-r25-H -b base.tif -R 2.5 -d 8 -q 0.85 -c p3 -H
```

Stdout/stderr: empty for the three `-b` runs; `out-nob-r25` and `out-b-r25-H` print
`Warning: Picture headroom > max headroom (set with -R parameter), highlight clipped.`

### Matrix at a glance

| run | `-R` | bytes | sha256 (12) | gain-map dims | AlternateHeadroom *(stops)* | contentHeadroom *(HDR decode, ×)* | calculatedContentHeadroom | decoded HDR peak *(linear P3)* | SDR alpha | base depth |
|---|---|---|---|---|---|---|---|---|---|---|
| `out-b-r25` | 2.5 | **4203** | `8d010ca497e2` | 1024×768 | **1.994353** | **3.984374** | 4.002930 | **4.002966** | **no** | 8 |
| `out-b-r15` | 1.5 | 4203 | `8d010ca497e2` | 1024×768 | 1.994353 | 3.984374 | 4.002930 | 4.002966 | no | 8 |
| `out-b-r6` | 6 | 4203 | `8d010ca497e2` | 1024×768 | 1.994353 | 3.984374 | 4.002930 | 4.002966 | no | 8 |
| `out-nob-r25` | 2.5 | 5817 | `58e0113805cb` | 1024×768 | 1.994353 | 3.984374 | 3.984375 | 3.984408 | **YES** | 8 |
| `out-b-r25-H` | 2.5 | **3055** | `adbb1a14d7ec` | **512×384** | **2.300450** | **4.926114** | **2.013672** | **2.014133** | no | 8 |

The three `-b` runs are **byte-for-byte identical** (same sha256, same size, same metadata).

---

## Q1. Does `-R` cap the advertised headroom in the `-b` path?

**No. `-R` is completely ignored when `-b` is used without `-H`.** Runs (a) `-R 2.5`, (b) `-R 1.5` and
(c) `-R 6` produce **byte-identical files** (sha256 `8d010ca497e2…` for all three) with identical
`AlternateHeadroom` (1.994353), `contentHeadroom` (3.984374) and decoded pixels (peak 4.002966).

What the metadata actually encodes:

- `2^AlternateHeadroom = contentHeadroom = 3.984374` in **all** `-b` runs (1.994353 stops).
- `AlternateHeadroom = GainMapMax + log2(base pixel linear value) = 2.994354 + log2(0.5) = 1.994354`, i.e.
  `AlternateHeadroom = log2(peak reconstructed HDR linear value)` where reconstructed peak =
  `0.5 × 2^2.994354 = 3.9844`.
- vs the **authored 4.0 peak**: `log2(3.998057) = 1.999300` stops. The advertised value is **0.004947 stop
  lower**, entirely explained by 8-bit gain-map quantisation (`GainMapMax = 2.994354` instead of exactly 3.0).
- `BaseHeadroom = 0.000000`, `GainMapMin = -3.794207`, `Gamma = 1.000000`, `BaseOffset = AlternateOffset = 0.000010`.

So in the `-b` path the advertised headroom is **derived by Core Image from the actual HDR↔base ratio**
(≈ `log2(authored peak)` when the SDR base reaches white under the highlight; with this mid-grey base it is
`log2(base × ratio)`), and there is **no CLI headroom control**. This contradicts docs/03 §3's sentence
"with `-b` the tool skips its own headroom analysis, so `-R` is the only headroom control" — the source
(`tools/toGainMapHDR/toGainMapHDR/main.swift`) confirms why: the headroom analysis block is skipped when
`baseImageBool && !subsamplingBool`, and the `-b` export branch is
`ctx.writeHEIFRepresentation(of: base, options: [.hdrImage: hdrImage, .hdrGainMapAsRGB: true])`
(Core Image writes `HDRToneMap` itself); `maxHeadroom` (`-R`) and `toneMappingRatio` (`-r`) are only consumed
by the SDR-base tone-map fallback.

**`-H` is the exception that proves the rule:** it re-enables headroom analysis, but its `AlternateHeadroom`
is **hard-coded `2.300450`** in the tool (`Metadata.swift` → `defaultHDRMetadata()`), independent of `-R` and
of content. Its `GainMapMax = log2(absolute HDR peak) = 1.999295`. See Q6/Q7 — that metadata is wrong.

**M1 consequence:** "headroom cap" must be enforced by clamping the **HDR rendition pixels** before encoding.
`-R` cannot be used to cap delivery headroom; it will silently do nothing in the `-b` path.

---

## Q2. Is the supplied base preserved exactly?

**Yes — bit-exactly, for every `-b` run including `-H`.** The HEIC SDR base decoded and the supplied
`base.tif` rendered into 8-bit Display P3 are pixel-identical:

- per-channel `meanAbsDiff = 0.0`, `maxAbsDiff = 0.0`, `pixelsDiffering = 0 / 786432` (R, G, B).
- decoded uniform base: **188 / 188 / 188** in all pixels, spatial **variance = 0** exactly (8-bit P3 and
  linear-P3, both ≈ 0).
- the base is 8-bit `noneSkipLast` (opaque) — no alpha, see Q3.

The tool does not re-tone-map or colour-convert the supplied base beyond tagging/encode; the HEVC encode of a
flat plane is lossless in value terms at q=0.85 here.

---

## Q3. Alpha channel? Base bit depth?

| path | alpha (SDR base) | alpha in `DecodeToHDR` | base bit depth |
|---|---|---|---|
| `-b` (a, b, c) | **no** (`CGImageAlphaInfo` raw 5 = `noneSkipLast`; `heif-info`: alpha channel: no) | no (raw 6 = `noneSkipFirst`) | **8** (YCbCr 4:2:0, 8 bpc, CGImage 32 bpp) |
| `-b -H` (e) | **no** | no | 8 |
| no `-b` (d) | **YES** (raw 3 = `last`; `heif-info`: alpha channel: yes; an `auxid:1` aux item appears) | **yes**, and the result is 16 bpc / 64 bpp | 8 (base item is still Main Still Picture 8-bit) |

So: **the delivered `-b` file has no alpha and an 8-bit base** — exactly what doc 04 decision 5 asks for.
The no-`-b` control is *not* deliverable-safe on alpha alone.

Also note the gain-map item itself: `ImageIO` aux `kCGImageAuxiliaryDataInfoDataDescription` says
`PixelFormat = 875704422` = FourCC **`420f`** (8-bit 4:2:0 full-range), full base resolution 1024×768
(512×384 with `-H`).

---

## Q4. Brands / dialect — ISO 21496-1 `tmap`? Any Apple aux item?

**ISO 21496-1 `tmap`, no Apple auxiliary item.**

- `ftyp` bytes: `…66747970 68656963 00000000 6d696631 746d6170 6d696166 4d694842 68656963` →
  major brand **`heic`**, compatible brands **`mif1, tmap, miaf, MiHB, heic`**
  (no-`-b` control adds **`MiHE`**: `mif1, tmap, MiHE, miaf, MiHB, heic`).
- The `meta` box contains an `infe` item with `item_type = tmap`; item references (`heif-info -d`):
  `dimg` base grid item id 5 → tiles 1..4, `dimg` gain-map item id 10 → tiles 6..9, and
  `tmap` item 11 → `[5, 10]`. With `-H`: `tmap` item 8 → `[5, 7]` (gain map item 7 is a single 512×384 item).
- `kCGImageAuxiliaryDataTypeISOGainMap` is **present** for all five outputs;
  `kCGImageAuxiliaryDataTypeHDRGainMap` (legacy Apple) returns **nil for all five** — no Apple `auxC` URN,
  no XMP `HDRGainMapHeadroom` item. `exiftool` shows no `HDRGainMap` metadata, only the ISO `tmap`/`HDRToneMap` route.

---

## Q5. ICC vs `nclx` colour signalling — base vs map

> **Asymmetric, as docs/03 §4 predicted.** The base is ICC-tagged; the gain map is `nclx`-signalled only.

- **Base item:** `colr` type **`prof`** — a 536-byte Apple **Display P3** ICC profile (heif-info:
  `color profile: prof`; exiftool `ICC_Profile: Profile Description = Display P3`). An additional `nclx`
  property is present with `colour_primaries = 2` (unspecified), `transfer_characteristics = 2` (unspecified),
  `matrix_coefficients = 6` (BT.601), full range.
- **Gain-map item, `-b` path:** `nclx` **`colour_primaries = 12` (SMPTE EG 432-1 = Display P3)**,
  **`transfer_characteristics = 16` (SMPTE ST 2084 PQ)**, matrix 6, full range. No ICC on the map.
  ImageIO reports the aux colour space as `ICCBased Display P3 + SMPTE ST 2084 PQ`.
- **Gain-map item, `-H` path:** `nclx` primaries 12, **transfer = 13 (sRGB/sYCC)**, matrix 6 — a different
  dialect for the same tool, and `ImageIO` reports the aux colour space as `ICCBased Display P3` (no PQ).
- All outputs: decoded SDR base CGImage colour space = `kCGColorSpaceDisplayP3`, profile name `Display P3`.

---

## Q6. Does `DecodeToHDR` succeed, and at what headroom?

**Yes on all five outputs** (options `[kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR]`):

| run | success | bpc/bpp | contentHeadroom | calculatedContentHeadroom | decoded peak linear | authored peak |
|---|---|---|---|---|---|---|
| `out-b-r25` / `-r15` / `-r6` | ✅ | 10 / 32 | **3.984374** (=1.994353 stops) | 4.002930 | **4.002966** | 3.998057 |
| `out-nob-r25` | ✅ | 16 / 64 (alpha) | 3.984374 | 3.984375 | 3.984408 | 3.998057 |
| `out-b-r25-H` | ✅ | 10 / 32 | **4.926114** (=2.300450 stops) | **2.013672** | **2.014133** | 3.998057 |

- `-b` runs: the decode returns 10-bit HDR at the advertised headroom, and the reconstructed peak matches the
  authored 4.0 peak to **0.12 %** (4.002966 vs 3.998057). `contentHeadroom` and the independent
  `calculatedContentHeadroom` agree to 0.46 %.
- Whole-image HDR fidelity vs the authored ramp (R channel, linear P3): `meanAbsDiff = 0.013791`,
  `maxAbsDiff = 0.060969`. The error is concentrated below base level (see notes) — decoded
  x=0: 0.0361 vs authored 0.0219 (the gain map's negative range bottoms out at `GainMapMin = -3.794207`,
  ratio 0.0723); above base, samples are within ~1 % (x=512: 2.0326 vs 2.0119; x=1023: 4.0030 vs 3.9981).
- `-H`: the decode succeeds and *reports* 4.926× headroom, but the actual content only reaches **2.014×**
  (`calculatedContentHeadroom` = 2.0137 agrees with the pixels). **`contentHeadroom` over-promises by 2.45×**,
  and the authored 4.0 peak is **halved to 2.014 (50.4 % of authored)** — explained in Q7.
- The no-`-b` control decodes at 16 bpc because the file carries alpha; don't use it as a reference.

---

## Q7. File sizes and the `-H` effect

| run | bytes | vs full map | gain map | notes |
|---|---|---|---|---|
| `out-b-r25` (a) | 4203 | — | 1024×768, 8-bit `420f` | canonical full-res RGB map |
| `out-b-r15` (b) | 4203 | 0 % | 1024×768 | **identical bytes to (a)** |
| `out-b-r6` (c) | 4203 | 0 % | 1024×768 | **identical bytes to (a)** |
| `out-nob-r25` (d) | 5817 | +38.4 % | 1024×768 | extra alpha item + more base detail |
| `out-b-r25-H` (e) | **3055** | **−27.3 %** | **512×384** | half-size map, but see caveats |

`-H` is **not only a size choice — it switches the writer path** (Core Image adaptive writer → manual
`CGImageDestinationAddAuxiliaryImage` + hand-written XMP). Observed side effects, all verified:

1. gain map 1024×768 → **512×384**; file −27.3 %; base still preserved **exactly** (0 diff, Q2).
2. `AlternateHeadroom` becomes the **hard-coded 2.300450** (→ `contentHeadroom` 4.926114), while the actual
   content peak is 2.014 (`calculatedContentHeadroom` 2.013672). Metadata is wrong by 2.45×.
3. **The authored highlight peak is clipped.** The `-H` branch normalises the gain by the *absolute* HDR peak
   (`GainMapMax = log2(picHeadroom) = log2(3.998) = 1.999295`) instead of the HDR↔base ratio. With the base at
   linear 0.5 the true ratio at the peak is 8× (3 stops) ⇒ normalised gain 1.5 ⇒ clamped to 1.0 ⇒
   reconstructed peak = `0.5 × 2^1.9993 = 2.0` instead of 4.0. Any HDR pixel more than
   `2^GainMapMax` times brighter than the base pixel beneath it is clipped by `-H`.
4. colour signalling of the map changes (`nclx` transfer 16/PQ → 13/sRGB) and a `clli` property appears
   (`MaxCLL=203, MaxFALL=64`); the Exif item shrinks 102 → 60 bytes (base written via `CGImageDestinationAddImage`).

**M1 preview decision:** don't use `-H` for the preview either — the preview would advertise 4.93× headroom
and clip at 2.0×, so the iPad would judge a different image than the delivered one. Full-res maps are cheap
here (4 KB for a 1024×768 pair); at 2560 px they stay small.

---

## Surprises / things M1 must know

1. **`-R` is a no-op with `-b`** (byte-identical outputs). Headroom is authored by the HDR rendition, not by a
   CLI flag. Any "headroom cap" slider must be applied to the HDR pixels. This invalidates the doc 03 §3 claim
   that `-R` is "the only headroom control" with `-b`.
2. **The advertised headroom is content-derived and slightly conservative:** 1.994353 stops vs
   `log2(4.0) = 2.0` — a −0.004947 stop offset from 8-bit gain-map quantisation. M4 assertions should allow
   ~0.01 stop / 0.5 % tolerance against the authored peak, not require exact `log2(peak)`.
3. **`-H` breaks headroom metadata (hard-coded 2.300450) and clips highlights** in the same run. Treat it as a
   different encoder, not a quality knob.
4. **`-b` output has no alpha and an 8-bit P3 ICC base** — meets doc 04 decision 5. **No `-b` introduces alpha**
   (plus a 16 bpc HDR decode and a `MiHE` brand), so the Capture-One-base pipeline must always pass `-b`.
5. **Reproducibility is exact:** identical command ⇒ identical sha256; the pair generator is deterministic.
6. **Negative gain range exists but is limited** (`GainMapMin = -3.794207`, ratio floor 0.0723): HDR pixels darker
   than ~7.2 % of the base are not representable. Irrelevant for the real pipeline (HDR = base + lift ≥ base),
   but it is why the synthetic ramp's dark end shows a 0.014 absolute error.
7. **Base's own `calculatedContentHeadroom` is 0.501953 on plain SDR decode** (base peak is linear 0.5, i.e.
   mid-grey). Don't assert "SDR decode headroom ≥ 1" in M4 — assert `contentHeadroom == 1.0` and compare pixels.

## Caveats

- One synthetic pair, one 1024×768 size, `-q 0.85`, `-d 8`, `-c p3`. File sizes/timings will differ for real
  photographs; the *relationships* (Q1/Q2/Q4/Q5) are container-level and should hold.
- The base is uniform mid-grey, so the HDR ramp deliberately crosses below base level. That is useful for
  testing negative gain, but it means the `-H` clipping in Q7 is driven by ratio 8 (base 0.5) — a real
  SDR base that reaches 1.0 under the highlights would see ratio ~headroom and clip less. The hard-coded
  `AlternateHeadroom` and the metadata/content mismatch are independent of the pair and will still be wrong.
- `sips` was used for nothing: all HDR/aux judgments come from ImageIO + `heif-info`/`exiftool` + raw bytes
  (task rule; also doc 03 §2 — `sips` strips gain maps).

## Reproduce

```bash
cd work/m0/synthetic
export TMPDIR="$PWD/.tmp"
swift -module-cache-path "$PWD/.mc" make_pair.swift "$PWD"
mkdir -p out-b-r25 out-b-r15 out-b-r6 out-nob-r25 out-b-r25-H
TOOL=../../../tools/toGainMapHDR/bin/toGainMapHDR
# … run the five commands listed in §0, capturing each > logs/<run>.log 2>&1
swift -module-cache-path "$PWD/.mc" probe.swift > logs/probe.txt   # also writes logs/probe.json
```

`probe.swift` is the single source of the ImageIO facts; `report.json` is curated from `logs/probe.json`
plus the `logs/out-*.*` tool output.
