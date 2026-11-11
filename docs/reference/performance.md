---
type: reference
owner: docs
updated: 2026-11-09
---

# Performance

✔ Measured on the 6000×4000 trial image, M1 Max. The 2026-11-09 delivery numbers use the parallel
`DeliveryImageProbe` and `make appctl` (release); the debug column is the same code built debug. That
table is the external-tool pipeline (the v1 writer); the v2 in-process encoder is measured separately
below. The Core Image encoder numbers are debug (the release build is expected to be faster).

| Step | release | debug | Peak RSS |
|---|---|---|---|
| Full delivery (`appctl deliver`, end to end) | **8.1–8.4 s** | 20.5 s | 5.45 GB |
| — decode / render / preview / encode | 0.3–0.5 / 0.18 / 0.22 / 1.0 s | 0.7 / 1.25 / 1.1 / 1.2 s | |
| — verification (`DeliveryVerifier`) | **3.96 s (≈48 %)** | 11.14 s | |
| Base preview (`appctl serve` prepare) | 1.46 s cold / 0.095 s warm | — | — |

## v2 Core Image encoder (debug)

| Step | seconds |
|---|---:|
| Gain map, half-res | 1.09 |
| Gain map, full-res | 2.33 |
| HEIF write (base + gain map) | 0.36–0.46 |
| Encode step total (spike harness) | 6.1–7.4 |

- The gain map is the new engine's largest single cost; it is a parallel CPU loop (one divide + one
  `log2` per channel), and half-res is ~1/4 of the full-res work. A Core Image kernel/vImage version
  is a later optimisation, not a correctness requirement ([encoder.md](encoder.md)).
- The HEIF write is cheap next to the gain map; the metadata rewrap and the 8-bit fallback are part
  of the encode step total, not separately significant.
- The spike harness measured the whole encode step (source through the two HEICs), not just the
  writer; the writer's own share is the gain map + HEIF write above.
- The v2 end-to-end delivery total has not been re-measured yet; the verify numbers are unchanged
  and the encoder's share is the table above.

## Notes

- **Verification is still the largest single step** (3.96 s release / 11.14 s debug), but the
  scalar per-pixel loops are now parallel and the `Colorimetry` matrix is scalar. The batch is
  serial in v2, so a 20-image batch pays ~4 s per image in verification (release). The split and
  the benchmark are in [verify-performance-investigation.md](../plans/verify-performance-investigation.md).
- **The full-resolution float render with local highlight masks is memory-bound**, not CPU-bound:
  expect 5–6 GB peak (the parallel strips add ~0.8 GB). The v2 batch is serial; do not run
  deliveries concurrently.
- **Transfer math:** judging loads the full **22,112,102 B** 16-bit Display P3 base PNG at
  2560×1707 per image — a complete 20-image judging session moves ~440 MB of previews. The filmstrip
  itself only needs ~1–3 MB via the 512-high thumbnails
  ([ADR-0013](../decisions/0013-thumbnail-api.md)).
- **Output sizes:** the legacy 8-bit full-res trial delivery is 5,798,146 B (HDR container) and
  1,946,906 B (its map-stripped SDR copy — a second encode, so the pair does not measure the map's
  cost). The gain map itself costs ≈ +89 % over SDR-only on the M0 full-resolution pair (3.85 MB vs
  2.03 MB). The v2 10-bit half-res profile measured 6.4 MB on the spike image. Budget ~20 MB per
  delivered file.
- A 10-bit base costs ≈ +25 % bytes for cleaner SDR gradients; v2 makes it a profile
  ([v2-plan.md](../plans/v2-plan.md)), not the only output.
