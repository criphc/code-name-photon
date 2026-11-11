# M0 — Encoder + Recipe Verification

*Stage 1, milestone M0 · executed 2026-11-02 on macOS 27.2 (M1 Max, Xcode 27.2 / Swift 6.4) · plan: [docs/04](04-stage-1-plan.md) M0 · encoder behaviour: [docs/03](03-considerations-beyond-the-plan.md) §3*

**Verdict: PASS.** The encoder path, the delivered container, the base-preservation contract and recipe v0 are measured and verified, and the actual M0 gate — the file renders in **Photos** and in **Safari via a local page** on the iPad Pro with only the highlights brighter — passes in both viewers. M1 may start.

The measured `-R`/headroom relationship contradicted docs/03 §3 and decision 2 as written; both were corrected as part of this milestone (see §6), so read this note together with the updated docs/03 §3.

---

## 1. Checklist

| M0 item | Result | Evidence |
|---|---|---|
| synthetic base+HDR pair with a known peak (4.0 linear), `-b`, record what the file is | ✅ | §2, §3.1 |
| `DecodeToHDR` succeeds at the expected headroom | ✅ | §3.1, §3.2 |
| decoded SDR base matches the supplied base; zero variance when the base is uniform | ✅ | §3.1 (variance 0, 0/786432 px differ), §3.2 (16-bit pass-through Δ0) |
| repeat on one real pair (`R0003777-P3.tif`, lift bringing out the sun reflections) | ✅ | §3.2 |
| open in Photos and in Safari on the iPad — Safari via a local page | ✅ | §4 |
| delivered file has no alpha channel | ✅ | §2, §3.2 |
| recipe v0 JSON, stored beside the output | ✅ | §5 |

Artifacts live in gitignored `work/m0/` (`synthetic/`, `real/`, `verify/`, `deliverable/`, `recipe/`); the committed, reusable pieces are `tools/verify-heic/` (the verifier) and `tools/m0-fixtures/` (the synthetic pair generator). Encoder: `toGainMapHDR@5dba4e2` (tool git commit, 2026-10-25).

---

## 2. What the delivered file actually is

Measured on `work/m0/real/out/R0003777-M0.heic` (6000×4000, 3,853,079 B) and cross-checked on the synthetic output:

- **Dialect: ISO 21496-1.** `ftyp` major brand `heic`, compatible brands `mif1, tmap, miaf, MiHB, heic`; the `meta` box carries an `infe` item of type `tmap` whose `dimg` references name the base item and the gain-map item. `kCGImageAuxiliaryDataTypeHDRGainMap` (legacy Apple) is **absent** — this is the standards dialect, not the Apple sharing dialect.
- **Base:** 8-bit, YCbCr 4:2:0, tiled (6×7 tiles at 6000×4000), ICC **Display P3** profile (536 B) plus an `nclx` property with unspecified primaries/transfer. Opaque: `alphaInfo = noneSkipLast`, `heif-info` reports `alpha channel: no`.
- **Gain map:** auxiliary item at full base resolution, pixel format `420f` (8-bit 4:2:0 full range), `nclx` primaries 12 (Display P3) / transfer 16 (PQ), no ICC. ImageIO returns its metadata and description but deliberately **omits** `kCGImageAuxiliaryDataInfoData` for `420f` ("Unsupported AuxiliaryData format") — the aux item is still real; assert metadata + `DecodeToHDR`, not the byte payload.
- **ISO headroom metadata:** `HDRToneMap:BaseHeadroom = 0`, `AlternateHeadroom = 1.321928` (= 2.5×), `GainMapMax = 1.399812` stops (the authored lift), `GainMapMin = 0`, `BaseColorIsWorkingColor = true`.
- **ImageIO read-back:** `DecodeToHDR` returns a 10 bpc / 32 bpp image with `contentHeadroom = 2.4999998` (= 1.321928 stops); the plain SDR decode reports headroom 1.0. The container advertises exactly the authored cap.
- **Sizes:** 3.85 MB delivered full-resolution, 883 KB for the 2560×1707 preview (same encoder flags), 2.03 MB for the map-stripped SDR reference. Full-resolution RGB map costs **+89 %** over SDR-only — well under the ~20 MB budget.
- **Timing:** 16.6 s total render+encode (mask/HDR 4.1 s, full encode 1.0 s, read-back verify 1.8 s).

