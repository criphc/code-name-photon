# Stage 1 — M3: iPad EDR Judging Client

*Plan document 6 · created 2026-11-03 · inputs: [docs/01](../../01-app-concept-and-three-stages.md), [docs/03](03-considerations-beyond-the-plan.md), [docs/04](04-stage-1-plan.md) "M2.1 — the base-first contract"*
*Scope: the iPad client only. M4/M5 are [docs/07](07-m4-m5-output-and-acceptance.md); the stage-1 definition of done is [docs/01 §1](../../01-app-concept-and-three-stages.md).*

**Status:** **M3 complete (2026-11-03).** M3.0 (contract freeze + this document) and M3.1–M3.6 are done; the device acceptance passed and the result is §10. The Mac side is M0–M2.1 ([docs/04](04-stage-1-plan.md)); **nothing on the wire changed in M3** and this document does not repeat the M2.1 endpoints or error table.

---

## 1. Goal and acceptance

**Goal.** Given the SDR base the Mac serves (16-bit Display P3 PNG + `PreviewMetadata`), the iPad adjusts only the gain function's three parameters, sees a real HDR preview through EDR, and posts a schema 0 recipe back. The base pixels never change, no HDR rendition or gain map crosses the wire, the iPad writes no files and renders no full resolution.

Acceptance (M3 is done when all of these hold):

1. **Connect.** Manual host:port + token; `/api/health` is reachable; `/api/items` lists the batch; `prepare` (spinner on a cold cache) delivers the base and the metadata.
2. **Base.** With no gain the EDR canvas shows the SDR base (1.0 = reference white); hold-to-compare shows the same base; it matches the Capture One look and samples the PNG the iPad received.
3. **Real HDR.** The default recipe (`start 0.62 / lift 1.4 / transition 0.28`) lifts the sun reflections on the XDR display; midtones, skin and white walls do not change; the effect is not a global brightening.
4. **Live controls.** The three sliders update uniforms only — no re-download, no re-decode; the response feels immediate (60 fps is a stage-2 target, not a gate).
5. **Judging aids.** Hold-to-compare returns to the base; the overlay separates *authored above SDR white* from *authored beyond the currently available headroom*; both follow the sliders and the display headroom.
6. **Recipe round-trip.** Done changes only `hdr.start` / `hdr.lift_stops` / `hdr.transition` (and `created`); `source` (including the provenance-only `path`), `base`, `encoder` and `versions` are preserved; the server returns 200 + `renderKey`; 401/404/409/422/400 surface as specific messages; 409 `source_changed` forces a re-judge and is never a silent success.
7. **One maths.** The shader and `PhotonContract.HighlightShape` / `HDRRendition` agree on the **decoded PNG base** (gate: absolute error ≤ 1e-4 linear) across mask = 0/1, the cap engaged, and the threshold region.
8. **No regressions.** `cd app && make test` is **229** tests and green (it needs `tools/toGainMapHDR`; missing encoder fails by design — `docs/04` P1-5). The M2.1 contract, recipe schema 0 and the M4 delivery path are unchanged.
9. **Evidence.** Device screenshots/notes plus the parity output in `work/m3/` (gitignored); the M3 result is recorded in §10.
10. **Scope.** Nothing outside §7.

---

## 2. Decisions (2026-11-03)

| Decision | Value |
|---|---|
| Creative controls | **3**: Start HDR, Highlight lift, Transition |
| `hdr.headroom_cap` | fixed **2.5**; not a slider; the overlay reports the display end |
| Network | **TLS / Bonjour are not in M3**; manual host:port + bearer token on a trusted LAN; unscheduled |
| Client location | a new `ipad/` Xcode project (the Mac side stays in `app/`) |
| Shared contract | one no-I/O contract module: `Recipe` Codable/validation + the mask/gain maths + Rec.709 luma; the MSL shader is a port checked by a parity test |
| Preview | 2560 px base; fit-to-screen only; no crop/zoom |
| Cache | in memory for the session; no disk cache |

**Why three, not four.** A fourth "peak cap" slider was considered (the gain-map/slider session) and declined for stage 1: the delivered headroom is the constant 2.5 and Apple's HAGC adapts it per display, so a slider would conflate display adaptation with authoring and let the user mis-set the advertised headroom. If a real photograph needs a different delivered headroom, that is a recipe/M4 decision, not a preview slider.

**Why only gain.** The SDR base is authoritative; M3 may change *where* and *how much* extra brightness is authored, never the base. `mask`/`gain` are pure functions of the base luma and the three values, so the iPad can compute the preview without a baked map — and M4 bakes the same recipe into the delivered file.

