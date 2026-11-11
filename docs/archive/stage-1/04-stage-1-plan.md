# Stage 1 — M0–M2.1: Mac-Side Plan and Results

*Prepared at end of the design session; M0 executed 2026-11-02.*
*Read [doc 01 §1](../../01-app-concept-and-three-stages.md) and [doc 03 §3](03-considerations-beyond-the-plan.md) first; this file only turns them into work packages.*
*Scope: the Mac side, M0–M2.1. The iPad client is [docs/06](06-m3-ipad-edr-plan.md) (M3); full-resolution output and delivery acceptance are [docs/07](07-m4-m5-output-and-acceptance.md) (M4/M5); the stage-1 definition of done is [docs/01 §1](../../01-app-concept-and-three-stages.md).*

**Status:** M0–M2.1 complete (2026-11-02; the 2026-11-03 P1 fixes and the empty-token guard are in); M3 (iPad client) completed 2026-11-03 — result in [docs/06 §10](06-m3-ipad-edr-plan.md); M4 (full-resolution delivery + verification report) completed 2026-11-03 — result in [docs/07 §10](07-m4-m5-output-and-acceptance.md). M0 (encoder path, delivered container, recipe v0) and M1 (Mac core pipeline) are verified in [`docs/05`](05-encoder-verification.md) and the M1 result below; M2/M2.1 (LAN API: base down, recipe up) are the M2 result below. The Mac side lives in [`app/`](../../../app/README.md). **Next:** stage 1 is closed (M4/M5 results in [docs/07 §10](07-m4-m5-output-and-acceptance.md)); stage 2 is not started — its shape is [docs/01 §2](../../01-app-concept-and-three-stages.md). This file stays the M0–M2.1 record and the M2.1 API contract.

---

## Decisions (confirmed 2026-11-02)

All six are answered by the owner; they are inputs now, not questions.

1. **SDR base profile: Display P3.** Capture One P3 exports of all three sources now sit beside the Adobe RGB ones (`samples/sources/*-P3.tif`); use the `-P3` file for the P3 path so the conversion chain stays explicit. The Adobe RGB originals stay for regression comparison. **Enforced since 2026-11-03 (review P1-4):** `SourceDecoder` refuses any source that is not Display P3 (`unsupportedSource` → HTTP 422 `source_unreadable`) instead of letting 16-bit quantisation silently clamp out-of-gamut samples; the P3 export is a hard input requirement and the user-facing docs say so.
2. **Headroom cap: 2.5 linear (≈1.32 stops), enforced on the HDR rendition pixels.** ✔ M0: the command still passes `-R 2.5`, but in the `-b` path the tool **ignores `-R`**; what the delivered file advertises follows the authored peak (`AlternateHeadroom = log2(2.5) = 1.321928`, decoded `contentHeadroom = 2.4999998`). A renderer that forgets to clamp gets whatever the lift produces — see `docs/05` §2.
3. **Trial image: `samples/sources/R0003777-P3.tif`** (Ricoh GR III, 6000×4000). The highlight that must visibly improve: **sun reflections**.
4. **Encoder integration: shell out to `tools/toGainMapHDR`.** Do not port its approach while stage 1 is unproven.
5. **Alpha: none.** The delivered base must have no alpha channel; assert it in M0 and M4.
6. **Safari path: a local page.** Test the HEIC through a local web page in Safari on the iPad, not by opening the file directly from Files (used by M5 — [docs/07](07-m4-m5-output-and-acceptance.md)).

---

## Work packages

### M0 — Encoder + recipe contract (do this first, no app)

- Build a synthetic base+HDR pair with a known peak (e.g. peak 4.0 linear), run `toGainMapHDR -b` (command: doc 03 §3), and record what the file actually is: `ftyp` brands, `tmap` presence, base bit depth, alpha, headroom metadata.
- Assert per doc 03 §5: `DecodeToHDR` succeeds at the expected headroom; the decoded SDR base matches the supplied base (zero variance when the base is uniform).
- Repeat on one real pair (base = SDR tone map of `samples/sources/R0003777-P3.tif`; HDR = same with a lift that brings out the **sun reflections**).
- Open the results in Photos and Safari on the iPad — Safari via a local page (decision 6); record pass/fail per viewer.
- Confirm the delivered file has **no alpha channel** (decision 5).
- Write the **recipe v0** JSON — the only thing the iPad sends back, stored beside the output so any image can be re-rendered:

```json
{
  "schema": 0,
  "source":   { "path": "samples/sources/R0003777-P3.tif", "sha256": "…", "width": 6000, "height": 4000 },
  "base":     { "profile": "DisplayP3", "tone_map": "c1_match_v1" },
  "hdr":      { "start": 0.62, "lift_stops": 1.4, "transition": 0.28, "headroom_cap": 2.5 },
  "encoder":  { "tool": "toGainMapHDR", "quality": 0.85, "depth": 8, "subsample": false, "map": "iso-rgb" },
  "versions": { "recipe": 0, "tone_map": 1, "encoder": "5dba4e2" },
  "created":  "2026-11-02T20:52:00+08:00"
}
```

**M0 result (2026-11-02):** encoder path verified end to end on the synthetic 4.0-linear pair and on `R0003777-P3.tif` (delivered headroom 2.4999998 linear = 1.321928 stops, no alpha, base pass-through bit-exact at 16-bit). Measurements and the viewer verdict (Photos **and** Safari pass) are in [`docs/05`](05-encoder-verification.md). The M0 recipe written for the trial image is `work/m0/recipe/recipe-v0.json` (repo-local, gitignored) and is copied beside the output as `R0003777-M0.recipe.json`.

**Deliverable:** a short verification note (append to this file or `docs/05-encoder-verification.md`) + recipe schema. **Gate:** if the file does not render in Photos *and* Safari, stop and fix the encoder path — do not start M1.

#### Recipe v0 — field contract

`schema: 0` is the only accepted value; a renderer that receives another value must refuse, never guess. Recipe fields only *select* rendering; none of them may modify the SDR base pixels.

| field | type | range / value | meaning |
|---|---|---|---|
| `schema` | int | `0` | contract version; bump on any semantic change |
| `source.path` | string | repo-relative (cwd-relative when the source is under the working directory) | provenance only — never resolved blindly from JSON, and never part of `renderKey()` (P1-6: moving the repo or the same bytes to another folder must not miss the cache) |
| `source.sha256` | string | 64 hex | source identity; a re-export changes it, which invalidates recipes and caches |
| `source.width` / `height` | int | > 0 | must equal the decoded image, else refuse |
| `base.profile` | string | `"DisplayP3"` | delivered SDR base colour space (no sRGB in stage 1) |
| `base.tone_map` | string | `"c1_match_v1"` | identity pass-through of the Capture One export; changing it invalidates the SDR match |
| `hdr.start` | number | 0…1 | mask threshold as a fraction of SDR white, on Rec.709 luma of the linear working buffer |
| `hdr.lift_stops` | number | 0…4 | gain at full mask, stops above SDR white (mask 0 ⇒ 0 stops) |
| `hdr.transition` | number | 0.001…1 | roll-off width: `smoothstep(start, start+transition, luma)` |
| `hdr.headroom_cap` | number | 1.0…4.0 | absolute linear clamp on the HDR rendition — the **only** control of delivered headroom (advertised ≈ `log2(cap)` stops); `-R` does not do this |
| `encoder.tool` | string | `"toGainMapHDR"` | encoder CLI family |
| `encoder.quality` | number | 0…1 | `-q` |
| `encoder.depth` | int | `8` or `10` | `-d`; stage 1 delivers 8 |
| `encoder.subsample` | bool | `false` | `-H`; must stay false — ✔ M0 measured it corrupts the headroom metadata and clips highlights |
| `encoder.map` | string | `"iso-rgb"` | the only gain-map dialect reachable with `-b` |
| `versions.recipe` | int | `0` | duplicate of `schema` for humans |
| `versions.tone_map` | int | `1` | implementation version of the tone map named in `base.tone_map` |
| `versions.encoder` | string | tool git short sha, e.g. `"5dba4e2"` | the encoder's commit (not libheif's version) |
| `created` | string | RFC 3339 | metadata only; never affects pixels |

Semantics: `m = smoothstep(start, start+transition, luma)`, `gain = 2^(lift_stops·m)`, `hdr = base·gain`, then clamp `hdr` to `headroom_cap`. Same source + recipe ⇒ byte-identical output (M0 verified determinism of renderer, TIFF writes and encoder). Validation: reject unknown schema, out-of-range values, depth ∉ {8,10}, subsample true, dimension mismatch, or hash mismatch (a hash mismatch means a re-export: invalidate, never pair silently).

### M1 — Mac core pipeline

