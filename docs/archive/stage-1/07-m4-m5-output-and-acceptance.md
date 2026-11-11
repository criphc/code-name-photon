# Stage 1 — M4/M5: Full-Resolution Output, Verification and Delivery Acceptance

*Plan document 7 · created 2026-11-03 · starts after M3 ([docs/06](06-m3-ipad-edr-plan.md))*
*Inputs: [docs/04](04-stage-1-plan.md) (M0–M2.1: recipe schema, M2.1 API contract), [docs/06](06-m3-ipad-edr-plan.md) (M3), [docs/03](03-considerations-beyond-the-plan.md) §3/§5/§6, [docs/05](05-encoder-verification.md) §6. The stage-1 definition of done is [docs/01 §1](../../01-app-concept-and-three-stages.md).*

**Status (2026-11-03): stage 1 complete.** M4.0–M4.5 and M5.1–M5.3 are **done**: `photon deliver` delivers the M3-posted recipe at full resolution (report PASS 8/8, independent `verify-heic` PASS, two runs byte-identical), and the delivered file passed device acceptance on the reference iPad — Photos (View Full HDR on/off) and Safari via the local page, all five ladder rungs, the blind A/B and the reject criteria (§10). Stage 1 stops here; stage 2 is not started ([docs/01](../../01-app-concept-and-three-stages.md)).

---

## 1. Goal and acceptance

**M4 goal.** Turn the recipe the iPad posted into the delivered file: apply it at full resolution on the Mac, write the SDR base + HDR rendition pair, hand that pair to `tools/toGainMapHDR -b`, verify the container and the base with ImageIO, and archive the HEIC with its recipe and verification report. M4 renders and writes; it does not judge.

**M4 acceptance** (M4 is done only when all of these hold):

1. **Deliver from the stored recipe.** `photon deliver` resolves the item, re-hashes the source, loads the recipe M3 stored, revalidates it, and renders at full resolution with the same maths and the same cap.
2. **Base untouched.** The full-resolution SDR base is a bit-exact 16-bit pass-through of the Capture One P3 export (the M1 contract — same `sdr.tif` bytes as M1), and the decoded delivered base passes the container ΔE2000 rule of [docs/03 §5](03-considerations-beyond-the-plan.md) (mean ≤ 2.5, p95 ≤ 6.0; the tighter mean < 1 / p95 < 2 is the render target, met by the 16-bit base itself).
3. **Real HDR at full resolution.** The authored peak equals the recipe cap within float tolerance; the encoder's 1.05 floor is asserted *before* encoding ([docs/05 §6](05-encoder-verification.md)); the delivered container advertises `contentHeadroom` within the documented tolerance; no alpha channel.
4. **Verified, never assumed.** A `report.json` (schema 0) records every check of [docs/03 §5](03-considerations-beyond-the-plan.md) as a named PASS/FAIL with its measured values. A failing check means "not a deliverable": the file is not installed into the delivery folder.
5. **SDR fallback proved separately.** A map-stripped copy (made with ImageIO — never `sips`) pixel-compares with the approved SDR base, so the file that non-HDR viewers show is the Capture One rendition.
6. **Deterministic and idempotent.** Same source + same recipe ⇒ byte-identical `hdr.heic`; a re-delivery replaces the previous files atomically. The flat folder holds one current delivery per image: the report records the HEIC's `renderKey` and sha256, so a changed recipe is always visible and never silently paired.
7. **Named and archived.** The `--out` folder holds `{stem}-hdr.heic`, `{stem}-sdr.heic`, `{stem}.recipe.json` and `{stem}.report.json`; every replaceable file goes through `AtomicFile` ([docs/03 §6](03-considerations-beyond-the-plan.md)).
8. **No regressions.** `cd app && make test` is green (the test count grows); the M2.1 wire contract, recipe schema 0 and the M3 iPad client are unchanged; `photon prep` and `photon serve` behave exactly as before.
9. **Evidence.** The trial image's delivery, report and `verify-heic` output in the gitignored `work/m4/`; the M4 result recorded in §10.
10. **Scope.** Nothing outside §8.

**M5 goal.** Prove the delivered file in the real viewers on the device, apply the reject criteria, and close stage 1. M5 adds no product code — its only new committed artifact is the visual-check tool (§6 M5.1), promoted from the M0 viewer page.

**M5 acceptance:**

1. The delivered HEIC opens in **Photos on the iPad** and in **Safari on the iPad via a local page** (Safari 26+; decision 6 of [docs/04](04-stage-1-plan.md)) and shows the intended HDR; the SDR view is indistinguishable from the Capture One export.
2. The **five-rung viewer ladder** of [docs/03 §5](03-considerations-beyond-the-plan.md) is recorded rung by rung, with the failing rung named where one fails.
3. A **blind A/B** against the SDR base and the two look references (`samples/reference/IMG_7097.HEIC`, `IMG_7473.JPG`) is recorded — randomised order/filenames, "which looks like the print?" rather than "which is HDR?", a second observer if available.
4. **No reject criterion** from [docs/03 §5](03-considerations-beyond-the-plan.md) triggers — or the trigger is recorded and the delivery goes back to M3 (recipe) or M4 (render) instead of claiming success.
5. **Timings** are recorded (full render, encode, verification, transfer, viewer start-up).
6. The stage-1 DoD in [docs/01 §1](../../01-app-concept-and-three-stages.md) is checked line by line; §10 records the verdict and the stage stops here.

---

## 2. Decisions (recorded 2026-11-03)