---

## 3. What M3 does and does not do

**Does:** connect, list, prepare, download, decode/linearise the base, render it in EDR, apply the three gain controls, compare with SDR, show the headroom facts, post the recipe.

**Does not:** decode a TIFF, write a file, encode a HEIC, render at full resolution, carry HDR or gain-map content over the wire, retouch the base, batch, presets, undo, crop, Exposure/Highlights/Shadows, local masks, TLS/Bonjour, a Mac UI.

---

## 4. Architecture

### 4.1 Components

| Component | Responsibility | In | Out | M3 does not |
|---|---|---|---|---|
| **Session / Transport** | host:port + token settings, health probe, HTTP, timeouts/cancellation, `code` → message mapping, 22 MB download progress | user input; M2.1 API | items / meta / PNG in memory | TLS, Bonjour, retry storms, keep-alive, background tasks |
| **Library** | batch list, selection, per-item phase (trusts the server-derived state), in-session base/meta/draft cache | `/api/items` | selected item and state | disk cache, filmstrip, batch, multiple iPads |
| **BaseStore** | 16-bit P3 PNG → validate (dimensions, no alpha, ICC) → linearise → GPU texture; once per item | `GET preview` + meta | texture + base facts | decode a TIFF, client-side colour conversion, resampling, modifying the base |
| **Renderer** | EDR canvas; uniforms; the shader's mask/gain/cap; the base compare path; overlay bands; headroom query | texture + uniforms | frames | a second maths implementation, full resolution, encoding |
| **Judge UI** | canvas, three sliders, hold-to-compare, overlay, Done, status/errors | renderer + state | recipe draft | crop/zoom, presets, undo, Exposure/Highlights/Shadows |
| **Recipe** | build the draft from the defaults; change only `hdr` + `created`; validate locally; POST; handle responses | `meta.recipeDefaults` | HTTP request | full-resolution rendering, file writing, computing `renderKey` |
| **Contract** | one definition of `Recipe` Codable/validation, the mask/gain maths and Rec.709 luma (no I/O; the repo-root `contract/` SwiftPM package, linked by the Mac package and compiled into the iPad app) | — | — | any I/O |

### 4.2 Data flow

1. Launch → connection settings (host/port/token) → `/api/health`.
2. `GET /api/items` → list; each row shows the server-derived state (`pending` / `preview_ready` / `recipe_received` / `failed`).
3. Select → `POST prepare` (spinner; cold ≈1.46 s) → the prepare response carries the metadata; then `GET preview` (≈22.1 MB, with progress). A non-P3 source stops here with 422 `source_unreadable`.
4. Decode the PNG → validate → linearise → texture; draft = `recipeDefaults`; render the default recipe.
5. Slider → update the draft and the uniforms only → redraw (no network, no decode).
6. Hold → compare flag → the same texture with gain = 1; release → HDR.
7. Overlay toggle → the shader draws the two bands; the readout shows the currently available headroom.
8. Done → build the Recipe from the defaults + the three edits → validate locally → `POST recipe` → 200 / `renderKey` → "recipe sent to the Mac; M4 writes the HEIC".
9. Errors: 401 → settings; 404 → refresh the list; 409 → re-prepare and re-judge; 422 → "export Display P3 from Capture One"; 400/500 → message, keep the draft.
10. Relaunch → refetch (no disk cache in M3; the 22 MB download is accepted).

### 4.3 Control model and cap/headroom semantics

| UI | Recipe field | Range | Default | Effect |
|---|---|---|---|---|
| **Start HDR** | `hdr.start` | 0…1 | 0.62 | mask threshold on linear luma |
| **Highlight lift** | `hdr.lift_stops` | 0…4 | 1.4 | `2^(lift·mask)` |
| **Transition** | `hdr.transition` | 0.001…1 | 0.28 | `smoothstep(start, start+transition, luma)` width |
| *(no slider)* | `hdr.headroom_cap` | 1…4, fixed 2.5 | 2.5 | authoring ceiling; the only control of delivered headroom |

