---
type: record
owner: docs
updated: 2026-11-05
---

# HDR Highlight Finisher — What the App Should Be Like

*Design document 1 · derived from the planning session `session-edbdb902` (2026-11-02)*
*Companion docs: [02 — the quick guide](design-02-hdr-highlight-finisher-workflow.md) · [docs index](../README.md) · [stage-2 handoff](stage-2-handoff.md). Stage-1 plans, results and evidence are archived in [docs/archive/stage-1/](../archive/stage-1/)*

---

## 0. The plan as discussed, in one page

### The constraint

Your editing software has no HDR pipeline and your Mac (M1 Max + Studio Display) cannot display HDR. You do have an **M2 iPad Pro with a Liquid Retina XDR display** (600 nits SDR / 1000 nits full-screen HDR / 1600 nits peak HDR). Delivery target: **gain-map HEIC**, viewed on **Apple devices only** — primarily Photos and Safari.

### The key correction from the session

A 16-bit SDR TIFF exported from Capture One (stage 1 uses the Display P3 export) is *display-referred*: 65535 = SDR white, and everything brighter is already clipped. It is **not** an HDR source. The app therefore cannot "recover" extra highlight brightness; it must **author** it. That is fine — but it defines the app:

> **This is not an HDR converter. It is an HDR highlight finisher.**
> The Capture One TIFF remains the authoritative SDR photograph. The app decides *where* and *how much* extra brightness is added on top of it for HDR-capable displays, and guarantees that the SDR image still looks like the Capture One export.

Your answers in the session fixed the remaining degrees of freedom:

| Question | Answer | Consequence |
|---|---|---|
| Where will the HEICs be viewed? | Apple devices only (Photos, Safari) | One delivery format, one viewer matrix |
| What should the SDR version look like? | Closely match the Capture One export | SDR is a *constraint*, not a free variable |
| What kind of HDR? | Two look references: `fixtures/media/reference/IMG_7097.HEIC` (iPhone HDR HEIC) and `IMG_7473.JPG` (added later) — textured highlights, restrained | Highlight-only lift, not global brightness |
| Are highlight areas textured? | Almost always, unless shot flat | The source has usable highlight structure to lift |
| Hardware | iPad M2 XDR (iPadOS 27), Mac M1 Max (macOS 27.2, SDR-only) | iPad judges; Mac renders; Mac cannot visually verify |
| Personal tool or product? | Personal tool | Can assume one Mac, one iPad, one user, one network |

### The revised architecture the session settled on

1. **The Mac is the colour-managed rendering authority.** Read the embedded Display P3 profile, convert to a **linear extended Display P3 working space** (float, no clipping), and derive the SDR base so it matches the Capture One look as closely as the delivery format allows. Stage 1 refuses non-P3 sources instead of silently clipping them ([colour.md](../reference/colour.md)).
2. **The iPad is a judging and control surface, not an editor.** It never decodes a 270 MB TIFF, never touches the filesystem, and never saves a file. It gets a ≤2560 px preview, displays it through the XDR display's EDR path, and lets you decide on three creative controls.
3. **Only a versioned recipe travels back.** Source identity + control values + tone-mapping version + intended SDR base. The Mac renders full resolution, produces the SDR base and the HDR rendition, and **hands that pair to an existing tool that already writes gain-map HEICs** (`toGainMapHDR`, details in [encoder.md](../reference/encoder.md)) rather than implementing the container itself.
4. **Two separate acceptance tests.** Looking right in the app proves nothing about delivery: the exported file must be opened in **Photos and in Safari on the iPad**, and each must show the intended result.
5. **Prove the export before building the editor.** The single highest-risk step is "a gain-map HEIC that Photos and Safari actually render the way the iPad preview promised". A working base+HDR→gain-map CLI is already in the workspace, so this is a *validation* task with one photograph — not a build task — and it comes before any UI polish.

### The control set the session converged on

Three creative controls, deliberately not a general editor:

- **Start HDR** — how bright a region must be before it receives extra brightness (the mask threshold, expressed as a fraction of SDR white).
- **Highlight lift** — how much extra brightness it receives (maximum gain in stops above SDR white).
- **Transition** — how gently the effect rolls into surrounding midtones (roll-off width).

Plus two *judging* aids that are **not** creative sliders:
- **SDR↔HDR hold-to-compare** — shows the actual proposed SDR base vs. the HDR rendition.
- **Headroom warnings** — separate the two different facts: *pixels authored above SDR white* (in stops) and *pixels beyond the display headroom currently available*.

