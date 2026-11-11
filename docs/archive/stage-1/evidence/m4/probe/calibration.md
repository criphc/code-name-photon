# M4.3 real-data calibration — verifier thresholds

*M4.3 evidence · probe: `work/m4/probe/calibrate.swift` (linked against the real
`app/Sources/PhotonCore` sources, `swiftc -O`) · machine: macOS 27.2, M1 Max · generated
2026-11-03 · machine-readable JSON: `work/m4/probe/calibration.json` · build/run: `notes.md`.*

The M4 delivery verifier's thresholds were **frozen from measurement on a real 24 Mpx gain-map
HEIC**, not guessed: every number below comes from the already-produced M0 deliverable
`work/m0/deliverable/R0003777-M0.heic` (6000×4000, ISO 21496-1 `tmap`, 8-bit Display P3 base +
full-resolution RGB gain map, sha256 `1c9020c6…`), the M0 16-bit base `work/m0/real/sdr.tif`, the
authored float HDR `work/m0/real/hdr.tif`, the M0 2560 px preview HEIC and the M0 recipe
(`start 0.62 / lift 1.4 / transition 0.28 / cap 2.5`). All decodes/encodes use ImageIO only
(`sips` silently strips gain maps — docs/03 §2); the probe runs the *real* verifier on the file as
the final smoke test.

## Frozen thresholds

| check | PASS rule | M0 measurement | margin |
|---|---|---|---|
| `container` | ISO-BMFF/HEIF `ftyp`, compatible brand `tmap`, ISO gain-map aux present | major `heic`, brands `mif1,tmap,miaf,MiHB,heic`, aux present | exact |
| `identity` | decoded dims == source == recipe, source sha256 == recipe sha256 | 6000×4000 ×3, `bd486ca6…` both | exact |
| `alpha` | no alpha in the SDR **and** HDR decodes | SDR `noneSkipLast`, HDR `noneSkipFirst` | exact |
| `headroom` | advertised `contentHeadroom` within 5 % of `min(cap, authoredPeak)` | `2.4999998` vs expected `2.5`, rel. err. `9.5e-8`; calc `2.6240` cross-check | 5 % vs 1e-5 % |
| `clipping` | `authoredPeak ≤ cap+1e-6`, `authoredPeak ≥ 1.05`, `fractionAboveOne > 0` | peak `2.5` (1.321928 stops), above-one `10.9419 %`, at-cap `0.4306 %` | exact; decode-side peak `2.9227` is a diagnostic only |
| `baseDeltaE` | **ΔE2000 mean ≤ 2.5 AND p95 ≤ 6.0** (decoded-container rule, see decision A) | mean **1.4406**, p95 **4.1200**, p99 6.54, max 28.34; 8-bit LSB mean 1.475 / p99 7 | 1.7× / 1.5× |
| `fallback` | copy decode vs delivered SDR primary: mean abs ≤ 2.5 LSB, p99 ≤ 8 LSB, ΔE2000 mean ≤ 1.0 | mean **0.627** LSB, p99 **3**, ΔE mean **0.5268** | 4× / 2.7× / 1.9× |
| `previewAgreement` | vs the lossless float preview pair: ΔE2000 mean < 2.5, p99 < 10, fractionAbove5 ≤ 5 % | mean **1.1642**, p99 **5.27**, frac>5 **1.24 %** | 2.1× / 1.9× / 4× |

The verifier's own run on the M0 file: **8/8 PASS** (all eight checks and their measured values are
in `calibration.json` → `verifier`).

## a. `baseDeltaE` — delivered SDR decode vs the Capture One base

Both sides decoded with ImageIO and rendered strip-wise to linear extended Display P3 float32
(`CIContext`), full 24 M px, ΔE2000 per pixel:

| comparison | mean | p50 | p95 | p99 | max | frac > 2 | 8-bit LSB mean / p99 | 8-bit LSB p50/p90/p99 |
|---|---|---|---|---|---|---|---|---|
| delivered HEIC SDR decode vs `sdr.tif` | **1.4406** | 0.99 | **4.1200** | 6.54 | 28.34 | 22.92 % | 1.475 / 7 | 1 / 3 / 7 |
| delivered SDR decode vs `SourceDecoder` buffer | 1.4406 | 0.99 | 4.1200 | 6.54 | 28.34 | 22.92 % | 1.475 / 7 | 1 / 3 / 7 |