- `luma = 0.2126·r + 0.7152·g + 0.0722·b` on the linear P3 base (the same as `RGBA.rec709Luma`); `m = smoothstep(start, start+transition, luma)`; `gain = 2^(lift·m)`; `hdr = base·gain`, each channel clamped to 2.5.
- Reference white = 1.0. The SDR compare is the same texture with `gain = 1` — no second decode, no second tone map.
- **Authored vs presented.** The renderer authors to the 2.5 cap; the EDR display can only present what the current headroom allows; the overlay uses the *authored* value to mark what is beyond the display. HAGC may adapt further — that is expected.
- Slider ranges/defaults come from the recipe schema and `meta.recipeDefaults`, not a second hard-coded set.
- Edge cases: lift = 0 ⇒ base; start = 1 ⇒ no mask; `start + transition > 1` is legal (luma ≤ 1, the mask never reaches 1). No error.
- Validate locally (schema, ranges) before POST; the server re-validates and re-hashes the source.

### 4.4 State and errors

- **App phase:** unconfigured → connecting → connected → itemLoading (prepare/download) → judging → posting → posted / error.
- **Item phase:** use the server-derived value (`pending` / `preview_ready` / `recipe_received` / `failed`); do not keep a second truth on the client.
- **Editor state:** `draft` (Recipe), `baseline` (defaults or the last post), `isDirty`, `comparing`, `overlayOn`, `displayHeadroom`, `lastRenderKey`.
- **Switching items:** keep each item's draft for the session; no disk persistence; an unsent draft is lost when the app quits (stage 1 accepts this).
- **Error mapping:**

| `code` | UI action |
|---|---|
| `unauthorized` | back to connection settings; re-enter the token |
| `not_found` | refresh the list; explain the item left the batch |
| `source_changed` (409) | banner "the source was re-exported; judge it again"; re-prepare; never accept silently |
| `source_unreadable` (422) | "not a Display P3 source; export P3 from Capture One" |
| `invalid_recipe` / `bad_request` | keep the draft; show the field problem (should not happen — a bug guard) |
| `prepare_failed` / `internal_error` / network | specific message + retry; keep the draft |

- **Write guards:** the draft's `source.sha256` must equal the item id; `base` / `encoder` / `versions` are preserved; `source.path` stays as provenance; only `hdr` + `created` change; validate before POST; never compute `renderKey` (the server returns it).

### 4.5 One maths, one parity gate

- `HighlightShape` / `HDRRendition` (CPU, in the shared `PhotonContract` module, re-exported by `PhotonCore`) is the definition; the MSL shader is its GPU port. No third renderer. The single MSL source is `ipad/Photon/Shaders/HighlightShape.msl`; it ships as an app-bundle resource and the app compiles it at runtime (`device.makeLibrary(source:)`), so the app and the parity test cannot run different shader text.
- The parity test (`ipad/PhotonTests/ShaderParityTests.swift`) runs the same MSL source on the Mac GPU and compares it with the CPU maths on the **decoded PNG base**: a fixed fixture grid plus the trial image's base, covering mask = 0, mask = 1, the cap engaged and the threshold region. Gate: absolute error ≤ 1e-4 linear. It also pins compare mode (gain = 1) and the overlay's three-band classification against `OverlayBands`. The trial-base case needs the gitignored `work/m21-final/preview-base.png` (or `$PHOTON_M3_BASE_PNG`) and **`XCTSkip`s when it is absent** — an M3/M5 evidence run must assert 0 skips, otherwise a clean checkout stays green with the trial gate silently missing ([AGENT](../../../AGENT.md) 「绿但没跑不算证据」).
- The preview computes the mask on the 2560 px base; M4 computes it at full resolution. Sub-pixel differences at highlight edges are expected — the preview is a rendering, not a pixel-level delivery proof.

### 4.6 Contract facts M3 relies on (from docs/04 M2.1)

- `/api/health` needs no token and is non-blocking; the client uses it as the reachability probe.
- `ItemSummary.state` is derived from the artifacts; the client displays it and does not keep a parallel state machine.
- A readable but non-Display-P3 source fails `prepare` with 422 `source_unreadable`; the base PNG itself is always 16-bit Display P3, no alpha.
- `Recipe.renderKey()` excludes `created` and the provenance-only `source.path`; the client preserves both fields and takes the returned key.
- The M2.1 contract (endpoints, errors, identity/state, cache) remains the single reference; this document only describes the client.

---

## 5. Work packages (M3.0–M3.6)

