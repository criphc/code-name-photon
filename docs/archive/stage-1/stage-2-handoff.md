---
type: record
owner: docs
updated: 2026-11-05
---

# Stage-2 Handoff — What Exists, What Is Open

*Created 2026-11-03, the day stage 1 closed. Stage 2 has not started.*
*Read this first when planning stage 2; then the product goal in [design-01 §2](design-01-app-concept-and-three-stages.md).*
*Companion docs: [01 — concept and stages](design-01-app-concept-and-three-stages.md) · [02 — the quick guide](design-02-hdr-highlight-finisher-workflow.md) · [docs index](../README.md)*

---

## 1. What exists today (stage 1, closed)

One photograph goes around the loop on real hardware: Capture One **Display P3** 16-bit TIFF → Mac
renders the SDR base + HDR rendition at full resolution → the iPad judges a ≤2560 px base through EDR
with three gain controls and posts a schema-0 recipe back → `appctl deliver` applies that recipe, encodes
the gain-map HEIC with `tools/toGainMapHDR -b`, verifies it with eight named checks, and atomically
installs four files. The delivered file was accepted on the reference iPad in Photos (View Full HDR
on/off) and Safari, with no reject criterion triggered.

| Piece | Entry point | Contract home |
|---|---|---|
| Mac pipeline + delivery | `server/` (`EngineKit`, `appctl prep` / `serve` / `deliver`) | [deliver.md](../reference/deliver.md) |
| Shared contract (no I/O) | `contract/` (`ContractKit`: `Recipe`, mask/gain maths, Rec.709 luma) | [recipe.md](../reference/recipe.md) |
| iPad judging client | `client/` package + `apps/ios` (`PhotonClient`) | [client.md](../reference/client.md) |
| Encoder (external MIT clone) | `tools/toGainMapHDR/` | [encoder.md](../reference/encoder.md) |
| Independent container verifier | `tools/verify-heic/` | [verification.md](../reference/verification.md) |
| Acceptance page / blind A/B | `tools/visual-check/` | [tools.md](../reference/tools.md) |
| Stage-1 history, evidence, trial delivery | `docs/archive/stage-1/` | [../archive/stage-1/MANIFEST.md](../archive/stage-1/MANIFEST.md) |

## 2. Verification baseline (run these before changing anything)

```bash
# encoder must be present: make test FAILS (not skips) without it
make test                               # contract + server + client; counts are informational
make parity                             # MSL vs ContractKit, ≤1e-4 linear; 0 failures, 0 skips
make ios-build                          # apps/ios compile check (normal terminal / CI)
make appctl                             # .build/server/debug/appctl
```

- The trial-image cases (`make parity`, `BasePNGTests`) read the gitignored
  `work/m21-final/preview-base.png` and `work/m21-final/meta.json`. That fixture is **kept on
  purpose**; on a clean clone those cases `XCTSkip`, so an evidence run must assert 0 skips (a plain
  `make test-macos` has exactly one expected skip: the opt-in trial-base parity case).
- Test *counts* are not acceptance criteria. The suite is pruned whenever new tests make older ones
  overlap (`AGENTS.md`「工作规则」), so the number moves in both directions. What must hold is
  "green, no unexpected skips, and the report gate below still passes".
- A stage-2 change is not done until these are green *and* the delivery/report contract in
  `docs/reference/deliver.md` still holds (the report is the gate: all eight checks PASS ⇒ install, else nothing).
- Scratch lives in the gitignored `work/` (per-image `work/<sha>/`); deliverables default to `out/`.

## 3. Open items and known gaps

Ordered by how soon stage 2 will hit them. None of these is a stage-1 defect.

| # | Item | Why it matters / what stage 2 must do |
|---|---|---|
| 1 | **No EXIF/orientation rewrap.** The delivered HEIC carries pixels + ISO gain map only. | Before any real delivery batch: decide and implement a `CGImageDestination` rewrap (the Core Image writers cannot attach metadata). Own risk; not needed for the stage-1 DoD. |
| 2 | **No Mac UI, no queue, no inbox watcher.** Delivery is an explicit `appctl deliver` after judging. | This *is* stage 2's core. Queue states `rendered`/`encoded`/`verified` are new wire states: adding them must not break the M3 client's closed `ItemState` enum behind its back. |
| 3 | **Verification is serial and takes ~15.8 s of the ~20.7 s per image.** | 20 images ≈ 5+ minutes of pure verification. Budget/parallelise/trim it; measure with the report's `timings`. |
| 4 | **Batch encoding must loop the CLI per image.** `heic_hdr.py` batch mode cannot pass `-b`. | The stage-2 batch driver calls `toGainMapHDR -b` once per image with its own base — do not attempt a single batch invocation. |
| 5 | **409 `source_changed` re-judge flow is not tested on the device.** Only the transport-level mapping is automated. | A batch that re-exports a source will hit this; add the device/automated test, and make the queue treat it as "judge again", never as success. |
| 6 | **No TLS, no Bonjour.** Manual host:port + bearer token on a trusted LAN. | If stage 2 adds auto-pairing/QR, that is a scheduling decision. Never expose the server beyond the LAN as-is. |
| 7 | **iPad has no disk cache and no draft persistence.** Relaunch re-downloads ~22 MB per item and loses unsent drafts. | Stage-2 filmstrip/ergonomics needs a cache keyed like the Mac's preview cache (source sha + app build + edge). |
| 8 | **"Authored beyond display headroom" is unobservable on this device** (display headroom stays ≥ 2.7× at every brightness against the 2.5 cap; figures:
[hardware.md](../reference/hardware.md)). Implemented and pinned by the parity test at headroom 2.0. | Revisit only with a headroom simulator, a different display, or a cap change — do not "fix" it blind. |
| 9 | **Two `appVersion` constants**: server `0.3.0-m21` (preview cache key) and delivery `0.4.0-m4` (report provenance). The reason lives only in code comments. | Decide whether stage 2 unifies them or documents both; the preview cache key must keep changing when the preview code changes. |
| 10 | **One delivered look per image.** A new recipe replaces the four files in the flat `--out` folder; the report's `renderKey` + HEIC sha256 make the swap auditable. | Multiple looks per image, or a shoot folder layout (`01_capture/…`, [operations.md](../reference/operations.md)) is a stage-2 design decision. |

## 4. Decisions stage 2 should re-open deliberately

- **Delivered dialect**: ISO 21496-1 only. A legacy Apple gain map buys reach in third-party apps at
  the cost of the Capture One base ([container.md](../reference/container.md)). Only revisit if photos
  leave the owner's Apple devices.
- **The 2.5 headroom cap** is fixed by the recipe, not a slider; it is also why item 8 above is
  unobservable. Changing it is a recipe/M4 decision, not a preview control.
- **Preview resolution**: fit-to-screen 2560 px only. Stage 2's crop inspector / 1:1 judging needs a
  bandwidth and memory plan before it needs code.
- **Stage-1 acceptance protocol** (five-rung viewer ladder, blind A/B, reject criteria) is archived;
  `docs/reference/tools.md` still describes the page. Reuse it as the regression check: stage-2
  DoD explicitly says no regressions in the stage-1 acceptance tests
  ([design-01 §2](design-01-app-concept-and-three-stages.md)).