The two rows are identical because `sdr.tif` is bit-identical to the Capture One P3 export (M0
contract). The 8-bit LSB distribution **exactly reproduces M0's published measurement**
(mean 1.475, p50/p90/p99 = 1/3/7, docs/05 §3.2), which confirms the decoded data is right and that
the difference is the container's codec, not a colour-management mistake.

### a2. The 1.44 is the codec, not the 8-bit container (diagnostic, never a gate)

`a2_quantisationFloor` isolates the two losses: the 16-bit `sdr.tif` rendered to 8-bit Display P3
(nothing else changed), then compared with (i) the 16-bit linear source and (ii) the delivered SDR
decode:

| comparison | ΔE2000 mean | p95 | p99 | max |
|---|---|---|---|---|
| 16-bit source → 8-bit Display P3 quantisation only | **0.2680** | 0.59 | 0.77 | 1.67 |
| 8-bit source → delivered decode (codec only) | **1.4688** | 4.15 | 6.57 | 28.34 |

So 8-bit quantisation accounts for ~0.27 mean ΔE; the remaining ~1.47 is the encoder's 8-bit
YCbCr **4:2:0 HEVC** re-encode (chroma subsampling dominates the tail). This is the evidence behind
decision A below.

## b. `fallback` — the ImageIO map-stripped copy

`DeliveryImageProbe.makeMapStrippedCopy` (= `CGImageDestinationCreateWithURL` +
`CGImageDestinationAddImage` with the SDR primary, **no** metadata dictionary: no aux data, no EXIF,
no timestamps — never `sips`), written from the delivered primary:

- copy: **1,946,906 B**, sha256 `d639359abd87bc9c311d2f7351f79d307e34225269fc21c9236f144f96805b0e`,
  `ftyp` major `heic`, compatible `mif1,miaf,MiHB,heic` (**no `tmap`**), `isoGainMapPresent = false`,
  SDR alpha `noneSkipLast`, 6000×4000.
- **two writes of the same input are byte-identical** → the fallback copy is deterministic
  (docs/07 §5.3 determinism gate; pinned by `DeliveryVerifierTests`).
- copy vs delivered SDR primary: 8-bit LSB **mean 0.627, p50 0, p90 2, p99 3, max 25**;
  ΔE2000 **mean 0.5268, p95 1.71, p99 2.63, max 12.96**.
- copy vs `sdr.tif` (the Capture One base): LSB mean 1.597 / p99 8 / max 137;
  ΔE2000 mean 1.5349 / p95 4.40 / p99 6.94 — the same single-codec loss as section a, reported as
  a diagnostic (the fallback gate is copy-vs-delivered, both 8-bit output).

## c. `previewAgreement` — 2560 px rendering vs the delivered HDR decode

The delivered HDR decode (`kCGImageSourceDecodeToHDR`) is downscaled to 2560×1707 through
`PreviewRenderer`'s exact Lanczos path (`clampedToExtent` + `CILanczosScaleTransform` + crop) and
compared, rendered to linear P3, with:

| comparison | mean | p50 | p95 | p99 | max | frac>2 | frac>3 | frac>5 |
|---|---|---|---|---|---|---|---|---|
| M0 2560 preview **HEIC** decode vs delivered HDR downscaled | 1.4352 | 1.01 | 4.08 | 6.84 | 75.6 | 22.74 % | 10.61 % | 2.81 % |
| **lossless pipeline analogue** (downscale `hdr.tif`, clamp to 2.5 — i.e. the float `input.preview.hdr` — vs delivered HDR downscaled) | **1.1642** | 0.81 | 3.30 | **5.27** | 48.45 | 15.98 % | 6.50 % | **1.24 %** |
| pipeline float preview pair vs M0 preview HEIC | 1.6230 | 1.04 | 4.91 | 8.45 | 78.1 | 26.63 % | 14.42 % | 4.78 % |

The middle row is what the M4 verifier actually compares (`input.preview` is the pipeline's
lossless float pair; the preview HEIC only appears in this calibration). The residual is dominated
by the delivered file's own 8-bit gain-map/codec noise and the documented 2560-vs-full-resolution
mask difference at highlight edges (docs/06 §4.5, docs/07 §5.5) — it is reported, never "fixed up".
The pipeline float pair vs the M0 preview HEIC (1.62 mean) confirms the M0 preview HEIC is the same
rendering plus one more 8-bit/preview codec loss.

## d. Timings (release, 24 M px, this machine)