Exposure / Highlights / Shadows are explicitly **out of the initial scope**: if they change the SDR rendition you lose the Capture One match; if they change only HDR they overlap with the three controls above. They are stage-3 candidates, to be added only when a real photograph exposes a specific need.

---

## 1. Stage 1 — Prototype: one photograph, end to end

**Goal:** prove the pipeline is real, and that the delivered file looks like the preview. Not smooth, not pretty, not fast.

**Status:** **met 2026-11-03** — the line-by-line check and the device verdict are archived in [docs/archive/stage-1/07-m4-m5-output-and-acceptance.md §10](../archive/stage-1/07-m4-m5-output-and-acceptance.md); stage 1 stops there and the record is now historical.

**Definition of done:** one photograph goes around the loop once, and the delivered file — opened in Photos *and* Safari on the iPad — shows an SDR view indistinguishable from the Capture One export, and an HDR view that is *better*, not merely brighter. In order:

1. `fixtures/media/sources/<one>.tif` is ingested by the Mac app, colour-managed to a linear working space, and turned into two full-resolution images: the **SDR base** (must look like the Capture One export) and the **HDR rendition** (authored highlight lift from the recipe).
2. A ≤2560 px **16-bit Display P3 PNG of the SDR base** plus its `PreviewMetadata` reaches the iPad; the iPad computes `hdr = base · 2^(lift·mask(luma))` in-shader, authors to the recipe's 2.5× cap and presents it within the headroom available at that moment; the overlay reports what is beyond it (the base-first decision — [wire.md](../reference/wire.md), "M2.1 wire contract"). The default-recipe `preview.heic` that `appctl prep` writes is a development/regression artifact, not part of the delivery path.
3. On the iPad: **Start HDR / Highlight lift / Transition** change the HDR preview; **hold-to-compare** shows the SDR base; the headroom overlay distinguishes authored-above-white from beyond-display-headroom; **Send recipe** posts a versioned JSON recipe back ([client.md](../reference/client.md)).
4. The Mac applies the recipe at full resolution, encodes with the tool ([encoder.md](../reference/encoder.md)), runs the verification report, and writes the HEIC ([deliver.md](../reference/deliver.md), delivery contract).
5. The file opens in **Photos** and in **Safari on the iPad via a local page**, and both show the intended HDR with an SDR view that still matches Capture One ([deliver.md](../reference/deliver.md), delivery contract).

The stage-1 milestone plans and results (M0–M5) are archived in [docs/archive/stage-1/](../archive/stage-1/).

### 1.1 Mac: preview preparation

- Import one 16-bit Display P3 TIFF and colour-manage it into a linear extended Display P3 working space in float, without clipping (non-P3 sources are refused, not clipped: [colour.md](../reference/colour.md)).
- Render the **SDR base** that reproduces the Capture One look, plus a ≤2560 px **16-bit Display P3 PNG** of that base for the iPad. The Mac does **not** send an HDR rendition or a gain-map file over the wire: the iPad authors HDR from the base and the three controls (decision and contract: [wire.md](../reference/wire.md), "M2.1 wire contract").
- Record the source path and hash so any recipe can be replayed later.

### 1.2 Mac: gain-map generation

The encoder is already solved: `tools/toGainMapHDR` takes the SDR base plus the HDR rendition and writes the gain-map HEIC. Use it; do not write a container writer.

- Command, flags, verified behaviour, caveats and the Core Image fallback: **[encoder.md](../reference/encoder.md)**.
- Stage-1 gate (archived): smoke-test it on one real pair and open the result in Photos and Safari before any app work, because the container is the project's highest-risk step.

### 1.3 iPad: EDR preview and HDR controls

- The iPad receives the SDR base PNG plus metadata (source identity, recipe defaults), computes `hdr = base · 2^(lift·mask(luma))` in its shader, authors to the recipe's 2.5× cap, and shows it in EDR within the headroom available at that moment; the overlay reports what is beyond it. It never decodes the TIFF and never saves a file (details: [client.md](../reference/client.md)).
- Three controls — **Start HDR**, **Highlight lift**, **Transition** — plus hold-to-compare and a headroom overlay that separates authored-above-white from beyond-display-headroom.
- Only a versioned recipe returns to the Mac.

### 1.4 Explicitly excluded from stage 1