| Package | Content | Deliverable / gate | Depends on |
|---|---|---|---|
| **M3.0** | Freeze the decisions in §2; create this document and [docs/07](07-m4-m5-output-and-acceptance.md); trim [docs/04](04-stage-1-plan.md) to M0–M2.1; move the stage-1 DoD into [docs/01 §1](../../01-app-concept-and-three-stages.md); align [docs/03](03-considerations-beyond-the-plan.md), README and AGENT; set the parity threshold and evidence locations | Documents consistent; no code | — |
| **M3.1** | iPad project + Session/Library + `prepare`/`preview`/`meta` + spinner/errors | On the iPad: list → prepare → base visible (SDR) | M3.0 |
| **M3.2** | PNG decode/linearise/GPU texture; EDR canvas + reference white + headroom query; the lift = 0 base view | Base matches the PNG / Capture One; no-gain view equals the base | M3.1 |
| **M3.3** | Three sliders + uniforms + live redraw; defaults/ranges from the metadata; parity test (MSL vs `HighlightShape`) | Default recipe lifts the highlights; sliders feel immediate; parity passes | M3.2 |
| **M3.4** | Hold-to-compare; false-colour overlay (authored > 1 / authored > headroom); headroom readout | The two facts are distinguishable; both follow sliders/headroom | M3.3 |
| **M3.5** | Recipe build/validate/POST; 401/404/409/422/400; `renderKey` state; the 409 re-judge flow | Server returns 200; only `hdr` + `created` differ; no false success | M3.1 (may run parallel with M3.3/M3.4) |
| **M3.6** | Device acceptance (§6); screenshots/notes in `work/m3/`; record the result in §10; [docs/07](07-m4-m5-output-and-acceptance.md) handoff | Acceptance passes; M4 can start | all |

**Parallelism and write scopes.** `ipad/` is one shared write scope and the Xcode project file has a single writer. M3.1 → M3.2 → M3.3 → M3.4 are sequential; M3.5 touches its own files and can run after M3.1 alongside M3.3/M3.4 (the Lead serialises `project.pbxproj`); M3.6 comes last.

---

## 6. Device acceptance

- iPad Pro (M2, Liquid Retina XDR, iPadOS 27), brightness ≈50 %, True Tone/Night Shift off, moderate room light ([docs/03 §9](03-considerations-beyond-the-plan.md)); the Mac runs `photon serve --batch … --work … --port … --token …`.
- Steps: connect → list → prepare → base view → default recipe → slider extremes → hold → overlay (look at the headroom at two brightness levels) → Done → confirm with curl that `/recipe` holds the expected fields; optional: re-export a source to trigger 409, and a non-P3 item to trigger 422.
- Evidence: base / HDR / compare / overlay screenshots + the parity output + a short note, in `work/m3/` (gitignored).
- Not evidence: simulator HDR, the Mac display, or screenshots without the headroom context.

---

## 7. Out of scope

TLS, Bonjour, automatic pairing; batch / filmstrip / queue; presets, undo, per-field numeric entry; crop/zoom/1:1; Exposure/Highlights/Shadows; local masks; additional output formats; HDR or gain-map content over the wire; file writing or encoding on the iPad; full-resolution rendering; a 60 fps gate; 10-bit; a Mac UI; disk cache; multiple iPads; App Store distribution. The binding stage-1 exclusion list remains [docs/01 §1.4](../../01-app-concept-and-three-stages.md).

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| The preview and the M4 delivery look different | one maths + the parity gate; M4 pixel-diffs at the same cap; this document states the 2560-vs-full-resolution edge difference |
| Wrong EDR reference white / colour space | M3.2's "no-gain base" gate before any gain; sample the PNG |
| HAGC / headroom changes with brightness and thermals | overlay + SDR compare; judge on the device at normal brightness; the preview is not a measurement |
| 22 MB download / cold prepare | spinner + progress; in-session cache; no retry storm |
| A non-P3 source is a hard failure under the new input contract | 422 `source_unreadable` maps to "export Display P3", not a generic error |
| The shared contract refactor disturbs the Mac | the contract module has no I/O; the Mac tests are unchanged; build for iOS early |
| Xcode/signing friction | install from Xcode on the device; manual acceptance; record the steps |
| Scope creep | §7 and the stage gates in [docs/01](../../01-app-concept-and-three-stages.md) |

---

## 9. Handoff to M4 (docs/07)

M4 applies the posted recipe at full resolution and encodes the gain-map HEIC. It must keep the same maths, the same 2.5 cap and the same recipe schema; it verifies the delivered file per [docs/03 §5](03-considerations-beyond-the-plan.md). The preview's job ends at the recipe; M3 never writes a deliverable.

---

## 10. Result

**M3 PASS (2026-11-03).** The iPad client is implemented in `ipad/` (app target `Photon` + macOS test target `PhotonTests`), the shared no-I/O contract moved to the repo-root `contract/` package, and the composite acceptance in §1 holds on the XDR device. Device evidence and the detailed acceptance log are in the gitignored `work/m3/` (`notes.md`, `evidence/`).