| Decision | Value | Why |
|---|---|---|
| **Delivery trigger** | an explicit Mac-side command: `photon deliver <id \| --source path>` after the recipe is stored; no automatic render on `POST recipe` | the Mac is the render authority; an explicit trigger is reproducible evidence and does not tie up the server; the watcher/queue is stage 2 ([docs/01 §2.1](../../01-app-concept-and-three-stages.md)) |
| **Recipe input** | `work/<sha256>/recipe.json` (the file M2.1 stored) by default, `--recipe FILE` to override | one source of truth; the identity is re-hashed and the recipe revalidated before any pixels are rendered |
| **Output layout** | a flat `--out DIR` (default `out/`) holding `{stem}-hdr.heic`, `{stem}-sdr.heic`, `{stem}.recipe.json`, `{stem}.report.json` | matches the stage-1 wording of [docs/02](../../02-hdr-highlight-finisher-workflow.md) and is the simplest thing that archives correctly for one photograph; one current delivery per image, with the `renderKey` + HEIC sha256 in the report so the pairing is auditable (multiple looks per image are stage 2) |
| **Report authority** | `PhotonCore.DeliveryReport` (schema 0) is the gate; its checks are unit-tested in `make test`, and the report itself is produced by `photon deliver`. `tools/verify-heic` stays the independent ImageIO cross-check run at M4/M5 acceptance | the gate must fail closed inside the pipeline and be unit-tested; `verify-heic` remains the M0-lineage second opinion, not the only one |
| **Wire contract** | unchanged: no new route, no new `renderKey` computation, `ItemState` keeps its four M2.1 values | the M3 client decodes a closed enum; `rendered` / `encoded` / `verified` are **stage-2** queue states ([docs/01 §2.1](../../01-app-concept-and-three-stages.md)); M5 reads files, not the API |
| **iPad** | untouched (frozen at M3) | M3's scope excludes delivery UI; M5's Safari page is a web page, not app UI |
| **M5 visual-check tool** | the M0 viewer page promoted into `tools/visual-check/` (`index.html` + `serve.py`): serves a folder over the LAN with `image/heic` + `no-store`, shows the delivered HEIC, its SDR copy and the two look references | M0 already built and passed this page ([docs/05 §4](05-encoder-verification.md)); promoting it keeps one acceptance tool instead of a new page, and it stays tooling, not product code |
| **Metadata** | stage 1 delivers pixels and the ISO gain map only; **no EXIF/orientation rewrap** — recorded as a known gap | the Core Image writers cannot attach capture metadata ([docs/03 §3](03-considerations-beyond-the-plan.md)); a rewrap is its own risk and is not needed to close the DoD |
| **Acceptance image** | `samples/sources/R0003777-P3.tif` with the recipe posted from the iPad in M3 (`work/m3/server/bd486ca6…/recipe.json`); `deliver` itself is source-agnostic | stage 1 is one photograph end to end ([docs/01 §1](../../01-app-concept-and-three-stages.md)); the other P3 sources stay as optional smoke tests |
| **Cap and maths** | the recipe's `hdr.headroom_cap` (2.5, fixed by M3) and `PhotonContract.HighlightShape` / `HDRRendition` unchanged | one maths; M4 must not grow a second renderer or a second cap |
| **Evidence** | `work/m4/`, `work/m5/` (gitignored); the verdicts recorded in §10 | M3 precedent ([docs/06 §10](06-m3-ipad-edr-plan.md)) |

**Why delivery is a separate Mac job, not a server route.** A full-resolution render and encode is a ~5 GB, multi-second job ([docs/03 §7](03-considerations-beyond-the-plan.md)); running it inside an HTTP request would hold the M2.1 connection handler for the whole render and turn a client timeout into a false failure. Stage 1 has no Mac UI and no queue, so the honest shape is a command the owner runs after judging — and its result is a file the M5 page can serve. Auto-delivery on recipe receipt, progress, and cancellation are stage-2 concerns ([docs/01 §2.1](../../01-app-concept-and-three-stages.md)).

**Why the report is a gate, not a log.** [docs/04](04-stage-1-plan.md) M1 already refuses to encode a rendition below the 1.05 floor and reads every HEIC back with ImageIO before accepting it (`EncodedHEICValidator`). M4 extends the same discipline to delivery: a file that was not verified is not a deliverable ([docs/02](../../02-hdr-highlight-finisher-workflow.md)). A PASS is required to install into `out/`; a FAIL leaves the diagnosis in the work folder and names the failing check.

---

## 3. Constraints inherited from M0/M1/M3

Each item's home is linked; M4/M5 must not re-derive them.

- **Encoder rules**: `-b` only (never `-H`; `-R` is inert under `-b`), 4-channel `RGBAf` intermediate, 1.05 read-back floor before encoding, shared preview/final flags — details in [docs/03 §3](03-considerations-beyond-the-plan.md) and [docs/05 §6](05-encoder-verification.md).
- **`CIImage` buffer ownership** ([docs/03 §3](03-considerations-beyond-the-plan.md)): build through a provider-backed `CGImage` (`ImageBuffers`); no new `CIImage(bitmapData:)` in the delivery path.
- **No alpha** (decision 5) and **Display P3 only** (decision 1, enforced at decode).
- **One maths** ([docs/06 §4.5](06-m3-ipad-edr-plan.md)): `PhotonContract.HighlightShape` / `HDRRendition` is the definition; the M3 shader is its port and the parity gate already pins it. M4 renders the same shape at full resolution; the preview computes the mask on the 2560 px base, so sub-pixel edge differences are expected and reported, never hidden.
- **Determinism** ([docs/04 M1](04-stage-1-plan.md), [docs/05 §3.2](05-encoder-verification.md)): same source + recipe ⇒ byte-identical intermediates and HEIC. M4 re-asserts it for the full-resolution output.
- **Atomic replacement** ([docs/03 §6](03-considerations-beyond-the-plan.md)): `AtomicFile` for every replaceable artifact; nothing half-written is ever visible.
- **Source identity** ([docs/04 M2.1](04-stage-1-plan.md)): item id = SHA-256 of the source bytes; a re-export is a new id and a stale recipe is refused (409 `source_changed`), never paired silently.