| step | seconds |
|---|---|
| decode delivered HEIC (facts + SDR + HDR decode) | 1.08 |
| `baseDeltaE` (ΔE2000 + 8-bit LSB over 24 M px) | **8.16** |
| `fallback` (write 0.12 + re-inspect/decode + 24 M px LSB + ΔE) | **5.9** (write 0.12) |
| `previewAgreement` (HDR decode downscale + render + 4.4 M px ΔE) | **1.8** |
| `clipping` decode-side overshoot scan (24 M px) | ~0.8 |
| quantisation-floor diagnostic (calibration only, not a check) | 9.8 |
| **`DeliveryVerifier.verify` total** | **16.2 s** |

So one 24 M px `photon deliver` ≈ 16 s render+encode + ~16 s verification on this machine. The
verifier is dominated by the two full-resolution ΔE2000 passes (base + fallback); the
`verifySeconds` recorded in `report.json` is this total. This is analysis cost, not render cost; it
does not touch the ~5 GB delivery memory peak beyond the buffers the pipeline already holds.

## Threshold decision (recorded 2026-11-03 — cited from docs/07 §10)

**A. `baseDeltaE` deviates from docs/03 §5's render target.** docs/03 §5 says "mean ΔE2000 < 1,
p95 < 2 versus the Capture One TIFF". That is a **render** target and it is met by the 16-bit
`c1_match_v1` base (M1 measured bit-exact pass-through, ΔE 0.000). It is **not reachable by a
decoded 8-bit 4:2:0 HEVC container**: the same photo measures mean 1.4406 / p95 4.1200 through the
delivered file, of which 8-bit quantisation explains only 0.2680 / 0.59 and the encoder's
4:2:0/HEVC re-encode the other ~1.47 / ~4.15 (a2). A fresh ImageIO 8-bit HEIC written from the same
base measures the same (1.5349 / 4.40), so this is the container's base fidelity, not a defect of
the delivered file or of the verifier.

Decision (Lead, 2026-11-03): the report's `baseDeltaE` gate is the **decoded-container rule**
`mean ≤ 2.5 AND p95 ≤ 6.0`, still tight enough to catch a colour-management/profile error or a base
re-grade (those land far above); `p99`, `max`, `fractionAbove2/5` and the 8-bit LSB cross-check stay
reported as diagnostics, and the docs/03 §5 render target is reported in `measured`
(`renderTargetMean` / `renderTargetP95`) for the M5 record. The verifier `detail` and doc comment
state the rule and why. This is recorded as an M4 deviation from docs/03 §5 in docs/07 §10.

**B. `fallback`** (approved as proposed): `mean abs ≤ 2.5 LSB && p99 ≤ 8 LSB && ΔE2000 mean ≤ 1.0`
against the delivered SDR primary; measured 0.627 / 3 / 0.5268 (>3× margin). The copy is also
re-inspected as a HEIF without an ISO gain map and with equal dimensions; two writes are
byte-identical.

**C. `previewAgreement`** (approved as proposed): `ΔE2000 mean < 2.5 && p99 < 10 &&
fractionAbove5 ≤ 5 %` on the **lossless** comparison (float `input.preview` vs the delivered HDR
decode downscaled); measured 1.1642 / 5.27 / 1.24 %. A wrong recipe/file/cap moves a large fraction
of the frame by ΔE 10+ and fails; the documented scale difference and 8-bit gain-map quantisation
do not.

`headroom` / `clipping` / `container` / `identity` / `alpha` were not changed: the M0 file passes
them exactly (table above).

## Limitations / notes for M4.5

- The verifier run above used the M0 full-resolution deliverable (the M4 pipeline produces its own
  staging file). The rules are source/recipe-parameterised and do not assume M0.
- `sdr.tif` / `hdr.tif` are the M0 intermediates; M0 proved both bit-identical to the pipeline's
  buffers (docs/05 §3.2), which is why they are valid proxies for the in-memory comparison.
- Two ImageIO decodes are in the path by design: the verifier re-reads the delivered HEIC (the
  read-back gate has already opened it) so it verifies the bytes that will be installed, not a
  buffer from the encoder.
- `baseDeltaE`'s 1.44 mean is a property of the **current recipe encoder flags** (`-d 8 -q 0.85`,
  4:2:0). If a future recipe/encoder changes the base fidelity, re-measure before reusing these
  thresholds; the 8-bit LSB mean is the fastest signal.
