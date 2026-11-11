---
type: reference
owner: client
updated: 2026-11-10
---

# Client Runtime

## Architecture

| Component | Responsibility | Does not |
|---|---|---|
| **Transport** (`ClientKit/Transport`) | host:port + token, health probe, HTTP, timeouts/cancellation, `code` mapping, download progress | TLS, Bonjour, retry storms, keep-alive, background tasks |
| **BaseStore** (`ClientKit/Base/BasePNG`) | 16-bit P3 PNG → validate (dimensions, no alpha, ICC) → linearise → `LinearImage`; once per item | decode a TIFF, colour conversion, resampling, modifying the base |
| **SessionModel** | settings persistence, `PhotonClient`, health, batch items, refresh, connection/refresh notices and retry | judging, full-resolution pixels, file writing |
| **JudgeModel** | select/cache, prepare→download→decode, `RecipeDraft`, three controls, compare/overlay/headroom, POST/receipt/dirty, 409 rejudge, judge notices/retry | a second wire client, file writing, `renderKey` computation |
| **Render** (v1 rebuild; prototype removed) | EDR canvas, uniforms, headroom polling, base upload gate | a second maths implementation, full resolution, encoding |
| **Recipe** (`ClientKit/Judging`) | build the draft from `recipeDefaults`; change only `hdr` + `created`; validate locally | full-resolution rendering, file writing, computing `renderKey` |

**Data flow.** `SessionModel.connect()` → `/api/health` → `refreshItems()` (`GET /api/items`);
connect persists settings and auto-reconnects on launch. Select → `JudgeModel` `POST prepare` →
`GET preview` (≈22 MB, progress) → `BasePNG.load` → cache a `Review` → sliders only update uniforms
→ hold compare → `gain = 1` on the same texture → overlay toggle → Done → build recipe from
defaults + the three edits → validate locally → `POST recipe` → 200 + `renderKey`. No disk cache; an
unsent draft is lost on quit (unscheduled).

**Filmstrip.** `ThumbnailCache.prefetch` fetches `GET /api/items/{id}/thumbnail` (512-high Display P3
HEIC) per item and decodes it with ImageIO; the preview base is only the judging canvas input, never a
thumbnail source. Thumbnails are display data — they never go through the `BasePNG` linearisation
path. The cache is two-level (memory + disk) and content-addressed: `ItemSummary.id` is the source
SHA-256, and the file name carries the render height plus a version segment, so it needs no
invalidation logic. Prefetch is view-driven (`DevelopView`'s `.task(id: session.items)`); the session
does not download on its own.

## Control model and cap/headroom semantics

| UI | Recipe field | Effect |
|---|---|---|
| **Start HDR** | `hdr.start` | mask threshold on linear Rec.709 luma |
| **Highlight lift** | `hdr.lift_stops` | gain at full mask (`2^(lift·mask)`) |
| **Transition** | `hdr.transition` | roll-off width, `smoothstep(start, start+transition, luma)` |
| **Cap** (tap the value → wheel picker) | `hdr.headroom_cap` | authoring ceiling, the only control of delivered headroom; shown in stops, stored linear |

Ranges/defaults come from `meta.recipeDefaults` and `RecipeDraft`; the UI never hard-codes a
second set (the cap default is 2 st = 2^2). The cap picker is the exception on presentation:
it offers six stops (0.5/1/1.5/2/2.5/3.0), stores `2^stops` in the schema's linear field (1…8),
and has no slider.
Reference white = 1.0; the SDR compare is the same texture with `gain = 1` — no second
decode, no second tone map. The renderer **authors** to the recipe's cap; the EDR display presents
what the current headroom allows, and the overlay uses the authored value to mark what is beyond the
display (HAGC may adapt further — expected). Legal edge cases: `lift = 0` (base), `start = 1` (no
mask), `start + transition > 1` (luma ≤ 1 keeps the mask below 1). The client validates locally
before POST; the server re-validates and re-hashes the source.

**Why three sliders plus a cap picker.** The three creative sliders change the look pixel by pixel;
the cap is a delivery decision, so it gets a discrete picker instead of a fourth continuous slider.
The picker's ceiling is what an HDR delivery can actually carry: 3.0 st = 8× is the encoder's
verified headroom ceiling ([encoder.md](encoder.md)), and the schema cap range stops at 8 for the
same reason. The EDR display's own headroom is presentation, not authoring, so the status bar
shows it in **stops** (`@ 2.0 Stops`, floored to one decimal) — the same unit as the cap picker,
which is what lets you compare "what the panel can do now" against "what I declared" directly.
Apple's HAGC adapting the presentation therefore never looks like an authoring change.

## State and errors

- **Session phase:** unconfigured → connecting → connected / error. `SessionModel.start()` silently
  reconnects when settings from a previous session exist.
- **Judge phase:** idle → loading (prepare/download/decode) → judging → posting → posted / error.
  The judge view is always present; no image / loading is expressed by `CanvasStatus` (`No image` /
  `Loading…`, see [ui/spec/judge.md](../ui/spec/judge.md)) and errors surface as an alert.
  `isShowingJudge` stays as model-level state — the app layout does not consume it; test assertions
  do.
- **Editor state:** `Review.draft`, the last accepted `PostReceipt`, `isDirty`, `comparing`,
  `overlayOn`, `displayHeadroom`, `lastRenderKey`.
- **Caches:** a session-only `reviews` dictionary (`item id → Review`); a `Review` stores the
  decoded pixels + `BaseIdentity` + draft + receipt. No disk persistence.
- **Switching items:** keeps each item's draft for the session; an in-flight load is discarded by a
  generation counter.
- **Error mapping:** `unauthorized` → back to settings; `not_found` → refresh the batch;
  `source_changed` (409) → "judge it again", one automatic re-prepare (a second 409 stops and asks
  the user); `source_unreadable` (422) → "export P3 from Capture One"; `invalid_recipe` /
  `bad_request` → keep the draft and show the field problem (bug guard); `prepare_failed` /
  `internal_error` / network → specific message + retry, keep the draft.
- **Write guards:** the draft's `source.sha256` must equal the item id; `base`/`encoder`/`versions`
  are preserved; only `hdr` + `created` change; validate before POST; never compute `renderKey`
  (the server returns it).
- **Disconnect / 401:** resets the judge and clears the session review cache; the next connect
  re-downloads.

## One maths, one parity gate

`client/Sources/ClientKit/Shaders/HighlightShape.msl` is the **only** MSL source. It ships as a
`ClientKit` package resource (`.copy("Shaders")`) and is compiled at runtime with
`device.makeLibrary(source:)`; there is no `.metal`/`.metallib` build step and no Metal toolchain
dependency (ADR-0008). `ShaderResource` is the only loader, used by the app and by
`ClientKitTests/ShaderParityTests`.

- `swift test` runs the analytic gate unconditionally (≤ 1e-4 linear error against
  `ContractKit.HighlightShape`/`HDRRendition`).
- The trial-base case is opt-in (`PHOTON_TRIAL_BASE_PARITY=1`, fixture `work/m21-final/`); with it
  on, `make parity` must report **0 skips**. A missing GPU/Metal device **fails** the gate, never
  skips it.
- A packaged-vs-checked-in sha256 test prevents the test bundle and the source from silently
  diverging.
- The preview computes the mask on the 2560 px base while `appctl deliver` computes it at full
  resolution, so sub-pixel differences at highlight edges are expected — the preview is a
  rendering, not a pixel-level delivery proof.