- `PhotonCore`: ICC read → linear P3 float32 working buffer; SDR base render (pass-through tone map for now); HDR rendition from recipe (mask on SDR luminance, lift, transition, headroom cap, no clipping).
- Deterministic output: same TIFF + recipe → identical bytes/hashes.
- Preview (development/regression artifact only): downscale to 2560 px, encode a gain-map HEIC through the tool, emit metadata JSON. M2.1 decided that the iPad receives a 16-bit P3 PNG of the **SDR base** instead (the M2.1 contract below), so `photon prep` keeps this HEIC purely as the end-to-end encoder smoke test that `verify-heic` checks — it is not part of the product data flow.
- CLI (temporary, before any UI): `photon prep <tiff> [--recipe defaults]` → `work/<hash>/{sdr.tif,hdr.tif,preview.heic,meta.json}`.
- Unit tests: mask math, headroom cap, colour round-trip (ΔE2000 of base vs. source).

**M1 result (2026-11-02):** `app/` is a SwiftPM package (`PhotonCore` library + temporary `photon` CLI), 82 tests green, and the real trial image goes through it:
- `sdr.tif` **byte-identical** to the M0 prototype's independently written base (`sha256 5378900171…`) — `c1_match_v1` is a true bit-exact 16-bit pass-through.
- `hdr.tif` **byte-identical** to M0's (`sha256 ea3d888c…`): authored peak exactly 2.5 linear (1.321928 stops), 10.94 % of pixels > 1.0, 0.431 % at the cap, no clipping below it.
- `preview.heic` 881,253 B (2026-11-03: 882,091 B before the Lanczos edge fix — see the P1 note below), 2560×1707, `verify-heic --expect-headroom 2.5` PASS (7/7), `contentHeadroom = 2.5000`, decoded peak ≈ 2.93×.
- Determinism: repeated runs give identical `sdr.tif` / `hdr.tif` / `preview.heic` bytes (Lead 2 runs, teammate 14 runs); only `created`/timings in `meta.json` differ. `Recipe.renderKey()` ignores `created` and the provenance-only `source.path`; the source identity (`sha256`, `width`, `height`) still enters the key (P1-6).
- Release pipeline: ~3 s and ~5.2 GB peak RSS for 6000×4000 (docs/03 §7's 4–6 GB estimate holds).
- One integration bug found and fixed: Core Image's `CIImage(bitmapData:)` does not own its buffer, so the preview's first Lanczos render could read freed memory (a 25 % RMSE preview and a 149× decoded peak in 1 run of 4). The preview path now uses a CGImage/provider-owned buffer; the gotcha is recorded in `docs/03` §3. (P1-3, 2026-11-03: `TIFFWriter.writeHDR` was the last remaining bitmap-data call — both it and the 16-bit base assembly now go through `ImageBuffers`/`SDRBaseCGImage`.)
- Evidence (gitignored): `work/m1-integration/` (`run1/`, `run2/`, `preview-verify.json`); CLI usage and package layout in `app/README.md`.
- Encoding is verified, not assumed: `photon prep` refuses to encode a rendition whose authored peak is below **1.05** (`PhotonError.hdrTooDim` — below that the tool silently writes a plain SDR HEIC and exits 0, `docs/05` §6 item 3), and every encoded HEIC is read back with ImageIO before it replaces `preview.heic`: ISO gain-map auxiliary data present, `contentHeadroom` within 5% of the authored peak, no alpha, expected dimensions (`PhotonError.encoderOutputInvalid`). `EncodedHEICValidator` is the shared assertion the M4 delivery report reuses.
- **P1 (2026-11-03):** the eight P1 findings that touch the M1 pipeline are fixed and covered by tests: Lanczos no longer samples past the source extent (frame edges keep the constant; preview is 881,253 B instead of 882,091 B and still passes `verify-heic` with the same `sdr.tif`/`hdr.tif` hashes), the HDR float TIFF uses the provider-backed buffer route, TIFF and PNG share one 16-bit P3 assembly, non-Display-P3 sources are refused at decode, the default recipe records a cwd-relative provenance path that is excluded from `renderKey()`, and `preview.heic`/`meta.json`/`preview-base.png` are replaced by `rename(2)` (`AtomicFile`) instead of remove-then-move. The integration tests now **fail** when `tools/toGainMapHDR` is missing instead of silently skipping (P1-5).

### M2 — Mac server + transport

- HTTP endpoints: list batch, get preview, get metadata, post recipe, get status.
- Cache keyed by source hash + recipe version; re-export detection by hash.
- Test with `curl` before any iPad code exists.

**M2 result (2026-11-02, corrected as M2.1 the same day):** `photon serve` runs the LAN HTTP API for the judgement loop — **base down, recipe up**. It is a SwiftPM target (`PhotonServer`, no third-party dependencies).
- **Measured (release, 6000×4000 trial image):** `/api/health` 0.007 s; first batch `GET /api/items` 0.68 s (SHA-256 of six sources, ≈1.1 GB), later listings 0.002 s; cold `POST prepare` **1.46 s** (decode → Lanczos → 16-bit PNG; M2's full HDR pipeline was 3.10 s); warm `prepare` 0.095 s (source + PNG re-hash); `GET preview` 22,112,102 B / 0.12 s on loopback (P1-2's Lanczos edge fix changes a few border pixels; the pre-fix figure was 22,111,140 B); `/meta` 1.5 KB.
- **Tests:** **229** (116 `PhotonCore` + 113 `PhotonServer`: codec 39, server 14, router 22, store 26, serve-token 12). `PhotonServer`/M2 tests have no encoder dependency, but `make test` as a whole now does: the integration tests fail when `tools/toGainMapHDR` is missing (P1-5, no silent skips).
- **Empty-token guard (M2, 2026-11-03):** `--token ''` (or a whitespace-containing value) is a usage error; an empty `$PHOTON_TOKEN` is treated as unset and a token is generated; `ServerConfig` refuses an invalid token, so `photon serve` can never reach the router's empty-token branch.
- **Deliberately out of M2:** TLS/Bonjour (not in M3 either — unscheduled; [docs/06](06-m3-ipad-edr-plan.md)), folder watcher (stage 2), full-resolution render of a posted recipe (M4 — the recipe is stored and validated, not applied), one prepare at a time.

#### M2.1 — the base-first contract (canonical home; every other doc points here)

**Decision (2026-11-02):** the iPad receives the **SDR base**, not a rendered HDR HEIC. A gain map is a ratio with one recipe baked in, and `mask`/`gain` are pure functions of the base luminance and the three controls — so a baked map can neither be re-modulated accurately nor serve the judging loop. M2 therefore transports a 16-bit Display P3 PNG of the base plus `PreviewMetadata` (source identity, base facts, recipe defaults); the iPad computes HDR in-shader and only the recipe travels back. The delivered gain-map HEIC is still produced by the Mac at full resolution with the final recipe (M4); the default-recipe preview HEIC that `photon prep` writes is a development/regression artifact checked with `verify-heic`, and is **not** part of the M2 API.

| endpoint | meaning |
|---|---|
| `GET /api/health` | reachability + item count (no auth); `authRequired` reflects whether a token is configured; the count is a cached file count that does not take the store lock (P1-8) |
| `GET /api/items` | the batch: `{items:[ItemSummary]}` sorted by name |
| `GET /api/items/{id}` / `.../status` | one item (same shape) |
| `POST /api/items/{id}/prepare` | idempotent render of the **SDR base preview**; returns `{item, meta, cached}` |
| `GET /api/items/{id}/preview` | 16-bit Display P3 PNG base bytes (prepares on a cold cache) |
| `GET /api/items/{id}/meta` | `PreviewMetadata` JSON (prepares on a cold cache) |
| `GET /api/items/{id}/recipe` | stored recipe, 404 when none |
| `POST /api/items/{id}/recipe` | validate + store a recipe; returns `{item, recipe, renderKey}` |

**Transport and auth:** HTTP/1.1 over Network.framework, one request per connection, 64 KiB header / 4 MiB body limits, JSON error bodies. Every route except `/api/health` needs `Authorization: Bearer <token>` (or `X-Photon-Token`); the token comes from `--token`, `$PHOTON_TOKEN`, or is generated and printed at startup. An explicit `--token` that is empty or contains whitespace is a usage error; an empty `$PHOTON_TOKEN` is treated as unset and a token is generated; `ServerConfig` refuses a token that is not presentable (`ServeToken`). Timeouts are scoped to the connection, never to the handler: a request that stops arriving gets 400 after 10 s of **inactivity** (the deadline resets on every received chunk and is cancelled the moment the request parses), so a queued or slow `prepare` cannot turn a valid request into a 400; a handler that has not answered 600 s after dispatch gets 500 `internal_error` and its late result is dropped. Framing is decided from the header block: a declared body over 4 MiB gets 413 as soon as the headers arrive (the body is never buffered or awaited), LF-only framing gets 400 immediately rather than at the inactivity deadline, and every value of every `Transfer-Encoding` header must be `identity` (otherwise 501) — all three were P1-10. TLS and Bonjour are not in M3 and remain unscheduled (`docs/03` §6); [docs/06](06-m3-ipad-edr-plan.md) records the decision.

**Identity and state:** item id = SHA-256 of the source bytes, never a path. `work/<sha>/` holds `preview-base.png`, `preview-meta.json`, `state.json` and a posted `recipe.json`. Lifecycle `pending → preview_ready → recipe_received` (or `failed` + `lastError`). The reported state is **derived from the artifacts**, never from a hand-written flag (P1-1): a valid preview pair plus a decodable `recipe.json` → `recipe_received`; a preview pair alone → `preview_ready`; neither and a recorded failure → `failed`; otherwise `pending`. Hence a POSTed recipe does not by itself claim `preview_ready` (recipe-before-prepare reads `pending` with `hasRecipe: true` and both observers agree), deleting or corrupting `recipe.json` falls back to `preview_ready`, and a failed `prepare` cannot hide an intact preview (`failed` only when there is no usable preview; `lastError` stays in `state.json` as diagnostics). A re-export is a new id, and a recipe for the old bytes is refused with 409 `source_changed` — enforced by re-hashing the source in **both** `prepare` and `POST …/recipe` before any cache or recipe decision.

**Errors:** JSON `{"error":{"code":"…","message":"…"}}` with `code` one of `unauthorized`, `not_found`, `method_not_allowed`, `bad_request`, `invalid_recipe`, `source_changed`, `source_unreadable`, `prepare_failed`, `internal_error`. Status mapping: 401 / 404 / 405 / 400 / 409 / 422 / 500; `bad_request` is also the protocol-layer code (malformed request 400, oversized headers/body 413, unsupported transfer coding 501). `source_unreadable` (422) also covers "readable but unsupported": a non-Display-P3 source is refused at decode (P1-4) with an actionable message, not clamped and reported as a 500 `prepare_failed`. Curl matrix verified: 200 for health/list/prepare/preview/meta/recipe; 401 without or with a wrong token; 404 unknown id/route; 405 with `Allow`; 400 `invalid_recipe` (schema 7); 409 `source_changed` (wrong source sha); 422 `source_unreadable` (Adobe RGB source).

**Cache:** the base preview is recipe-independent and hits only when the source sha, `appVersion` (0.3.0-m21), the preview long edge and the PNG's recorded sha all still match; `prepare` re-hashes the source before serving a cache hit and `POST …/recipe` re-hashes before accepting a recipe — measured: an in-place rewrite that preserved size, mtime and inode still produced 409 `source_changed` and a refreshed id (`docs/03` §6). The M4 recipe half of the key, `Recipe.renderKey()`, is SHA-256 over the canonical render JSON: `schema` + source identity (`sha256`, `width`, `height`) + `base` + `hdr` + `encoder` + `versions`; `created` and the provenance-only `source.path` are excluded (P1-6), so relocating the repository or the same bytes does not miss the cache. Nothing persisted consumes `renderKey()` yet (M2.1 only records it in `state.json`), so the P1-6 change needs no `appVersion` bump. `/api/health`'s `itemCount` is an advisory cached file count refreshed by list/prepare scans and never takes the store lock, so it may lag a folder change until the next scan (P1-8). Every sidecar, the base PNG and `preview.heic` are replaced with temp file + `rename(2)` (`AtomicFile`), so a reader never sees a partial artifact (P1-7).

**Scope and exclusions:** the binding stage-1 list is [doc 01 §1.4](../../01-app-concept-and-three-stages.md); this file records the Mac side (M0–M2.1) only.

---

## Risks to watch

| Risk | Mitigation |
|---|---|
| The SDR base drifts from the Capture One look | compare on the iPad with the Capture One export side by side; ΔE check; never let the HDR authoring touch the base |
| The tool's colour handling disagrees with our working space | M0 on a real pair; `-c p3` explicitly; fall back per doc 03 §3 |
| `-R`/headroom semantics are misread | ✔ M0 settled it: `-R` is a no-op with `-b`, `-H` writes wrong metadata and clips; the renderer clamps the HDR pixels (`docs/05` §2) |
| Scope creep while "just testing" | stage gates above; stage 2 features are named and deferred |

---

## Next

This file stays the record of the Mac side (M0–M2.1) and the M2.1 API contract. M4 and M5, and with them stage 1, are recorded in [docs/07 §10](07-m4-m5-output-and-acceptance.md).