**Device.** iPad Pro 12.9-inch 6th generation (`iPad14,5`, M2, Liquid Retina XDR), iPadOS 27.0 (24A435), Developer Mode, Reference Mode **off**, brightness ≈50 %, True Tone/Night Shift off, moderate room light; the Mac ran `photon serve` (0.3.0-m21) on the LAN and the app was installed from Xcode/`devicectl` (Debug, bundle `com.criphc.Photon`). At maximum brightness the display headroom read 2.7×; at ~50 % it read 6.9–7.3×.

**Gates.**

| gate | result |
|---|---|
| Mac `cd app && make test` | **229** tests (116 PhotonCore + 113 PhotonServer), green; contract extraction kept the count identical |
| iPad `cd ipad && make test-macos` | **80** tests green at M3 acceptance (wire, transport/error mapping, recipe draft, PNG base decode, shader parity); **85** after the P0/P1 code-review fix added 5 `BaseUploadGateTests` |
| Parity (`make parity`, §4.5) | fixture grid max abs error **9.54e-07**, decoded trial base `work/m21-final/preview-base.png` (2560×1707, 4,369,920 px) **1.43e-06**, both ≤ 1e-4 linear; compare mode error 0; overlay classification at headroom 2.0 error 1.49e-08 with all three bands present; the evidence run had 0 skipped tests |
| Acceptance (device items 1–6; §1.7–§1.9 are the Mac/parity/evidence gates) | pass (connect/list/prepare/base/HDR/sliders/compare/overlay/recipe round-trip); `source_changed` (409) was not triggered on device — optional in §6, and only the transport-level 409 mapping is automated; the app's re-judge flow has no test and was not exercised, so it stays an open acceptance item; the 422 `source_unreadable` path was exercised on device with the Adobe RGB source |

**Timings / feel.** The M2.1 server figures still apply (cold prepare 1.46 s, 22,112,102 B base — [docs/04](04-stage-1-plan.md)); the device downloaded and decoded the base without stalls, and the three sliders only refresh uniforms and felt immediate (60 fps was never a gate). No full-resolution rendering, file writing or HDR over the wire occurred.

**Deviations and findings.**

1. **Hold-to-compare implementation.** SwiftUI's `DragGesture(minimumDistance: 0)` and a hand-rolled `UILongPressGestureRecognizer` overlay failed to deliver press events on iPadOS 27 in this control bar; the final control is a real `Button` whose `ButtonStyle.Configuration.isPressed` reports press begin/end, with a fixed 176×40 pt slot so neither the pill nor the bar reflows between states. Behaviour is the documented hold-to-compare (press → SDR base, release → authored).
2. **Stale-drawable redraw.** With `isPaused` + `enableSetNeedsDisplay`, a canvas resize (a banner changing the header height) did not trigger a redraw, so the previous drawable was stretched (photo aspect 1.50 → 1.64 until the next slider move). Fixed by requesting a redraw from `drawableSizeWillChange` and `layoutSubviews`; the HDR/compare photo rectangle now measures 2032×1357 vs 2030×1355 px (0.1 %, noise), and a posted banner keeps the 3:2 shape.
3. **Overlay's beyond-headroom band is unobservable on this device with the fixed 2.5 cap**: `currentEDRHeadroom` stayed above 2.5× at every brightness tried (2.7× at maximum brightness, 6.9–7.3× at ~50 %), so every authored value is presentable. The band remains implemented and is pinned by the parity test at headroom 2.0. This is a note for M4/M5 and for any later revisit of the cap, not a defect.
4. **Environment, not plan:** the Metal toolchain **is installed** (Xcode 27.2, `metal` 32023.922; `xcodebuild -showComponent MetalToolchain` reports `installed`) — but the single MSL source still ships as an app resource and is runtime-compiled by both the app and the parity test, so the two always compile the same text. From the DSH shell `metal` needs `-fmodules-cache-path`/`TMPDIR` pointed into the workspace (the harness sandbox denies the default clang module cache); this is what originally read as "toolchain unavailable". Command-line builds need `-disable-sandbox` for the Swift macro plugin server under the agent sandbox (the Makefile provides it); the signed device build needed keychain access outside the workspace file sandbox. The app and tests are otherwise normal Xcode artefacts.
5. **Scope:** nothing outside §7 was added; the peer-review follow-ups were documentation/README/AGENT updates plus the contract module extraction described in §4.1/§4.5.
