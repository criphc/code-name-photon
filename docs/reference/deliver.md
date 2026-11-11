---
type: reference
owner: server
updated: 2026-11-09
---

# Delivery Contract and Report

## v2 delivery (`appctl deliver`)

```bash
appctl deliver <id | --source fixtures/media/sources/R0003777-P3.tif> \
    [--recipe work/<sha>/recipe.json] [--out out/] [--batch fixtures/media/sources] [--work work] \
    [--profile 10/half/rgb]... [--encoder <oracle-path>] [--preview-edge 2560]
# -> out/{stem}-hdr-{profile}.heic   (one per requested profile)
#    out/{stem}-sdr.heic, out/{stem}.recipe.json, out/{stem}.report.json
```

### The delivery contract

`appctl deliver` is the explicit Mac-side trigger (there is no automatic render on `POST recipe`): it
resolves the item and the recipe the iPad stored, re-hashes the source, revalidates the recipe
against the decoded source, renders the SDR base + HDR rendition at full resolution with the shared
`HighlightShape`/`HDRRendition` maths and cap, refuses a rendition below 1.05, encodes **once per
requested profile** with the in-process `CoreImageHEICEncoder`, reads each container back with
ImageIO, runs the `DeliveryVerifier` per profile, and installs the set **only when every check of
every profile passes** (fail-closed).

- **Serial.** Items are delivered one at a time; a single item's profiles are encoded and verified
  one at a time. No item/profile concurrency in v2 (memory first).
- **One render, one report.** The source is decoded and the base/HDR are rendered once per item; the
  report is one document with a `profiles: [...]` array, not one report per profile.
- **Shared fallback.** `{stem}-sdr.heic` is written once per item (8-bit, no aux, same capture metadata) and shared by every
  profile.

*Inputs.* `<id>` is the 64-hex source SHA-256 that `/api/items` reports; it is resolved inside
`--batch` (default `inbox`) by re-hashing the TIFFs — the same identity rule as the API. `--source
PATH` skips the lookup; other than that `deliver` is source-agnostic. The recipe is `--recipe FILE`
when given, otherwise `<work>/<source sha256>/recipe.json`. `--preview-edge` (default 2560) only feeds
the `previewAgreement` check. Profiles come from the recipe's `encoder` block (one profile) unless
`--profile` is passed, repeatable (`10/half/rgb`, `8/full/mono`); a duplicate profile is
`invalidRecipe`. The writer is the in-process `CoreImageHEICEncoder`; `--encoder PATH` selects the
external `toGainMapHDR` as the migration oracle, not the production path.

*Outputs* — one HDR file per profile plus the shared files, one current delivery per image:

| file | content |
|---|---|
| `{stem}-hdr-{profile}.heic` | per-profile gain-map HEIC: 8/10-bit P3 base, ISO `tmap` + ISO aux (half/full, RGB/mono), no alpha, EXIF/TIFF/GPS |
| `{stem}-sdr.heic` | shared 8-bit SDR fallback: the same base, no auxiliary data, EXIF/TIFF/GPS/orientation |
| `{stem}.recipe.json` | the exact recipe used (canonical bytes, the posted `created` preserved) |
| `{stem}.report.json` | schema 1 verification report — the gate |

`{profile}` is `HEICEncodeOptions.profileName` (`10-half-rgb`, `8-full-mono`); `{stem}` is the source
file's base name. Staging is `<work>/<sha>/delivery/<uuid>/` and is removed on success. A failing
delivery installs **nothing**: the staging set plus `report.json` move to
`<work>/<sha>/rejected/<renderKey12>/` and the command exits 1 naming the failed `profile: check`.
Every installed file goes through a same-directory temp file + `rename(2)` (`AtomicFile`); the files
are not one transaction, and the report's `renderKey` + HEIC SHA-256 make a stale pairing detectable
instead of silent.

*Errors* — the existing `PhotonError` families plus the delivery cases:

| condition | error | exit |
|---|---|---|
| no item with that id in `--batch` | `sourceUnreadable` (the message names `--batch` / `--source`) | 1 |
| the `--batch` folder cannot be listed | `sourceUnreadable` | 1 |
| stored recipe missing / undecodable / out of contract | `invalidRecipe` | 1 |
| duplicate `--profile` | `invalidRecipe` | 1 |
| malformed `--profile` string | usage error naming the accepted form | 2 |
| source bytes differ from the recipe's `source.sha256` (re-export) | `sourceHashMismatch` — re-hashed at decode **and** again before install | 1 |
| decoded size differs from the recipe | `dimensionMismatch` | 1 |
| non-Display-P3 source | `unsupportedSource` | 1 |
| authored peak below 1.05 | `hdrTooDim` — asserted before any encode | 1 |
| the writer cannot produce the file | `writeFailed` | 1 |
| encoded file fails the structural ImageIO read-back gate | `encoderOutputInvalid` | 1 |
| a named report check failed | `deliveryVerificationFailed(reportPath, failures)` | 1 |
| usage / unknown option | — | 2 |

The oracle can additionally fail with `encoderMissing` / `encoderFailed` /
`encoderOutputMissing`; the in-process engine has no subprocess to miss.

*Idempotence and determinism.* Re-delivery replaces the set atomically; the same source + recipe +
profile produces byte-identical `{stem}-hdr-{profile}.heic`, `{stem}-sdr.heic` and
`{stem}.recipe.json` on the same machine and OS. Across OS the contract is pixel-level (base
bit-exact, HDR decode ΔE 0, metadata equal). `report.json` carries timings, so it is not
byte-comparison material — the determinism gate covers the HEICs and the recipe echo. A different
recipe replaces the current delivery in the same folder; keeping two looks per image is unscheduled.

### Batch delivery

`appctl deliver --batch <dir>` with no `<id>` and no `--source` delivers the whole flat batch: the
single-item path above runs once per item with the shared `--out`/`--work`/`--profile`/`--preview-edge`.

- **Items.** `BatchLookup.items(in:)`: regular, non-hidden `.tif`/`.tiff` files in file-name order,
  duplicate content collapsing to the first name — the same rule as `/api/items`, so an id and a batch
  run never disagree about which files exist. A file that cannot be hashed is skipped.
- **Skipped.** An item is delivered only when `<work>/<sha256>/recipe.json` exists; the rest are
  `skip`, not failures (the iPad has not posted a recipe yet).
- **Serial, failure continues.** Items run one at a time; a failed item does not stop the batch. v2
  has no item/profile concurrency and no queue.
- **Evidence.** A failed item's rejected evidence sits where a single delivery leaves it; the summary
  appends `(evidence <path>)` only when the failure reached the verifier — an earlier failure (recipe
  mismatch, unreadable source) has no evidence folder.
- **Exit.** 0 when every deliverable item passed; 1 when any item failed or no item had a stored
  recipe (nothing delivered, stderr says so); 2 for a usage error.

## Report schema 1 — the delivery gate

`EngineKit.DeliveryReport` (pretty JSON, sorted keys, newline-terminated) is written into the staging
set before the verdict is acted on, so the rejected evidence folder always explains why a delivery
did not install. A `FAIL` is a value, not an exception. `pass`/`failures` are derived, never
hand-written: a report cannot claim PASS while one of its checks says FAIL.

```json
{
  "schema": 1,
  "pass": true,
  "failures": [],
  "provenance": { "tool": "photon deliver", "appVersion": "0.5.0-v2", "encoderVersion": "coreimage-1" },
  "source": { "path": "...", "sha256": "...", "width": 6000, "height": 4000 },
  "recipe": { "renderKey": "...", "created": "...", "start": 0.2, "liftStops": 1.4,
              "transition": 0.5, "headroomCap": 2.5, "quality": 0.85, "depth": 10 },
  "profiles": [
    {
      "profile": { "name": "10-half-rgb", "bitDepth": 10, "quality": 0.85,
                   "mapResolution": "half", "mapKind": "iso-rgb" },
      "render": { "width": 6000, "height": 4000, "headroomCap": 2.5, "authoredPeak": 2.176,
                  "fractionAboveOne": 0.0, "fractionAtCap": 0.0, "capEngaged": false,
                  "previewLongEdge": 2560 },
      "artifacts": { "hdrHEIC": { "file": "...", "bytes": 0, "sha256": "..." },
                     "sdrHEIC": { "...": "..." }, "recipeJSON": { "...": "..." } },
      "checks": [ { "name": "container", "status": "PASS", "detail": "...", "measured": {}, "warnings": [] } ],
      "timings": { "decodeSeconds": 0.0, "verifySeconds": 0.0 },
      "pass": true,
      "failures": []
    }
  ]
}
```