---

## 3. Objective assertions

### 3.1 Synthetic control — a known peak (4.0 linear)

Pair (`tools/m0-fixtures/make-pair.swift`): `base.tif` uniform mid-grey, linear 0.499986, 16-bit Display P3; `hdr.tif` 32-bit float "Display P3 Linear", ramp 0.021943 → 3.998057. Five encoder runs, all exit 0:

| run | `-R` | bytes | `AlternateHeadroom` | `2^alt` = `contentHeadroom` | decoded HDR peak |
|---|---|---|---|---|---|
| `-b`, `-R 2.5` | 2.5 | 4,203 | 1.994353 | 3.984374 | 4.002966 |
| `-b`, `-R 1.5` | 1.5 | 4,203 | 1.994353 | 3.984374 | 4.002966 |
| `-b`, `-R 6` | 6 | 4,203 | 1.994353 | 3.984374 | 4.002966 |
| no `-b` (tool-made base) | 2.5 | 5,817 | 1.994353 | 3.984374 | 3.984408 |
| `-b -H` (half-size map) | 2.5 | 3,055 | **2.300450** | **4.926114** | **2.014133** |

What this settled:

- **`-R` is a no-op in the `-b` path.** The three `-b` runs are **byte-identical** (same sha256, 4,203 B). Core Image derives the map and the advertised headroom from the actual HDR↔base ratio; `AlternateHeadroom ≈ log2(authored peak)` with a −0.005-stop offset from 8-bit gain-map quantisation (1.994353 vs log2(3.998057) = 1.999300). **The headroom cap must be applied to the HDR rendition pixels; no CLI flag does it.**
- **The supplied base is preserved bit-exactly.** Uniform base → decoded SDR `188/188/188`, variance exactly 0, mean/max abs diff 0, 0/786432 px differ.
- **No alpha, 8-bit base** in every `-b` run. The no-`-b` control is the opposite: alpha present, `MiHE` brand, 16 bpc HDR decode — so the Capture One-base pipeline must always pass `-b`.
- **`-H` is a different writer and is broken for delivery.** It hard-codes `AlternateHeadroom = 2.300450` (over-promising 2.45× where the content peaks at 2.01×), normalises the gain to the absolute peak so highlights beyond `2^GainMapMax × base` are clipped (authored 4.0 → 2.01), and switches the map's `nclx` transfer from PQ to sRGB. Do not use it for previews or delivery.
- **Determinism:** identical command ⇒ identical sha256; the pair generator is deterministic too.

### 3.2 Real photograph — `R0003777-P3.tif`

Source: 6000×4000, 16-bit, Display P3, no alpha, sha256 `bd486ca6…6116`. SDR base = `c1_match_v1` identity (no tone curve); HDR = smoothstep mask (start 0.62, transition 0.28) on Rec.709 luma, gain `2^(1.4·m)`, absolute clamp to 2.5 linear.

- **Base contract holds:** `sdr.tif` vs source = **0 / 72,000,000** 16-bit samples differ, max |Δ| = 0.
- **Authored peak exactly 2.5** (1.321928 stops); 10.94 % of pixels > 1.0, 0.431 % at the cap, no NaN; read-back peak 2.5 before encoding.
- **Delivered file:** `AlternateHeadroom = 1.321928` stops → 2.4999998 linear, `contentHeadroom` 2.4999998, `headroomWithin5pct` passes with relative error 9.5e-8.
- **Base still the capture:** delivered 8-bit fallback vs 16-bit source — mean |Δ| 1.475 LSB, signed bias **+0.09** (no tone curve → no drift), p50/p90/p99/p99.9 = 1/3/7/12, isolated max 138 LSB at sharp chroma edges. An independent encode of the same base deviates mean 1.92 / max 95, and the delivered file vs that SDR-only HEIC is mean 0.97 / max 45 — i.e. the whole difference is 8-bit 4:2:0 HEVC loss, not a re-grade. (M4 will add ΔE2000 per docs/03 §5.)
- **HDR fidelity:** decoded HDR vs authored `hdr.tif` — mean |Δ| 0.0062 linear, p99 0.035, p99.9 0.074.
- **Decode-side overshoot (benign):** the SDR fallback itself peaks ~1.19 linear at clipped speculars (8-bit chroma overshoot); multiplied by the max gain, ~0.3 % of decoded samples exceed 2.5 (peak 2.92×) while the container metadata remains exactly 2.5 and the mean matches the authored rendition. Viewers clipping those pixels is expected. Do not use per-pixel maxima as pass criteria.
- **Determinism and timing:** two independent whole-render runs produced byte-identical `sdr.tif`, `hdr.tif` and all three HEICs; 16.6 s total, 1.0 s for the full encode.
- **Verifier:** `tools/verify-heic` reports **8/8 checks PASS**, exit 0 (`work/m0/verify/reports/real-full-final.json`). The 2560 preview passes 7/7.