---

## 4. What M4 and M5 do and do not do

**M4 does:** read the stored recipe, revalidate identity, render the full-resolution SDR base and HDR rendition, encode the gain-map HEIC with the existing tool, verify container + base + fallback, write and archive the deliverables, and report PASS/FAIL.

**M4 does not:** judge HDR visually, change the iPad, add API routes or wire states, write a HEIF container, re-colour the base, batch, watch a folder, add a Mac UI, attach EXIF, or render 10-bit.

**M5 does:** serve the delivered file to Safari on the iPad, run the viewer ladder and the blind A/B, apply the reject criteria, record timings and the verdict, and stop.

**M5 does not:** add product features, retune the recipe without going back through M3, or start stage-2 work.

---

## 5. Architecture

### 5.1 Components

| Component | Responsibility | Reuses | M4 does not |
|---|---|---|---|
| **Delivery job** (`photon deliver`, `DeliveryPipeline`) | resolve item + recipe, re-hash, validate, orchestrate render → encode → verify → archive, print the verdict | `SourceDecoder`, `ToneMapper`, `Encoder`, `EncodedHEICValidator`, `AtomicFile` | add a second renderer or a wire route |
| **Full-resolution renderer** | SDR base (16-bit P3 TIFF) + HDR rendition (RGBAf float TIFF) with the recipe's shape and cap | `contract/` `HighlightShape` / `HDRRendition`, `TIFFWriter` | retouch the base, add a second tone curve |
| **Encoder** | `toGainMapHDR -b -d 8 -q <recipe> -c p3`, pre-peak assertion, read-back gate, atomic install | the existing `Encoder` + `EncodedHEICValidator` | write the container, use `-H`, rely on `-R` |
| **Verifier** (`DeliveryVerifier` → `DeliveryReport`, schema 0 → `report.json`) | named checks, measured values, PASS/FAIL, timings, versions | `EncodedHEICValidator`, `PhotonContract`, ImageIO for ΔE2000 | re-implement the maths or trust `sips`/exit codes |
| **Archive and naming** | a flat `--out DIR` (default `out/`): `{stem}-hdr.heic`, `{stem}-sdr.heic`, `{stem}.recipe.json`, `{stem}.report.json`; every file replaced atomically | `AtomicFile` | version counters; pretending the four files are one transaction (the report's `renderKey` + HEIC sha256 is the pairing check) |
| **Visual-check tool** (M5) | a folder-driven page showing the delivered HEIC, its SDR copy and the two look references; served from the Mac over the LAN | `tools/visual-check/`, generalised from `work/m0/deliverable/index.html` + `work/m0/serve.py` | rewrite the viewer logic; app UI, auth, product feature |

### 5.2 Data flow

1. The iPad posted a recipe in M3 → `work/<sha256>/recipe.json`; M2.1 recorded its `renderKey` in `state.json`.
2. `photon deliver <id>` (or `--source <path>`) → resolve the batch item by source hash, load the recipe, **re-hash the source**, validate the recipe (schema, ranges, identity, dimensions) — refuse on any mismatch.
3. Decode → linear extended Display P3 float → SDR base (`c1_match_v1`, untouched) → HDR rendition (`HighlightShape` from `hdr`, `HDRRendition` clamps to `hdr.headroom_cap`).
4. Assert the authored peak ≥ the 1.05 floor; encode into a staging directory, never into the destination.
5. ImageIO read-back gate: ISO gain-map auxiliary present, `contentHeadroom` within tolerance of the cap, dimensions match, no alpha, `DecodeToHDR` succeeds.
6. Verifier: container/profile facts, base ΔE2000 vs the source export, clipping counts, the map-stripped fallback comparison, and the same-recipe preview↔delivery comparison → `report.json`.
7. Write the map-stripped SDR copy with ImageIO and compare it with the SDR base (the fallback proof).
8. If every gate passes, atomically install the four files into `--out DIR` (`{stem}-hdr.heic`, `{stem}-sdr.heic`, `{stem}.recipe.json`, `{stem}.report.json`) and print a short summary (paths, headroom, ΔE, sizes, timings, PASS).
9. On failure, install nothing; keep the staging diagnostics and `report.json` in `work/<sha256>/rejected/<renderKey12>/` and name the failing step and check.
10. Re-run with the same recipe: the same four files, byte-identical HEIC (determinism). A different recipe replaces the current delivery in the same folder — the new report's `renderKey` and HEIC sha256 make the change explicit; keeping two looks per image is stage 2.

### 5.3 Delivery contract (inputs, outputs, failure modes)

**CLI — the explicit Mac-side trigger** (decision 1 of §2):

```bash
photon deliver <id | --source PATH> [--recipe FILE] [--out DIR] [--batch DIR] [--work DIR] \
               [--encoder PATH] [--preview-edge N]
```

- `<id>` is the 64-hex source SHA-256 that `/api/items` reports; it is resolved inside `--batch`
  (default `inbox`) by re-hashing the TIFFs — the same identity rule as the API ([docs/04](04-stage-1-plan.md) M2.1). `--source PATH` skips the lookup; other than that `deliver` is source-agnostic.
- The recipe is `--recipe FILE` when given, otherwise `<work>/<source sha256>/recipe.json` — the
  file the M3 client stored. `--work` defaults to `work`; the M3 acceptance run used
  `--work work/m3/server` ([docs/06 §10](06-m3-ipad-edr-plan.md)).
- `--out` (default `out/`) is the flat delivery folder. `--preview-edge` (default 2560) only feeds
  the `previewAgreement` check. The encoder resolves as `--encoder` → `$PHOTON_ENCODER` →
  `tools/toGainMapHDR/bin/toGainMapHDR` ([docs/03 §3](03-considerations-beyond-the-plan.md)).

**Outputs** — exactly four files per delivery, one current delivery per image:

| file | content |
|---|---|
| `{stem}-hdr.heic` | gain-map HEIC written by `toGainMapHDR -b`: 8-bit P3 base, ISO `tmap` + RGB map, no alpha |
| `{stem}-sdr.heic` | the same base with the gain map stripped **by ImageIO** — the SDR fallback proof |
| `{stem}.recipe.json` | the exact recipe used (canonical bytes, posted `created` preserved) |
| `{stem}.report.json` | schema 0 verification report — the gate |

`{stem}` is the source file's base name (`R0003777-P3`). Staging is `<work>/<sha>/delivery/<uuid>/`
and is removed on success. A failing delivery installs **nothing**: the staging set plus
`report.json` move to `<work>/<sha>/rejected/<renderKey12>/` and the command exits 1 naming the
failed checks. Every installed file goes through a same-directory temp file + `rename(2)`
(`AtomicFile`), so a crash cannot leave a half-written file; the four files are not one transaction,
and the report's `renderKey` + HEIC SHA-256 make a stale pairing detectable instead of silent.

**Errors** — the existing `PhotonError` families plus one new delivery case:

| condition | error | exit |
|---|---|---|
| no item with that id in `--batch` | `sourceUnreadable` (the message names `--batch` / `--source`) | 1 |
| stored recipe missing / undecodable / out of contract | `invalidRecipe` | 1 |
| source bytes differ from the recipe's `source.sha256` (re-export) | `sourceHashMismatch` — re-hashed at decode **and** again before install | 1 |
| decoded size differs from the recipe | `dimensionMismatch` | 1 |
| non-Display-P3 source | `unsupportedSource` | 1 |
| authored peak below the encoder's 1.05 floor | `hdrTooDim` — asserted before any encode | 1 |
| encoder missing / non-zero exit / no output | `encoderMissing` / `encoderFailed` / `encoderOutputMissing` | 1 |
| encoded file fails the ImageIO read-back gate | `encoderOutputInvalid` | 1 |
| a named report check failed | `deliveryVerificationFailed(reportPath, failures)` | 1 |
| usage / unknown option | — | 2 |

**Idempotence and determinism:** re-delivery replaces the four files atomically; the same source +
recipe produces byte-identical `{stem}-hdr.heic`, `{stem}-sdr.heic` and `{stem}.recipe.json`.
`report.json` carries timings, so it is not byte-comparison material — the determinism gate covers
the two HEICs and the recipe echo. A different recipe replaces the current delivery in the same
folder, and the new report's `renderKey` + HEIC SHA-256 make the change explicit; two looks per
image are stage 2.

**Report schema 0 — `PhotonCore.DeliveryReport`** (pretty JSON, sorted keys, newline-terminated):

| field | content |
|---|---|
| `schema` | `0`; a reader refuses any other value |
| `pass` / `failures` | derived from the checks on construction **and on decode**, so a hand-edited `pass` cannot survive a re-read |
| `provenance` | tool `photon deliver`, the delivery build's `appVersion`, encoder commit, `generatedAt` (RFC 3339), host OS |
| `source` | provenance path, `sha256`, width/height, embedded profile name, bits per component |
| `recipe` | `renderKey`, `created`, `start` / `lift_stops` / `transition` / `headroom_cap`, encoder `quality` / `depth` |
| `render` | source width/height, `headroomCap`, `authoredPeak` (linear and stops), `fractionAboveOne`, `fractionAtCap`, `capEngaged`, `previewLongEdge` |
| `artifacts` | `hdrHEIC` / `sdrHEIC` / `recipeJSON`: file name relative to `--out`, bytes, `sha256` |
| `checks` | the eight checks below in report order, each `{name, status: PASS\|FAIL, detail, measured}`; `measured` values are typed number / integer / text / boolean |
| `timings` | decode, render, preview, encode, verify, total (seconds) |

The report is written into the staging set before the verdict is acted on, so the rejected evidence
folder always explains why a delivery did not install.

### 5.4 The verification report

Numeric thresholds and reject criteria live in [docs/03 §5](03-considerations-beyond-the-plan.md); this table is the full M4 check list, a superset of the M5 checks. Each check is a PASS/FAIL; all must pass for the delivery to install.

| check | PASS rule (all must hold) | what it measures |
|---|---|---|
| `container` | ISO-BMFF/HEIF byte structure; compatible brand `tmap`; `kCGImageAuxiliaryDataTypeISOGainMap` present | the dialect M0 verified; ImageIO + the `ftyp` box only, never `sips` |
| `identity` | decoded SDR dims == source dims == recipe dims; `source.sha256` == recipe `source.sha256` | provenance for the archive (sha256/renderKey/versions live in the report body) |
| `alpha` | SDR **and** HDR decodes have `alphaInfo` ∈ {none, noneSkipLast, noneSkipFirst} | decision 5 |
| `headroom` | advertised `contentHeadroom` within 5 % of `min(recipe cap, authored peak)`; authored peak does not exceed the cap by > 1e-6 | `calculatedContentHeadroom` reported as cross-check ([docs/03 §5](03-considerations-beyond-the-plan.md)) |
| `baseDeltaE` | decoded base ΔE2000 vs the 16-bit P3 base: **mean ≤ 2.5 and p95 ≤ 6.0** (8-bit LSB mean ≤ 2.5 / p99 ≤ 16 reported as cross-check) | the Capture One match of the delivered container; see the two-comparison rule in [docs/03 §5](03-considerations-beyond-the-plan.md). Measured on the trial base: mean 1.44, p95 4.12 |
| `clipping` | authored peak ≤ cap + 1e-6, authored peak ≥ 1.05, `fractionAboveOne > 0`; decode-side overshoot reported as a diagnostic, not a gate | [docs/05 §3.3](05-encoder-verification.md) |
| `fallback` | the map-stripped copy is a HEIF with **no** ISO gain map, same dims; vs the delivered SDR primary: 8-bit mean ≤ 2.5, p99 ≤ 8, ΔE2000 mean ≤ 1.0 | proves the fallback separately; the copy is what non-HDR viewers see (copy-vs-16-bit-base reported as diagnostic) |
| `previewAgreement` | the same recipe rendered at preview scale (float) vs the delivered HDR decode downscaled: ΔE2000 mean < 2.5, p99 < 10, fraction above 5 ≤ 5 % | differences confined to highlight edges; M3's preview is a rendering, not a delivery proof ([docs/06 §4.5](06-m3-ipad-edr-plan.md)). Measured on the trial data: mean 1.16, p99 5.27, 1.24 % above 5 |

The limits above are the gate; the calibration measurements behind them (M0 full-resolution deliverable vs its
bit-identical 16-bit base, and the lossless preview comparison) are recorded in
`work/m4/probe/calibration.md`. A check that cannot be evaluated (e.g. a failed HDR decode) is a FAIL with
the reason in `detail` — never an omitted check.

`tools/verify-heic` is deliberately **not** a report check: it is the independent ImageIO cross-check run at M4/M5 acceptance, and its JSON report is archived beside `{stem}.report.json`.

A check FAIL is a value, not an exception: `photon deliver` records every check, writes the report into the staging set, then either installs the four files (all PASS) or moves the staging set to `work/<sha>/rejected/<renderKey12>/` and exits 1 naming the failures (§5.3).

### 5.5 One maths, and what "preview vs delivery" means

- The renderer is `PhotonContract.HighlightShape` / `HDRRendition` — the same definition the M3 shader was parity-tested against ([docs/06 §4.5](06-m3-ipad-edr-plan.md)). M4 adds no second implementation; the only scale difference is the 2560 px mask vs the full-resolution mask.
- The delivery verifier compares the two at the same cap and reports the residual; it does not "fix up" the difference. Sub-pixel differences at highlight edges are the expected, documented outcome, and M5 is where the human judges whether they matter.

### 5.6 What M4 does not change

The M2.1 endpoints and error table, the four derived `ItemState` values, the recipe schema and `Recipe.renderKey()`, the iPad app, the 2560 px preview base and its cache key, and the 2.5 cap all stay exactly as M3 left them. Delivery state is a Mac-side fact (`report.json` + the work-folder state), not a new wire state; `rendered`/`encoded`/`verified` are stage-2 queue states ([docs/01 §2.1](../../01-app-concept-and-three-stages.md)) and must not be added to the M3 client behind its back.

---

## 6. Work packages (M4.0–M4.5, M5.1–M5.3)

| Package | Content | Deliverable / gate | Depends on |
|---|---|---|---|
| **M4.0** | Freeze §2; write this plan; set the evidence locations; align the one-line status/link edits in [docs/04](04-stage-1-plan.md), [docs/06](06-m3-ipad-edr-plan.md), README and AGENT (docs/06, README and AGENT already pointed at M4/M5, so only docs/04 needed the Next-line edit) | **Done 2026-11-03:** this document, the docs/04 next-line fix and the docs/05 M5.1 page reference; §2 decisions recorded | — |
| **M4.1** ✔ 2026-11-03 | `photon deliver` skeleton + full-resolution render from the stored recipe: identity re-hash, recipe validation, SDR base + HDR rendition, 1.05 floor, staging directory. **Starts from the recipe the iPad posted in M3** — `work/m3/server/bd486ca6…/recipe.json` (R0003777-P3: `start 0.1971 / lift 2.0151 / transition 1.0 / cap 2.5`, renderKey `0bb77468…`) | The trial image renders full-res with that recipe: base 16-bit pass-through, HDR peak == cap, specific errors for hash/recipe/dimension mismatches; the posted recipe also exercises the legal `transition = 1.0` edge | M4.0 |
| **M4.2** ✔ 2026-11-03 | Full-resolution encode via `toGainMapHDR -b`; ImageIO read-back gate; atomic install (staging first) | Full-res HEIC: ISO aux, no alpha, headroom within tolerance, dimensions match; two runs byte-identical | M4.1 |
| **M4.3** ✔ 2026-11-03 | `DeliveryVerifier` + `report.json` schema 0 + map-stripped fallback proof + preview↔delivery comparison; fail-closed install rule | Report PASS on the trial image; a deliberately defective file fails with a named check; `verify-heic` agrees | M4.2 |
| **M4.4** ✔ 2026-11-03 | Naming/archive/CLI surface/status: the flat `--out` file set; the report carries the HEIC sha256 + `renderKey` so the pairing is auditable; the delivery contract lands in this document; one-line docs updates (no wire change) | The `--out` folder holds the four files and they agree (report names the delivered HEIC's sha256 and `renderKey`); re-run idempotent; a different recipe replaces the delivery explicitly | M4.3 |
| **M4.5** ✔ 2026-11-03 | M4 acceptance on the trial image with the M3-posted recipe; determinism (two runs); `make test` regression; evidence in `work/m4/`; §10 M4 result | §1 M4 acceptance holds; `make test` green with the grown count; result recorded | all |
| **M5.1** ✔ 2026-11-03 | Visual-check tool: promote and generalise the M0 page (`work/m0/deliverable/index.html` + `work/m0/serve.py`) into `tools/visual-check/` — folder-driven (delivered HEIC, SDR copy, two look references), `image/heic` MIME + `no-store`, LAN-only | Page loads over the LAN on the iPad and every section renders; a folder argument selects what it shows; no auth, LAN only | M4.2 (a delivered file exists) |
| **M5.2** ✔ 2026-11-03 | Device acceptance: five-rung ladder, Photos View Full HDR on/off, Safari page, SDR fallback, blind A/B vs both look references, reject criteria, timings | Ladder recorded rung by rung; A/B record; no reject criterion triggers (or it is recorded and the loop returns to M3/M4) | M5.1, M4.5 |
| **M5.3** ✔ 2026-11-03 | Stage-1 closure: §10 M5 result, DoD line-by-line check, status lines updated; stop | §10 says M5 PASS (or the failure and its return path); no stage-2 work starts | all |

**Parallelism and write scopes.** M4.1 → M4.4 share `app/` (`PhotonCore`, `photon` CLI) and are sequential with one writer; the Lead serialises the package boundaries and reviews the diff. M5.1 lives in `tools/visual-check/` (plus the one-line docs edits) and can start as soon as M4.2 has produced a delivered file, in parallel with M4.3/M4.4. `tools/verify-heic/` is read-only for M4. The M5.2 device steps are the owner's — the iPad, AirDrop and Photos are not automatable; the Mac-side preparation (delivery, page, randomised A/B set, timing capture) is scripted and recorded.

---

## 7. M5 acceptance protocol

**Setup.** The iPad and lighting of [docs/06 §6](06-m3-ipad-edr-plan.md): iPad Pro (M2, Liquid Retina XDR), iPadOS 27, Reference Mode off, brightness ≈50 %, True Tone/Night Shift off, moderate room light; one pass at maximum brightness to record the headroom-bound behaviour. The Mac-side preparation is recorded in `work/m5/notes.md`: `work/m5/viewer/` holds the delivered `{stem}-hdr.heic`, its `{stem}-sdr.heic` fallback copy, the report and the two look references, served by `python3 tools/visual-check/serve.py --root work/m5/viewer`; `work/m5/ab-set/` holds the randomised blind A/B set (key in `work/m5/ab-key.json`); `work/m5/device-checklist.md` is the step-by-step protocol and the fill-in records are `ladder.md`, `ab-record.md`, `timings.json`.

**Photos.** AirDrop both HEICs; A/B by toggling Settings → Apps → Photos → View Full HDR. Judge: same SDR look as Capture One; HDR only where the recipe authored it; no glow, halo, banding or clipping.

**Safari.** The visual-check page, `<img>` of the delivered HEIC next to the SDR copy. Confirm it is not the SDR render (the highlight separation must match Photos) and that the SDR section is indistinguishable from the export.

**Ladder** ([docs/03 §5](03-considerations-beyond-the-plan.md)): record PASS/FAIL for each rung — SDR-only viewer, iPad Photos (toggle on/off), Safari 26+ page, Preview/Quick Look/Files, the target app — and name the first failing rung.

**Blind A/B.** Randomise filenames and order with a script (the key stays in `work/m5/`); ask "which looks like the print?" against the SDR base and both look references; include a second observer if available, and record who observed what.

**Reject criteria.** Apply the list in [docs/03 §5](03-considerations-beyond-the-plan.md) verbatim; any hit returns to M3 (recipe) or M4 (render), never "ship anyway".

**Evidence.** `work/m5/`: page copy, screenshots, `notes.md`, `timings.json`, the A/B key and the ladder record. Gitignored, per M3 precedent; §10 records the verdict.

---

## 8. Out of scope

Mac UI; inbox watcher; batch/queue; automatic delivery on recipe receipt; new API routes or wire states; computing `renderKey` on the client; iPad app changes; multiple delivered looks per image (the flat folder keeps one current delivery); presets, undo, numeric entry; crop/zoom; Exposure/Highlights/Shadows; local masks; additional output formats; EXIF/orientation rewrap; 10-bit output; TLS/Bonjour; App Store distribution; stage-2 features. The binding stage-1 exclusion list remains [docs/01 §1.4](../../01-app-concept-and-three-stages.md).

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| The preview and the delivered file disagree | one maths; the M3 parity gate; the report's `previewAgreement` diff; the documented 2560-vs-full-resolution edge difference instead of hiding it |
| The SDR base drifts from the Capture One look | `baseDeltaE` check against the P3 export; `fallback` proof; the HDR authoring never touches the base |
| `-R` / headroom semantics misread | ✔ M0 settled it ([docs/05 §2](05-encoder-verification.md)); the report asserts `contentHeadroom`; never `-H`; the cap is authored into the pixels |
| The file passes the tool but not the viewers | the M5 ladder is the real gate: Photos **and** Safari, SDR fallback included |
| Full-resolution delivery is memory-hungry (~5 GB peak, [docs/03 §7](03-considerations-beyond-the-plan.md)) | one delivery at a time, serialised, outside the HTTP handler; timings recorded per step |
| The report grows into a second maths / second truth | it only formats `EncodedHEICValidator` + `PhotonContract` facts; the M3 shader parity and the M4 `baseDeltaE` share one definition |
| A re-export mid-delivery pairs a stale recipe | re-hash the source before render and before install; the recipe identity must match the item id; 409 semantics upstream |
| The flat folder pairs a new HEIC with an old report/recipe | one command replaces all four files; the report names the delivered HEIC's sha256 and `renderKey`, so the pairing is checked, not assumed; the verdict is read from the report |
| Determinism is claimed but never re-checked | two-run byte comparison of `hdr.heic` in the test suite and in M4.5 |
| No capture metadata in the deliverable | recorded as a known stage-1 gap (§2); decide before any real delivery batch, not during M5 |
| Scope creep while "just testing" | §8 and the stage gates; stop after M5 ([docs/01 §1](../../01-app-concept-and-three-stages.md)) |

---

## 10. Result

**M4: PASS (2026-11-03).** `photon deliver` applies the M3-posted recipe at full resolution, encodes
the ISO `tmap` HEIC with `toGainMapHDR -b`, verifies it with the eight named checks and installs the
four files only when every check passes. The trial delivery is in `out/`; the evidence is in
`work/m4/` (`run-m4.sh` reproduces it, `deliver-run1.log`/`deliver-run2.log`,
`verify-heic-hdr.json`, `verify-heic-sdr.json`, `out-sha256.txt`, `base-check/`,
`probe/calibration.md`).

**Delivered set.** Source `samples/sources/R0003777-P3.tif` (sha256 `bd486ca6…`), recipe
`work/m3/server/bd486ca6…/recipe.json` — the recipe posted from the iPad in M3, renderKey
`0bb774682c9d178c852f085b3badf2813397485c422dc50e79efc3e0be5fb747`, `created`
`2026-11-03T11:45:38+08:00`, start `0.1971` / lift `2.0151` / transition `1.0` / cap `2.5`:

| `--out` file | bytes | sha256 |
|---|---|---|
| `R0003777-P3-hdr.heic` | 5,798,146 | `826e27599cbbd6308d7695940dd3ec463a39ea5c8814024008bd6f36efb8df69` |
| `R0003777-P3-sdr.heic` | 1,946,906 | `d639359abd87bc9c311d2f7351f79d307e34225269fc21c9236f144f96805b0e` |
| `R0003777-P3.recipe.json` | 543 | `b4cec8a2540d5fad9cc2487c58378a649312b5108ced368404d0ae5f13cc8261` |
| `R0003777-P3.report.json` | 13,650 | report: PASS, 8/8 checks |

**Gates.**

| gate | result |
|---|---|
| `cd app && make test` | **255** tests (142 `PhotonCore` + 113 `PhotonServer`), green; +26 over M2.1's 229 (delivery report/pipeline/verifier) |
| §1 item 1 — deliver from the stored recipe | `photon deliver --source …` and `photon deliver <id>` both resolve the M3 recipe and re-hash the source; hash/dimension/recipe refusals covered by `DeliveryPipelineTests` |
| §1 item 2 — base untouched | the full-resolution `sdr.tif` is **byte-identical to M1's** recorded base (`5378900171…`), so `c1_match_v1` is still a bit-exact 16-bit pass-through |
| §1 item 3 — real HDR at full res | authored peak **2.5** linear (1.321928 stops, cap engaged), `fractionAboveOne` 25.64 %, `fractionAtCap` 0.75 %; `contentHeadroom` **2.4999998** (expected 2.5, 9.5e-8 relative), no alpha in either decode |
| §1 item 4 — verified, never assumed | report PASS (8/8); `tools/verify-heic` independently PASS on the delivered HEIC (8/8 checks, `--expect-headroom 2.5 --base sdr.tif`), and the fallback copy has no ISO aux and `basePreserved` PASS |
| §1 item 5 — SDR fallback proved | `R0003777-P3-sdr.heic` is a HEIF without an ISO gain map/tmap brand; vs the delivered SDR primary mean 0.627 LSB / p99 3 / max 25, ΔE2000 mean 0.5268 (2× writes byte-identical) |
| §1 item 6 — deterministic and idempotent | two consecutive deliveries: `-hdr.heic`, `-sdr.heic` and `.recipe.json` byte-identical (hashes above); `report.json` differs only in timings |
| §1 item 7 — named and archived | exactly the four `{stem}*` files in `out/`, each installed temp-file + `rename(2)`; the report names the HEIC sha256 + renderKey, matching the installed bytes |
| §1 item 8 — no regressions | M2.1 wire contract, recipe schema 0 and `ipad/` untouched; `photon prep`/`serve` unchanged; full suite green |
| §1 item 9 — evidence | `work/m4/` holds `run-m4.sh`, both delivery logs + time/memory files, the two `verify-heic` reports, the M1-base hash check and the report; `out/` is the current delivery |
| §1 item 10 — scope | nothing outside §8; no new route, no iPad change, no EXIF rewrap |

**Report checks** (all PASS, with the measured values; the complete document is
`out/R0003777-P3.report.json`):

| check | measured |
|---|---|
| `container` | ISO-BMFF major `heic`, compatible brands `mif1, tmap, miaf, MiHB, heic`, ISO gain-map aux present |
| `identity` | 6000×4000 decoded == source == recipe; source sha256 `bd486ca6…` matches the recipe |
| `alpha` | SDR `noneSkipLast`, HDR `noneSkipFirst` — no alpha in either decode |
| `headroom` | `contentHeadroom` 2.4999998 vs expected 2.5 (5 % tolerance; 9.5e-8 relative); `calculatedContentHeadroom` 2.7451 cross-check |
| `clipping` | authored peak 2.5 ≤ cap, ≥ 1.05, `fractionAboveOne` 0.2564 > 0; decoded peak 2.99 reported as diagnostic |
| `baseDeltaE` | mean **1.4406** / p95 **4.1200** (gate 2.5 / 6.0), p99 6.54, max 28.34; 8-bit LSB mean 1.475 / p99 7 |
| `fallback` | copy 1,946,906 B, no ISO aux, no `tmap`; vs delivered SDR primary mean 0.627 LSB / p99 3, ΔE mean 0.5268 |
| `previewAgreement` | vs the float 2560×1707 preview pair: ΔE2000 mean **1.1902** / p95 3.37 / p99 5.42, 1.37 % > ΔE 5 (gate 2.5 / 10 / 5 %) |

**Timings** (release, M1 Max; from the report): decode 0.29 s + render 0.19 s + preview 0.26 s +
encode 1.22 s + verify 16.22 s = **20.73 s** end to end, peak RSS ≈ 4.6 GB (the docs/03 §7 ~5 GB
estimate holds). Two-run determinism run: 20.73 s / 20.88 s.

**Deviation recorded (M4.3).** [docs/03 §5](03-considerations-beyond-the-plan.md)'s mean ΔE2000 < 1 /
p95 < 2 is a **render** target; the delivered base is a single 8-bit 4:2:0 HEVC re-encode of the
bit-exact 16-bit base, and the measured codec loss on the trial image is mean 1.4406 / p95 4.1200
(8-bit quantisation alone accounts for ~0.268/0.59 — `work/m4/probe/calibration.md`). The report's
`baseDeltaE` gate is therefore the decoded-container rule mean ≤ 2.5 / p95 ≤ 6.0 (still catches a
colour-management or base-drift defect), and the 16-bit render target stays as stated in
[docs/03 §5](03-considerations-beyond-the-plan.md). No M4 behaviour depends on the loosened number
beyond that one check.

**Known gaps unchanged:** no EXIF/orientation rewrap (§2), no Mac UI, no queue; verification is
serial and takes ~16 s of the ~21 s delivery (§9 risk measured).

**M5: PASS (2026-11-03).** M5.1 `tools/visual-check/` (`serve.py`, `index.html`, `make-ab-set.py`,
`README.md`) serves the delivery folder over the LAN with `image/heic` + `no-store`, folder-driven
sections and the report summary; verified by curl on the real delivery (manifest classifies
hdr/sdr/reference and renders the schema-0 report: PASS, 8 checks, headroom, baseDeltaE, sizes,
timings, renderKey, HEIC sha256). M5.2 device acceptance ran on the reference iPad, Mac-side
preparation in `work/m5/` (`viewer/`, `ab-set/` + key, `device-checklist.md`), records in
`work/m5/ladder.md`, `ab-record.md`, `timings.json`:

| M5 acceptance (§1) | result |
|---|---|
| 1 — Photos **and** Safari show the intended HDR; the SDR view is indistinguishable from the Capture One export | **PASS**: Photos View Full HDR on/off and the Safari local page both render the delivered file; the SDR view matches the export |
| 2 — five-rung ladder recorded, failing rung named | **PASS**: all five rungs PASS, **first failing rung: none** (SDR-only viewer; iPad Photos on/off; Safari 26+ page; Preview/Quick Look/Files; target app) |
| 3 — blind A/B recorded | **PASS**: randomised set (seed `9900937501100669718`), observer 1 chose the delivered HDR (`P28.heic`) as most like a print; single observer, recorded as such |
| 4 — no reject criterion triggers | **PASS**: no halo/edge glow, skin shift, clipping/posterisation, banding, SDR-base change, headroom overshoot, >20 MB file or black/alpha render |
| 5 — timings recorded | full render/encode/verify from the report: **20.73 s** (decode 0.29 + render 0.19 + preview 0.26 + encode 1.22 + verify 16.22); AirDrop transfer to Photos **<5 s** (owner estimate); viewer start-up immediate |
| 6 — stage-1 DoD checked line by line | see below |

**Stage-1 DoD ([docs/01 §1](../../01-app-concept-and-three-stages.md)), line by line:**

| # | DoD item | where it was proved |
|---|---|---|
| 1 | the source is colour-managed into the linear working space and becomes a full-resolution SDR base + HDR rendition | M1 (`docs/04` M1 result); M4: `sdr.tif` byte-identical to M1's base (`5378900171…`), authored peak exactly 2.5 with the cap engaged |
| 2 | a ≤2560 px 16-bit P3 PNG base + metadata reaches the iPad, which authors HDR in-shader to the 2.5 cap and reports the overlay | M2.1 contract (`docs/04`) + M3 device acceptance (`docs/06 §10`) |
| 3 | the three controls, hold-to-compare, overlay and recipe upload work on the iPad | M3 device acceptance (`docs/06 §10`); the recipe posted there is the one M4 delivered |
| 4 | the Mac applies that recipe at full resolution, encodes with the tool, runs the verification report and writes the HEIC | M4: `photon deliver` report PASS 8/8, independent `verify-heic` PASS (§10 above) |
| 5 | the file opens in Photos **and** Safari via a local page, shows the intended HDR, and the SDR view still matches Capture One | M5: the device-acceptance table above |

**Stage-1 closure (M5.3).** The DoD is met; stage 1 stops here. No stage-2 work was started, and the
known gaps carried forward are unchanged: no EXIF/orientation rewrap (§2), no Mac UI, no queue.
The delivered trial file and its report are in `out/`; the evidence is `work/m4/` and `work/m5/`
(gitignored).
