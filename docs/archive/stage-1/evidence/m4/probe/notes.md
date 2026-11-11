# M4.3 calibration probe

Real-data calibration for the M4 delivery verifier (`app/Sources/PhotonCore/DeliveryVerifier.swift`,
docs/07 §5.4). It measures the distributions the verifier's thresholds are frozen against, on the
already-produced M0 full-resolution deliverable, **before** the thresholds were fixed — the point is
that every gate is backed by a measurement on a real 6000×4000 gain-map HEIC, not by a guess.

The probe is linked against the **real `PhotonCore` sources** (`app/Sources/PhotonCore/*.swift`,
compiled with `swiftc -O`), so the numbers come from exactly the code `photon deliver` runs — no
copy of the ΔE2000 maths, the strip renderer or the fallback writer. It also runs the real
`DeliveryVerifier.verify` on the M0 file as a check-level smoke test (see the "verifier" section of
`calibration.json`).

## Data used (all pre-existing M0 evidence, gitignored `work/`)

| input | why |
|---|---|
| `work/m0/deliverable/R0003777-M0.heic` | the M0 full-resolution gain-map HEIC (6000×4000, ISO `tmap`, 8-bit P3 base + full-res RGB map) |
| `work/m0/deliverable/R0003777-M0-2560.heic` | the M0 2560 px preview HEIC (same encoder flags) |
| `work/m0/real/sdr.tif` | the 16-bit Display P3 SDR base the encoder was handed (M0: bit-identical to the Capture One export) |
| `work/m0/real/hdr.tif` | the authored float HDR rendition before encoding (M0: readback bit-identical to the buffer) |
| `work/m0/real/stats.json` | M0's authored-rendition evidence: peak 2.5, fractionAboveOne 0.1094187, fractionAtCap 0.00430608 |
| `work/m0/deliverable/R0003777-M0.recipe.json` | the recipe that produced the file (start 0.62 / lift 1.4 / transition 0.28 / cap 2.5) |
| `samples/sources/R0003777-P3.tif` | the Capture One P3 export (sha256 `bd486ca6…` matches the recipe; it decodes to the same buffer as `sdr.tif`) |

ImageIO is the only decoder/encoder used (`sips` silently strips gain maps and cannot be part of a
proof — docs/03 §2).

## Build and run

From this directory (`work/m4/probe/`):

```bash
./build.sh          # compiles contract + app/Sources/PhotonCore + calibrate.swift with swiftc -O
./bin/calibrate     # writes calibration.json, prints the human summary
```

Everything scratch (TMPDIR, module cache, dylibs, binary, copies) stays inside
`work/m4/probe/` (`.tmp/`, `.mc/`, `.build/`, `bin/`, `out/`), per the DSH sandbox rules in
`app/README.md`. Nothing here is committed (`work/` is gitignored); the evidence for §10 is
`calibration.json` + `calibration.md` + the `out/` copies, referenced from docs/07 §10.

`build.sh` does two `swiftc` invocations:

1. `contract/Sources/PhotonContract/*.swift` → `PhotonContract` module + dylib;
2. `calibrate.swift` + all of `app/Sources/PhotonCore/*.swift` in one module with `-parse-as-library`
   (the probe's `@main` is the entry point), linked against step 1.

The binary is release-optimised on purpose: section (d) is the M4 verification timing.

## What is measured

- **a. `baseDeltaE`** — delivered HEIC SDR decode vs `sdr.tif`, and vs the `SourceDecoder`
  linear-P3 buffer the verifier holds; both rendered strip-wise to linear extended Display P3
  float32. ΔE2000 distribution (mean/p50/p95/p99/max/fractions) + 8-bit Display P3 LSB
  distribution (the `tools/verify-heic` shape).
- **a2. quantisation floor (diagnostic only)** — `sdr.tif` rendered to 8-bit Display P3 and compared
  with the 16-bit source (the shared 8-bit quantisation cost) and with the delivered decode (the
  codec cost). This separates "8-bit container" from "4:2:0 HEVC" and is the evidence behind the
  documented `baseDeltaE` deviation from docs/03 §5.
- **b. fallback** — `DeliveryImageProbe.makeMapStrippedCopy` (ImageIO `CGImageDestination`, no
  metadata) written **twice**, byte-identity checked, then re-inspected (HEIF, no ISO aux, no
  `tmap`, dims) and compared with the delivered SDR primary and with `sdr.tif` (LSB + ΔE2000).
- **c. `previewAgreement`** — the M0 2560 preview HEIC HDR decode vs the M0 full-resolution HEIC HDR
  decode Lanczos-downscaled with `PreviewRenderer`'s exact path; the lossless pipeline analogue
  (downscale `hdr.tif`, clamp to 2.5, vs the delivered decode downscaled — what the real verifier
  compares); and the pipeline preview pair vs the M0 preview HEIC.
- **d. timings** — per-step seconds for the 24 Mpx file, release build, plus the real
  `DeliveryVerifier.verify` total (the number the M4 report's `timings.verifySeconds` will show).
- **verifier** — the real eight checks on the M0 file with every `measured` value, i.e. the
  check-level smoke test and the frozen-threshold validation.

## Memory

The probe is deliberately strip-bounded for the comparisons (a 256-row float buffer), but it does
hold what the pipeline holds: the 384 MB linear source buffer, the 384 MB authored HDR buffer, the
decoded TIFF images and the decoded HEIC. Peak RSS is ~2 GB; the binary is a one-shot analysis
tool, not production code. Section timings show the per-check cost the deliverable pays.