Watched inbox folder, batch of 20, filmstrip, 60 fps, presets, undo history, pairing UI, zoomed crop inspection, any output format other than one HEIC. Each is a stage-2 or later concern; none can rescue an unsuitable source or an incompatible encoder. This list was binding for the stage-1 milestone plans ([docs/archive/stage-1/](../archive/stage-1/)); stage 2's own exclusions belong to its plan.

---

## 2. Stage 2 — Quality of life: batch, ergonomics, performance

**Goal:** make it pleasant to run a real shoot's worth of images through the finisher. Nothing new about *what* the image is; a lot about *how* the tool behaves.

### 2.1 Batch processing

- **Watched inbox folder**: drop Capture One exports in, Mac ingests them (the original plan's 20-at-a-time batch).
- **Queue with per-image state**: pending → preview ready → editing → recipe received → rendered → encoded → verified → done/failed. Visible, resumable, and survives a Mac or iPad restart.
- **Background preview preparation**: overlap decode/preview/gain-preview generation so the iPad always has the next image ready; show a small thumbnail grid/filmstrip.
- **Batch render**: apply the current or per-image recipe to all queued images, run the verification report on each, and report failures instead of silently producing bad files.
- **Re-export invalidation**: a re-exported TIFF must be flagged as changed, never silently paired with a stale recipe (invalidation rules: [operations.md](../reference/operations.md)).

### 2.2 UI ergonomics on the iPad

- Filmstrip with progress and state badges; jump between images without losing recipes.
- **Copy/paste settings** and "apply to selection" for a consistent look across a series.
- Undo/redo for control changes; tap-to-reset each slider; numeric read-out of stop values.
- **Hold-to-compare** and a **before/after split**; a zoomed crop inspector for tiny highlights (essential: a 1–2 px specular highlight is invisible at fit-to-screen).
- Connection status, reconnect, and clear failure messages ("Mac asleep", "TIFF moved", "render failed at step X").
- Save named recipes/presets, and see which recipe version a file was made with.

### 2.3 Performance

- 60 fps interaction on preview-sized buffers (the original plan's target now applies, once the pipeline is proven).
- Tiled/lazy preview decoding, GPU-resident textures, no per-slider re-upload.
- Cache previews so re-opening is instant and a re-export cannot show a stale preview.
- Parallel full-resolution renders on the Mac, memory-aware for a batch of large TIFFs.
- Encode + verification time budgeted per image so batch throughput is predictable.

**Stage-2 definition of done:** a folder of ~20 images goes from export to verified HEICs in one sitting, with clear per-image state, no manual path juggling, and no regressions in the stage-1 acceptance tests (the archived five-rung viewer ladder / blind A/B / reject criteria remain the regression check; see [stage-2-handoff.md §4](stage-2-handoff.md)).

---

## 3. Stage 3 — Feedback-driven extension

**Goal:** grow the tool only where real photographs and real use demand it. The session deliberately refused to guess this list; these are candidates, not commitments.

- **Exposure / Highlights / Shadows controls.** The most likely first addition, but they need a defined contract: either they act *only* on the HDR side (and must not disturb the Capture One SDR match), or they act on both — which is a different product decision. Add one only when a real image shows the three existing controls cannot express what you want.
- **Larger / full-resolution preview.** 1:1 tiled inspection on the iPad, or full-resolution "judge the actual pixels" mode, with bandwidth and memory implications.
- **Additional deliverables.** SDR-only JPEG alongside the HEIC; AVIF gain map (the machine already has `avifgainmaputil`); a web-page sRGB/PNG fallback; print-ready TIFF.
- **More refined judging tools.** Luminance histogram of authored HDR, per-region readouts, gain-map visualisation ("show me the gain map itself"), and a headroom simulator ("what does this look like on a 600-nit phone?").
- **Workflow hooks.** Shortcuts/AppleScript automation, Export from Capture One straight into the inbox, Share Sheet delivery, iCloud Drive handoff.
- **Multi-image consistency.** Series-level matching so a set of frames has the same HDR character.

---

## 4. What the app is *not*

- Not a raw developer and not a replacement for Capture One. It consumes Capture One's *output*.
- Not an HDR "enhancer" that brightens everything — that is the failure mode the design is built to avoid.
- Not a general photo editor: no cropping, no healing, no local masks (unless stage-3 feedback says otherwise).
- Not a cross-platform delivery tool. Apple-only viewers are an explicit assumption, and the SDR fallback is what protects everything else.
- Not a pixel editor on the iPad. The iPad holds a preview and a recipe; the Mac owns pixels.