- One document per delivery. `profiles` is ordered as requested; a duplicate profile name is a
  programming error.
- Top-level `failures` is `"<profile>: <check>"` for every failed check, in profile then canonical
  order.
- `Check.warnings` records non-fatal observations (the half-res `previewAgreement` band); a warning
  never changes `status`.
- The recipe schema and maths are documented in [recipe.md](recipe.md).

### Per-profile checks

All eight checks must pass in **every** requested profile for the delivery to install. The
`headroom` 5 % advertised-match is a gate again (ADR-0011 recovered by ADR-0012); `baseDeltaE`
limits are per profile bit depth.

| check | PASS rule (all must hold) | what it measures |
|---|---|---|
| `container` | ISO-BMFF/HEIF byte structure; compatible brand `tmap`; `kCGImageAuxiliaryDataTypeISOGainMap` present; map dims == base/2 for `half`, == base for `full`; for `iso-rgb` the map is a non-mono `PixelFormat` (the writer emits `420f`); `iso-mono` → `L008` | the profile's dialect; ImageIO + the `ftyp` box only, never `sips` |
| `identity` | decoded SDR dims == source dims == recipe dims; `source.sha256` == recipe `source.sha256` | provenance for the archive |
| `alpha` | SDR **and** HDR decodes have `alphaInfo` ∈ {none, noneSkipLast, noneSkipFirst} | the no-alpha rule |
| `headroom` | authored peak does not exceed the cap by > 1e-6; a missing ISO gain map fails; the advertised `contentHeadroom` within 5 % of `min(recipe cap, authored peak)` | `calculatedContentHeadroom` is the gate's fallback value when `contentHeadroom` ≤ 1.0, the cross-check otherwise ([verification.md](verification.md)) |
| `clipping` | authored peak ≤ cap + 1e-6, authored peak ≥ 1.05, `fractionAboveOne > 0`; decode-side overshoot reported as a diagnostic | the encoder floor |
| `baseDeltaE` | decoded base vs the 16-bit P3 base: **mean ΔE2000 ≤ 2.5 and p95 ≤ 6.0 for an 8-bit profile; mean ≤ 2.0 and p95 ≤ 5.0 for a 10-bit profile** | the Capture One match of the *container*; measured 1.44/4.12 (8-bit) and 1.06/3.25 (10-bit) on R0003777 |
| `fallback` | `{stem}-sdr.heic` is a HEIF with **no** ISO gain map, same dims; vs the delivered SDR primary: 8-bit mean ≤ 2.5, p99 ≤ 8, ΔE2000 mean ≤ 1.5 | proves the 8-bit fallback separately; it is what non-HDR viewers see |
| `previewAgreement` | ΔE2000 mean < 2.5, p99 < 10; `fractionAbove5` ≤ 5 % for a **full-res** map, ≤ 10 % PASS / 10–20 % PASS + warning / > 20 % FAIL for a **half-res** map | differences confined to highlight edges; the preview is a rendering, not a delivery proof |

**Two base comparisons, never conflated.** The *render* target is bit-exact: the 16-bit
`c1_match_v1` base vs the Capture One export (ΔE2000 0.000; target mean < 1 / p95 < 2). The
`baseDeltaE` check judges the *container*: the decoded HEVC re-encode of that base, hence the
looser per-profile gate above (8-bit is the M0 trial-image calibration; 10-bit the 2026-11-09
three-image set, half and full maps measuring identically). A check that cannot be evaluated
(e.g. a failed HDR decode) is a FAIL with the reason in `detail` — never an omitted check.
`tools/verify-heic` is deliberately not a report check: it is the independent ImageIO cross-check
at acceptance, and its JSON report is archived beside `{stem}.report.json`.