### 3.3 Verifier behaviour M1/M4 must not re-derive

- Gate on `kCGImageAuxiliaryDataTypeISOGainMap`; a plain SDR HEIC also "succeeds" `DecodeToHDR` (8 bpc, headroom 1.0), so success alone is not proof of HDR.
- `contentHeadroom` on the **HDR** decode is the authoritative advertised headroom; `calculatedContentHeadroom` is pixel-derived (+0.02…+0.14 here) and on an SDR decode it is not a headroom at all (~0.50 for mid-grey). Trust `contentHeadroom`; report the calculated one as a cross-check.
- A pure SDR P3 image renders at peak 1.14–1.19 in extended linear P3 (ColorSync overshoot), so "fraction of samples > 1.0" is not "authored above white". The useful ratio is `hdrDecode peak / sdrDecode peak`.
- Legacy Apple HEICs still work as a positive control: `samples/reference/IMG_7097.HEIC` carries **both** an ISO aux (mono `L008`, 2016×1512, `AlternateHeadroom` 2.46875 → 5.5356×) and an Apple `HDRGainMap` aux; `DecodeToHDR` returns 10 bpc at 5.5356×. Apple JPEG gain maps (`IMG_7473.JPG`) also expose an ISO aux through ImageIO, which is why the verifier rejects non-HEIF containers.

---

## 4. Viewer verdict — the M0 gate

Device: iPad Pro (M2, Liquid Retina XDR), iPadOS 27. Files: the full-resolution delivered HEIC (Photos) and the local page served from the Mac over the LAN (Safari).

| viewer | route | verdict | observed |
|---|---|---|---|
| **Photos** | AirDrop of `R0003777-M0.heic`, opened in Photos | **PASS** | HDR renders; only the specular sun glints on cars/glass/road get brighter, nothing else changes |
| **Safari** (iPad) | local page `http://192.168.10.85:8765/`, `<img>` with the same HEIC | **PASS** | HDR path active; section 1 (HDR) is brighter in the glints than section 2 (SDR reference); the synthetic 4.0-linear control renders as a grey→white ramp (i.e. the gain map is being applied, not ignored) |
| **SDR fallback** | map-stripped `R0003777-M0-sdr.heic` | **PASS** | indistinguishable from the Capture One export — decision 1 holds |

Gate decision: **Photos and Safari both pass → M0 is green; M1 may start.**

The page and files used for the test stay in the gitignored `work/m0/deliverable/` (`index.html` plus the `serve.py` in §7); they are not committed. M5.1 will promote a generalised copy into `tools/visual-check/` ([docs/07 §6](07-m4-m5-output-and-acceptance.md)), so the same page keeps proving the viewer path. Safari needs Safari 26+ for HDR rendering in `<img>` (docs/03 §2); the iPadOS 27 Safari on the iPad is past that line.

---

## 5. Recipe v0

The field contract lives in [docs/04](04-stage-1-plan.md) M0 ("Recipe v0 — field contract") — one home. The M0 instance written for this trial image is `work/m0/recipe/recipe-v0.json`, copied beside the output as `work/m0/deliverable/R0003777-M0.recipe.json`:

```json
{
  "schema": 0,
  "source":   { "path": "samples/sources/R0003777-P3.tif",
                "sha256": "bd486ca6e0a26734feba094190aec098d77c9a0e23a66c0cc641086f03916116",
                "width": 6000, "height": 4000 },
  "base":     { "profile": "DisplayP3", "tone_map": "c1_match_v1" },
  "hdr":      { "start": 0.62, "lift_stops": 1.4, "transition": 0.28, "headroom_cap": 2.5 },
  "encoder":  { "tool": "toGainMapHDR", "quality": 0.85, "depth": 8, "subsample": false, "map": "iso-rgb" },
  "versions": { "recipe": 0, "tone_map": 1, "encoder": "5dba4e2" },
  "created":  "2026-11-02T20:52:00+08:00"
}
```

`hdr.headroom_cap` (linear, 2.5 ⇒ 1.321928 stops advertised) is the **only** control of delivered headroom — this milestone exists partly to prove that `encoder.subsample` must stay `false` and `-R` must not be relied on.

---

## 6. What changed, and what M1 inherits

Docs corrected in this milestone (same commit): docs/03 §3 (`-R` is inert with `-b`; `-H` writes broken metadata and clips; alpha is path-dependent), docs/04 decision 2 (cap is enforced on HDR pixels) and the M0 section (recipe v0 contract, result).

Constraints M1 must not rediscover:

1. **Clamp the HDR rendition pixels** to the recipe cap; `-R` cannot do it.
2. **The HDR intermediate must be a 4-channel `RGBAf` float TIFF.** ImageIO silently misreads a 3-channel 32-bit-float TIFF (values wrong by ~35 %, tool still exits 0); `CIContext.writeTIFFRepresentation(.RGBAf, extendedLinearDisplayP3)` round-trips exactly and carries a "Display P3 Linear" ICC profile. The alpha sample is 1.0 and does not propagate — output alpha follows the 3-sample SDR base.
3. **Assert the HDR read-back peak before encoding.** If it is < 1.05 the tool silently writes a plain SDR HEIC *with alpha* and exits 0.
4. **Never `-H`**, and always pass `-b` (see §3.1).
5. **Preview and final must share the encoder flags** (M0 did: same `-b -d 8 -q 0.85 -c p3`); the preview is not a separate pipeline.
6. **Verify with `tools/verify-heic`**, gating on ISO-aux presence and `contentHeadroom`; judge base fidelity by distribution (mean/percentiles, and ΔE2000 in M4), never by per-pixel max through 8-bit HEVC.
7. **File size:** full-resolution RGB map = 3.85 MB (+89 % over SDR-only). Fine for stage 1; there is no working subsampling route (`-H` is broken), so any size work is stage 2.

---

## 7. Reproduce

Everything below is run from the repo root; the first block stays inside a subshell.

```bash
# synthetic pair + encoder matrix (~17 MB of TIFFs)
( mkdir -p work/fixtures/.tmp work/fixtures/.mc && cd work/fixtures \
  && TMPDIR="$PWD/.tmp" swift -module-cache-path "$PWD/.mc" \
       ../../tools/m0-fixtures/make-pair.swift "$PWD" \
  && mkdir -p out \
  && ../../tools/toGainMapHDR/bin/toGainMapHDR hdr.tif out -b base.tif -R 2.5 -d 8 -q 0.85 -c p3 )

# real pair: renderer + stats live in work/m0/real/ (prototype for M1, not committed)
swiftc -O -o work/m0/real/.tmp/render work/m0/real/render.swift && work/m0/real/.tmp/render

# objective verification (committed tool)
tools/verify-heic/build.sh
tools/verify-heic/bin/verify-heic work/m0/real/out/R0003777-M0.heic \
    --base work/m0/real/sdr.tif --expect-headroom 2.5 \
    --out work/m0/verify/reports/real-full-final.json     # exit 0

# the iPad page (Mac, same Wi-Fi)
python3 work/m0/serve.py 8765     # serves work/m0/deliverable/ as image/heic
```

The M0 real-pair renderer (`work/m0/real/render.swift`, 65 KB) is intentionally *not* committed — it is the prototype whose mask/cap/colour maths M1 re-implements in `PhotonCore`, so there is exactly one implementation going forward. The evidence it produced (`stats.json`, `notes.md`, `logs/`) stays beside it in the workspace.
