# Beyond the Plan — Things Worth Considering

*Design document 3 · derived from the planning session `session-edbdb902` (2026-11-02) and the HEIF/Core Image research session in [`Save to HEIC Using Core Image.md`](<../../../notes/Save to HEIC Using Core Image.md>), extended with local prototype measurements*
*Companion docs: [01 — app concept and three stages](../../01-app-concept-and-three-stages.md) · [02 — the quick guide](../../02-hdr-highlight-finisher-workflow.md) · [04 — Mac-side plan (M0–M2.1)](04-stage-1-plan.md) · [05 — M0 encoder/iPad verification](05-encoder-verification.md) · [06 — M3 iPad client](06-m3-ipad-edr-plan.md) · [07 — M4/M5 output and acceptance](07-m4-m5-output-and-acceptance.md)*

Items marked **✔ verified** were prototyped on this machine (macOS 27.2, M1 Max) while writing this document. Items marked **⚠ validate** still need a decision from testing on your hardware. Claims imported from the research session were checked against the local SDK headers where they affected a decision; where the two disagreed, the SDK won. Ordered by how likely each is to bite you.

---

## 1. "HDR HEIC" means three different files — pick one deliberately

| | Legacy Apple gain map | ISO 21496-1 (`tmap`) | True 10-bit HEIF |
|---|---|---|---|
| Base | 8-bit HEIC, P3 | usually 8-bit SDR (libheif writes 10-bit) | 10-bit HEVC, `heix` brand |
| HDR carrier | auxiliary gain-map item + XMP `HDRGainMapHeadroom` | `tmap` derived item referencing base + map | PQ/HLG transfer in `colr`, optional `clli`/`mdcv` |
| SDR fallback | implicit (`pitm` = base) | `altr` entity group | **none** — 8-bit-only decoders refuse the file |
| Written by | iPhone camera, AppKit HDR effect | Core Image (verified), libheif (experimental build) | camera `.HIF`, `writeHEIF10Representation` |
| Reach | any HEIC reader sees the SDR base | iOS 18/macOS 15+ renders HDR; others take the base | 10-bit-capable decoders only |

- **Legacy Apple map** (`urn:com:apple:photo:2020:aux:hdrgainmap`): 8-bit, single-channel, low-resolution (1/2–1/4 of the base; `samples/reference/IMG_7097.HEIC` carries 2016×1512 under 4032×3024), Rec.709 transfer, headroom in an XMP item (e.g. `HDRGainMapHeadroom: 3.482` ≈ 1.8 stops). This is what an iPhone ships.
- **ISO 21496-1** (`tmap`), iOS 18 / macOS 15: the gain map is a *derived item*, `dimg` names its inputs, and an `altr` entity group gives unaware readers the base. libheif's implementation encodes the base at 10 bits and signals colour with `nclx` only (no ICC) — worth knowing if you ever diff your output against another writer.
- **True 10-bit** (`heix`, PQ/HLG): not a gain map at all — a single 10-bit HDR image with no graceful fallback. Use only if SDR delivery is irrelevant.

**✔ verified:** Core Image emits the middle one — `tmap` brand + item, an **8-bit L008 full-resolution gain map**, and `AlternateHeadroom = log2(linear headroom)`. ImageIO's `kCGImageSourceDecodeToHDR` then returns 10-bit HDR at the expected headroom. So the dialect question is largely answered: **write ISO 21496-1, verify on the oldest Apple device you care about.**

**✔ verified — HAGC:** ImageIO derives a **Headroom Adaptive Gain Curve** from the ISO gain map automatically ([ColorSync HAGC](https://developer.apple.com/documentation/colorsync/headroom-adaptive-gain-curve), SMPTE ST 2094-50) and the system applies it as display headroom changes. Excellent for delivery, and the reason **the iPad preview is not a fixed reference** (see §5).

**Do not infer the layout from `samples/reference/IMG_7097.HEIC`.** ✔ verified: it is a hybrid — major brand `heic`, compatible brands `mif1/MiHB/MiHA/heix`, an 8×6 grid of 512 px 8-bit tiles, XMP items carrying headroom and style data. A major brand of `heic` cannot hold 10-bit data, and a `heix` *compatible* brand does not make it 10-bit. Use it as a look reference, not as a container template.

### 1.1 Don't "upgrade" the base to 10-bit for the gain-map file

Tempting, legal, and not worth it:

- **It is a rewrap, not an append.** A gain map is not a trailing chunk: adding it means new `infe` entries in `iinf`, a `dimg`/`auxl` entry in `iref`, `auxC`/`ispe`/`colr`/`pixi` in `ipco` with `ipma` associations (or a `tmap` property), amended `iloc` offsets, a changed or added `pitm`, and an `altr` group. Because `meta` precedes `mdat` in practice, every byte offset shifts.
- **No CLI does it.** `heif-enc` re-encodes from scratch, and libheif's gain-map support sits behind an experimental build flag — the Homebrew 1.23.7 on this machine exposes neither.
- **Apple's own writer is not reliable for this combination** — see "Writers differ across OS versions" in §3: the two writers disagree by OS version, and the encoder can silently drop the auxiliary image.
- **You lose the fallback.** A 10-bit Main-10 file is refused by 8-bit-only decoders instead of degrading to SDR — you have traded "degrades gracefully" for "needs a newer decoder anyway".
- **The gain is in the wrong place.** The gain map is the precision bottleneck, not the base. A 10-bit base gives cleaner SDR gradients; it does not give a better HDR image at the same authored headroom. It costs ~25 % more bytes on top of the map.

**Decision:** 8-bit P3 base + gain map for delivery; only consider a 10-bit base + `tmap` if you simultaneously need 10-bit SDR fidelity and HDR in one file; use 10-bit PQ/HLG only for a deliberately fallback-free deliverable. Note that the workspace tool's base-preserving path (`-b`) emits ISO `tmap`; its Apple-map mode (`-g`) is only reachable with a tool-generated base, so "Capture One base" and "Apple map" are mutually exclusive there.

---

## 2. Delivery is narrower than it feels — and `sips` will lie to you

**Where the gain map is actually rendered**

- **Photos** is the reference renderer on XDR hardware. On SDR hardware it shows the base or a headroom-limited tone map. The cheapest A/B switch is **Settings → Apps → Photos → View Full HDR**.
- **Safari** is narrower than assumed: Safari 17 decodes HEIC in `<img>` but renders it **SDR**; HDR image rendering only arrived in **Safari 26 (Sept 2025)**. Older Safari shows the base.
- **Preview / Quick Look / Files** may display SDR and may or may not preserve aux data on export — never assume.
- **AirDrop / Files** preserve the bytes. **iMessage** blue-bubble reportedly preserves the map; **SMS/MMS** strips it. **Mail** keeps the attachment but inline preview is unreliable. **Instagram** is inconsistent. **Print is SDR.**
- **Everything else:** Chrome renders JPEG gain maps since 116 and AVIF behind a flag, but not HEIC; Firefox renders none; Android 14+ uses **Ultra HDR JPEG**, so an Apple HEIC shows only its base there.

**The verification trap — read this twice.** **✔ verified:** `sips -s format jpeg` and `sips -s format heic` **silently strip the gain map**, and so do Finder conversion and most "Export" commands. A file that looks SDR after a `sips` check is not necessarily broken. **Never use `sips`, Finder, or an Export command to judge HDR.** Assert the auxiliary item with ImageIO (`kCGImageAuxiliaryDataTypeISOGainMap`) and deliver a byte-copy.

**Therefore the SDR base is the photograph for most of the world.** It must be the *approved* Capture One rendition (not a clipped HDR render), with a P3 ICC tag, no alpha channel, correct orientation, and no dependency on any auxiliary item. Keep an sRGB twin for web/social/print work (see §4).

---

## 3. The encoder path is already implemented — use it before writing any

The workspace contains `toGainMapHDR/` (chemharuka's `toGainMapHDR`, macOS 26+, tested Apple Silicon). It does exactly the job this product needs: read an HDR source, optionally reuse a supplied SDR base (`-b`), compute the gain map as the HDR↔SDR ratio, write a gain-map HEIC. This section is the canonical home for its behaviour; other docs point here.

```bash
tools/toGainMapHDR/bin/toGainMapHDR <hdr.tif> <out-dir> -b <sdr-base.tif> -R 2.5 -d 8 -q 0.85 -c p3
```

Verified on this machine:

- **The supplied base is preserved exactly.** Test: uniform-grey base + gradient HDR → decoded SDR output had zero variance. ✔ M0 re-measured bit-exactly: mean/max abs diff 0, 0/786432 px differ, uniform base variance 0. The tool does not re-tone-map the base.
- **The `-b` path emits ISO 21496-1.** `ftyp` compatible brands include `tmap`; base 8-bit, tiled (e.g. 2×2 / 6×7 tiles); no Apple auxiliary item. Options: `-R` headroom cap (**ignored with `-b`, see next**), `-q` 0–1 or 0–100, `-c srgb|p3|rec2020`, `-d 8|10` (pass 8 explicitly; README says default 8, the binary help says 6, and the code accepts only 8 or 10), `-H` half-size map, `-t` filename suffix.
- **With `-b`, `-R` does nothing and the headroom is content-derived.** ✔ M0 measured: `-b base.tif -R 1.5`, `-R 2.5` and `-R 6` produce **byte-identical** files. Core Image derives the metadata from the actual HDR↔base ratio: `AlternateHeadroom ≈ log2(authored peak)`, `2^AlternateHeadroom = contentHeadroom`, with a −0.005-stop offset from 8-bit gain-map quantisation. A "headroom cap" therefore has to be applied to the HDR rendition pixels **before** encoding; no CLI flag caps delivery headroom. Evidence and numbers: `docs/05`.
- **`-H` is a different writer, not a size knob.** ✔ M0 measured: it re-enables headroom analysis, hard-codes `AlternateHeadroom = 2.300450` (over-promising 2.45× where the content peaks at 2.01×), normalises the gain to the absolute peak so any HDR pixel more than `2^GainMapMax`× its base is **clipped** (authored 4.0 peak came out at 2.01), and switches the map's `nclx` transfer from PQ to sRGB. Do not use `-H` for previews or delivery until it is re-verified.
- **`-b` forces the RGB map.** It warns "Base image specified, will use RGB gain map" and ignores `-g` (Apple monochrome map) and `-m`. The Apple dialect is only reachable by letting the tool generate its own SDR base — which breaks the Capture One match. Treat "Capture One base" and "Apple map" as mutually exclusive in this tool.
- **`-g` is the sharing dialect, not the standards one.** README claims Apple gain maps are understood by Google Photos (Android), Instagram and Edge, while ISO `tmap` is the iOS 18/macOS 15+ standard. If a photo will be shared beyond your own devices, that is the trade: Apple map for reach, ISO for standards and for preserving your own base.
- **The tool cannot invent range.** Verified: on a clipped Capture One TIFF it measured headroom ≈1.10 (≈0.14 stop) and wrote a valid, visually SDR file. Authoring the HDR rendition is the app's job.
- **The HDR input must be a 4-channel `RGBAf` float TIFF.** ✔ M0 measured: a 3-channel 32-bit-float TIFF is silently misread by ImageIO/Core Image (values wrong by ~35 %), so the map would be computed from wrong pixels while the tool still exits 0. `CIContext.writeTIFFRepresentation(.RGBAf, extendedLinearDisplayP3)` writes 4 channels plus a "Display P3 Linear" ICC and round-trips exactly. The alpha sample (1.0) does not propagate — output alpha follows the 3-sample SDR base.
- **A near-SDR HDR input silently produces an SDR HEIC.** ✔ M0 measured: if the HDR peak is < 1.05 the tool warns and writes a plain SDR HEIC *with alpha*, exit code 0. Always assert the HDR read-back peak before encoding; do not infer success from the exit code. The pipeline enforces this (`docs/04` M1): authored peak < 1.05 is a hard error, and the encoded container is ImageIO-verified (ISO aux, `contentHeadroom` ±5%, no alpha) before it is accepted.
- **Operational caveats:** destination folder must exist (otherwise a `try!` crash); macOS 26+; Intel partially supported; `-H` crops odd extents by one pixel; alpha is path-dependent and ✔ M0 measured: the `-b` ISO output has **no** alpha (8-bit `noneSkipLast`), while a no-`-b` ISO output carries one, adds a `MiHE` brand and decodes HDR at 16 bpc — so the Capture One pipeline must always pass `-b`; `heic_hdr.py` batch mode does **not** support `-b`, so a stage-2 batch has to loop the CLI per image with its own base; "CIImage cannot handle the brightness of Apple gain map HDR correctly" — do not use Apple-map files as input.

**If the tool is ever ruled out**, the fallback is Core Image. One call writes a compliant ISO HEIC: give it the SDR image as the primary, the HDR rendition via the `hdrImage` representation option, and it derives the gain map from the HDR↔base ratio:

```swift
import CoreImage
import ImageIO

let ctx = CIContext()
// ImageIO keys must be wrapped: CIImageRepresentationOption is a RawRepresentable string wrapper.
let quality = CIImageRepresentationOption(
    rawValue: kCGImageDestinationLossyCompressionQuality as String
)

try ctx.writeHEIFRepresentation(
    of: sdrCIImage, to: url, format: .RGBA8,
    colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
    options: [
        .hdrImage: hdrCIImage,   // the HDR rendition, NOT `true`; macOS 15+/iOS 18+
        quality: 0.85
    ])
```

- **`hdrImage` takes an HDR `CIImage`, not a boolean.** The value is a full HDR rendition; Core Image computes the map from its ratio to the SDR primary. `contentHeadroom` (macOS 26+) supplies the metadata. The explicit `hdrGainMapImage` route (monochrome gain-map `CIImage` + properties, or `hdrGainMapAsRGB` for a chromatic map) remains for when you need exact stored gain values. ([`hdrGainMapImage` docs](https://developer.apple.com/documentation/coreimage/ciimagerepresentationoption/hdrgainmapimage))
- **Know the four writers and the ceiling.** `HEIFRepresentation` / `writeHEIFRepresentation` (you choose the `CIFormat`; macOS 10.13.4/iOS 11) and `HEIF10Representation` / `writeHEIF10Representation` (fixed 10-bit; macOS 12/iOS 15). There is **no 16-bit HEIF** — `RGBAh`/`RGBAf` into a HEIF write still lands at 8-bit — and `CIContext` has no AVIF export at all. 16-bit stays an intermediate working format.
- **Pixel format matters more than it should.** `.RGBA8` is the reliable choice (it may add an alpha channel you then strip). `.RGB8`/`.RGBh` on a HEIF write is a documented source of blank output or diagonal artifacts on cropped / infinite-extent images — clamp and crop filters before writing.
- **No metadata out of the CI writers.** Their documented option keys are quality, embedded thumbnail, and depth/disparity/matte — there is no EXIF/GPS/TIFF/orientation support. Capture metadata, orientation and maker notes require rewrapping with `CGImageDestination` + `CGImageDestinationAddAuxiliaryDataInfo`. (Note the header's "supported options" comment also omits the HDR options that demonstrably work — treat the comments as incomplete, verify behaviour.)
- **Do not plan on libheif.** **✔ verified:** Homebrew libheif 1.23.7 has **no gain-map CLI option and no gain-map headers** on this machine — `heif-enc` is out, and upstream's gain-map support sits behind an experimental build flag. Hand-writing the `tmap` item is a rewrap, not a patch, and not worth the weeks. libavif 1.2+ claims gain-map support but the installed `avifenc` 1.4.2 exposes no gain-map flag.
- **Finer control exists but is undocumented.** ImageIO's `kCGImageDestinationEncodeToISOGainmap`, `kCGImageDestinationEncodeGenerateGainMapWithBaseImage`, and `kCGImageDestinationEncodeGainMapSubsampleFactor` (macOS 16+/iOS 19+) let you tune the map, but the semantics are not documented — prototype only.
- **Writers differ across OS versions.** Reported that `writeHEIFRepresentation` and `writeHEIF10Representation` do not behave the same on every macOS build (one succeeds where the other fails, and builds reportedly invert), and that the writer can silently drop the auxiliary image. Verification is therefore mandatory, not optional.
- **Reading back is not guaranteed either.** Reported that `CGImageSourceCopyAuxiliaryDataInfoAtIndex` can return the metadata keys but omit `kCGImageAuxiliaryDataInfoData` (logging `Unsupported AuxiliaryData format '420f'`); the workaround is `CIImage(contentsOf:options:[.auxiliaryHDRGainMap: true])`. A failed read-back does not always mean a broken file.
- **The base must be the tone-mapped SDR image** (why: §2). The map is a *ratio*, not a second grade; a clipped HDR base produces a technically valid file with a poor fallback.
- **Strip alpha.** The RGBA8 path wrote an alpha channel; some viewers render transparent or black.
- **Map resolution is a size/quality trade.** ✔ verified in the CI path: a full-resolution 8-bit map took the file from 8.8 MB to 12.1 MB and the encode from 0.30 s to 0.67 s. ISO permits subsampling, and iPhone's own files are half-resolution; `toGainMapHDR -H` halves it, at a small quality cost (sizes: §7).
- **A `CIImage` must own its buffer.** `CIImage(bitmapData:)` neither copies nor guarantees the `Data` stays alive after the initializer returns, so a filter evaluated later can read freed heap memory. ✔ M1 hit exactly this in the preview path: 1 run in 4 produced a preview decoded 25 % RMSE away with a 149× HDR peak (freed base × valid gain map), while later runs were fine by heap luck. Build the image through a `CGImage` whose `CGDataProvider` retains the data — the float bitmap you need is `floatComponents | premultipliedLast | byteOrder32Little`; without `byteOrder32Little`, Core Image reads float RGBA as zeros — or keep the buffer alive across the whole filter graph. Determinism cannot be asserted without this: a use-after-free *is* the nondeterminism. ✔ Since 2026-11-03 the rule has no exceptions left in the writers: `PreviewRenderer`, `TIFFWriter.writeHDR` and the shared 16-bit SDR-base assembly all go through `ImageBuffers.swift` (`CGImage` → `CGDataProvider` → `Data`); do not add a `CIImage(bitmapData:)` call (review P1-3).

**Verification tooling for the container:** `xxd -l 32 file.heic` shows the `ftyp` major brand (`heic` = 8-bit base, `heix` = 10-bit); `heif-info` lists items, grid/tiling, bit depth and colour signalling; `heif-convert --with-aux file.heic out.jpg` spills out the base *and* the gain map for inspection; heic.fyi's inspector prints brands, HEVC profile, chroma format, bit depth and each item's `auxC` URN in one pass. None of these replaces an ImageIO/`DecodeToHDR` assertion, but they tell you *what* the file is when a viewer disagrees. The workspace's own `tools/verify-heic` makes that ImageIO assertion in one call (ISO aux, `contentHeadroom`, alpha, dims, base drift, JSON report); its checks and the M0 measurements are in [docs/05](05-encoder-verification.md).

**Before any real photograph:** run `toGainMapHDR -b` on one genuine base+HDR pair (a synthetic gradient with a known peak is ideal), then open the result in Photos and Safari. If that smoke test fails, no amount of colour science will save the project — and it now takes minutes, not a week of encoder work.

---

## 4. Colour management is where "it doesn't match Capture One" will come from

- **Stage 1 accepts Display P3 sources only.** Adobe RGB's green primary lies outside P3 (saturated foliage would clip) and P3's red lies outside Adobe RGB, so pushing Adobe RGB into the 16-bit P3 base is lossy: the out-of-gamut samples either get silently clamped (a change to the authoritative SDR base) or need a real colourimetric conversion. [Stage-1 decision 1](04-stage-1-plan.md) keeps the chain explicit — export Display P3 from Capture One. ✔ Since 2026-11-03 the decoder enforces it: `SourceDecoder` refuses any other embedded profile (Adobe RGB, sRGB, untagged) with `PhotonError.unsupportedSource` instead of clamping (review P1-4). The Adobe RGB originals in `samples/` stay for regression comparison only.
- **Work in linear P3, output P3.** Rec.2020 buys nothing on these displays. Tag the base with an ICC P3 profile — some viewers ignore `nclx`.
- **ICC vs `nclx` is not symmetric.** The ISO `tmap` route signals colour through `nclx` (libheif's writer emits no ICC at all), while Apple's base-image path is ICC-tagged. Readers that only honour ICC will mis-render an `nclx`-only file, and the reverse is also true. Plan which signalling you depend on, and check the decoded file's profile rather than the encoder's input.
- **P3 or sRGB base?** For Apple-only delivery, P3: Photos/Safari are colour-managed and the map is computed in that space. Keep an sRGB variant for web/social/print; a P3 file in a profile-ignoring app looks desaturated.
- **Never double tone-map.** Treat the Capture One SDR export as the base and extend only highlights. A second filmic curve makes the map encode the difference — and the HDR version drifts away from the SDR look.
- **Dither before 8-bit quantisation** and check a 100 % ramp; 8-bit base + wide transition + coarse map is exactly how skies band.
- **Set headroom to the actual peak.** 2.8× is 1.49 stops, 8× is 3 stops. Inflating it wastes map precision; understating it clips speculars.

---

## 5. Judging: the iPad is not a fixed reference

Because Apple derives and applies an HAGC automatically, the same file changes with display brightness, ambient light, True Tone, Night Shift, Low Power Mode, thermals, and the View Full HDR setting. The preview is a *rendering*, not a measurement. M3 computes the mask/gain on the 2560 px base and M4 at full resolution, so sub-pixel differences at highlight edges are expected — the preview is not a pixel-level delivery proof ([docs/06 §4.5](06-m3-ipad-edr-plan.md)).

- **Build a five-rung ladder** and record which rung fails: (1) SDR-only phone/old Mac/Chrome — base only; (2) iPad Photos, View Full HDR on/off; (3) Safari 26+ local page; (4) Preview/Quick Look/Files; (5) the actual target app.
- **Objective checks first.** Round-trip with ImageIO: assert the ISO aux exists, dimensions match, headroom is within 5 %, `DecodeToHDR` succeeds. Check clipping histograms and a 100 % ramp for banding. Size overhead is bigger than the original estimate: M0 measured **+89 %** for the full-resolution RGB map (3.85 MB vs 2.03 MB SDR-only, docs/05 §2), still inside the ~20 MB budget.
- **Two different base comparisons — do not conflate them.** The *render* comparison (the 16-bit `c1_match_v1` base vs the Capture One export) is the Capture One match: it is a bit-exact pass-through, so ΔE2000 is 0.000 and the target is mean ΔE2000 < 1, p95 < 2. The *container* comparison (the decoded 8-bit base of the delivered HEIC vs that 16-bit base) also matters — it is what non-HDR viewers see — but it includes an 8-bit 4:2:0 HEVC re-encode: chroma subsampling alone gives it a measured tail of **mean ΔE2000 1.44, p95 4.12** on the trial image (8-bit LSB mean 1.48, p99 7; `work/m4/probe/calibration.md`, matching `tools/verify-heic`'s `basePreserved`). The M4 delivery gate therefore judges the decoded base against **mean ≤ 2.5 and p95 ≤ 6.0** and reports the remaining percentiles; the mean < 1 / p95 < 2 limits stay the render target, not the container gate.
- **Prove the fallback separately:** make a map-stripped copy *with ImageIO* (not `sips`), pixel-compare it with the approved SDR export.
- **Blind A/B:** randomise filenames and order, ask "which one looks like the print?", not "which is HDR?". Include a second observer if possible.
- **Reject criteria (write these down now):** halo at high-contrast edges; skin shift > 2 ΔE or plastic sheen; clipped or posterised highlights; banding in sky/wall; any change to the SDR base; authored headroom beyond the target display; file > ~20 MB; any viewer showing black or alpha.

---

## 6. Operations: the boring things that break

- **Recipe versioning.** The schema lives in doc 04 (M0) and is the only thing the iPad sends back. Re-renders must be deterministic; bump the schema, never silently reinterpret old recipes.
- **Source immutability.** TIFFs in a read-only folder; do not write XMP into them (Capture One may rewrite or ignore it). All state in sidecars. Keep a SHA-256 manifest so a re-export is detectable even when size/mtime are preserved.
- **Folder layout.** `shoot/01_capture` (immutable) → `02_sdr` → `03_hdr` → `04_recipes` → `05_cache`; finals named `{shoot}_{frame}_v{NNN}.heic`. Stage 1 writes the flat `--out` set of [docs/07](07-m4-m5-output-and-acceptance.md) §2; this shoot tree and its naming are stage 2.
- **Cache invalidation.** Key previews, maps and finals on `hash(TIFF) + hash(recipe) + app build + output profile`. mtime/size are insufficient. Watch FSEvents, but invalidate on hash change. **M2 status:** the recipe-independent base preview is the only cached artifact so far; its validation rule and the re-export detection are in [docs/04](04-stage-1-plan.md) "M2.1 — the base-first contract" (cache). The recipe hash excludes `created` and the provenance-only `source.path` (docs/04 M2.1 "Cache"). Recipe-keyed full renders and the FSEvents watcher remain M4/stage-2 work.
- **Pairing and network.** Bind to the LAN interface only, advertise via Bonjour, require a per-session token (QR code is pleasant), pin a self-signed TLS certificate. One iPad at a time; no internet exposure. **M2 status:** LAN HTTP + a per-session bearer token only. **M3 decision (2026-11-03):** TLS and Bonjour are not in M3 either and remain unscheduled ([docs/06](06-m3-ipad-edr-plan.md)); the client uses a manual host:port + token. Transport details: [docs/04](04-stage-1-plan.md) "M2.1 — the base-first contract". Until then the server is plain HTTP on a trusted LAN — never port-forward it, never run it on a public network.
- **Batch has no base support.** `heic_hdr.py` cannot pass `-b` (§3), so it cannot preserve a Capture One base; a stage-2 batch must drive the CLI once per image.
- **Disconnect mid-batch.** Idempotent jobs keyed by recipe hash; the iPad keeps the last recipe; reconcile on reconnect; write temp + atomic rename so no half-written HEIC ever survives. The implementation is `AtomicFile` (`rename(2)`, P1-7) — remove-then-move is not atomic and is forbidden.
- **Backups.** 3-2-1 for originals, recipes and finals, excluding cache. Periodically decode a random final on a clean machine — a backup that cannot decode is not a backup.
- **Metadata.** The Core Image writers cannot attach EXIF/GPS/TIFF (§3); if capture data, orientation or maker notes must survive, the ImageIO rewrap described there is the only route. **Decision (2026-11-03, [docs/07](07-m4-m5-output-and-acceptance.md) §2):** stage 1 delivers pixels and the ISO gain map only — **no EXIF/orientation rewrap**, recorded as a known gap (a rewrap is its own risk and is not needed to close the stage-1 DoD); revisit before any real delivery batch.

---

## 7. Performance: it is not encode-bound

**✔ measured** on the 283 MB 8423×5599 16-bit TIFF, M1 Max, macOS 27.2, warm cache:

| Step | Time | Output |
|---|---|---|
| 2560 px thumbnail | 0.39 s | 2560×1702, 16-bit |
| HEIC preview, no map | 0.29 s | 717 KB |
| HEIC preview + map | 0.50 s | 3.36 MB |
| Full HEIC, no map | 0.30 s | 8.8 MB |
| Full HEIC + map | 0.67 s | **12.1 MB** |
| Peak RSS (full + map) | — | 3.7 GB |

Sample sizes: 144 MB (6000×4000), 194 MB (6960×4640), 283 MB (8423×5599). A 100-image batch is 15–28 GB of source and 1–2 GB of finals.

- **Transfer maths.** A 2560×1702 float16 RGB preview would be **26 MB** (35 MB as RGBA) — the 15–20 MB figure in the original plan only holds for fewer channels or a shorter edge. The **HEIC preview with map is 3.4 MB**. At 80 MB/s that is 0.04 s vs 0.3 s; at 20 MB/s, 0.17 s vs 1.3 s. **Superseded by the M2.1 decision below:** the iPad does need per-pixel access (it computes `mask`/`gain` itself), so M2 sends the 16-bit Display P3 base PNG — **22.1 MB** at 2560×1707 (§7), i.e. ~0.28 s at 80 MB/s and ~1.1 s at 20 MB/s. The HEIC-preview option is kept here only for the bandwidth maths.
- **The real bottlenecks are not HEVC.** They are full-resolution float rendering with local highlight masks (expect 2–5× the 0.67 s and 4–6 GB), preview regeneration after every re-export, the iPad decoding a 47 MP HEIC, and round-trip latency. Limit concurrency to 2 on 32 GB, 1 on 16 GB.
- **✔ M1 pipeline measured** (6000×4000, release build, M1 Max): decode 0.31 s (+0.09 s SHA-256), SDR base 0.007 s, HDR rendition 0.15 s, preview downscale + staging TIFFs ≈0.35 s, HEIC encode 0.44 s, meta ≈0.30 s → **~3.0 s total, ~5.2 GB peak RSS**. So the 2–5×/4–6 GB estimate above holds, and the pipeline cost is dominated by memory, not CPU.
- **✔ 2026-11-03 (P1-2): the preview Lanczos no longer samples past the source extent.** The source is `clampedToExtent()`-ed before `CILanczosScaleTransform`, so a constant stays constant at every border/corner pixel instead of darkening (measured pre-fix on a uniform 0.5 image: corner 0.4402, "interior" 0.4693, centre 0.5000). Interior samples move by at most one half-float ULP (≈4.9e-4), so the measured numbers above stand; the M1 preview's bytes changed (882,091 B → 881,253 B, same `sdr.tif`/`hdr.tif`, same `verify-heic` PASS).
- **✔ M2.1 base preview measured** (same source, release): decode + identity base + Lanczos to 2560 + 16-bit P3 PNG = **1.46 s cold / 0.095 s warm** (warm includes re-hashing the 144 MB source and the 22 MB PNG), output **22.1 MB** at 2560×1707. Roughly half the M1 pipeline time and a fraction of the memory, because no HDR rendition, TIFF pair or HEIC encode happens. A 20-image batch therefore costs roughly 0.7 s of batch hashing + 1.5 s per image of first-time base preparation — fine for stage 1, and the reason M3 should show a per-item spinner.
- **Don't spend 25 % size on a 10-bit base.** 12.1 MB at 8423×5599 is an 8-bit base plus a full-resolution map; switching the base to 10-bit adds roughly a quarter to the file for cleaner SDR gradients, not better HDR (see §1.1).
- **Reference sizes from the tool** (README, 4000×6000 16-bit TIFF): Apple map 6.5 MB (~39.5 dB), ISO RGB map 7.4 MB (~41.4 dB), Apple map half-size (`-H`) 4.6 MB, 10-bit ISO map 11.9 MB (~46 dB), PQ 10-bit 5.6 MB, SDR 3.9 MB. Our measured 12.1 MB CI file is a larger image with a full-resolution map — same order, no surprise.
- **Decision (M2.1, 2026-11-02): the iPad receives the SDR base, not a rendered HDR HEIC.** The contract, the rationale and the endpoints/error table live in [docs/04](04-stage-1-plan.md) "M2.1 — the base-first contract"; this section keeps only the measurements that motivated it (the 22.1 MB / 1.46 s base preview above, versus the 3.4 MB HEIC preview).

---

## 8. Product traps

- **HDR is not "everything brighter".** The failure mode is a global lift that makes skin glow and clouds look like lamps. Mask to highlights, cap the lift, default conservative. The win is highlight separation, not a halo.
- **Skin and pale surfaces fail first.** Luminance ratios make pale skin, wedding dresses, white walls and overcast skies show banding, clipping and plastic sheen before anything else. Put a portrait and a white-wall frame in every test set.
- **Scope creep.** Curves, masks or raw decoding turn this into a worse Capture One. It is a finisher: source in, recipe, HEIC out. The product-level "what it is not" list is doc 01 §4; everything on that list is also an engineering short-cut not to take.

---

## 9. Hardware notes that change what you can even see

- **The Studio Display cannot validate HDR.** 5120×2880, ~600 nits, SDR-only, no EDR.
- **The 12.9″ M2 iPad Pro is the reference** (Liquid Retina XDR, 2732×2048, 1000 nits full-screen, 1600 peak, P3).
- **Sidecar/AirPlay are not a validated HDR path.** Sidecar is compressed and latency-bound; AirPlay is SDR. Composition only, never final highlight judgement.
- **A cheap, repeatable validation loop:** AirDrop the final HEIC plus a map-stripped SDR copy; view both in Photos at ~50 % brightness with True Tone/Night Shift off, moderate room light, cool iPad; toggle View Full HDR for the A/B.
- **Calibrate expectations.** The iPad is a consumer display with Apple's tone mapping, not a calibrated reference. Judge relative naturalness and detail survival, not nits. For colour-critical work, borrow a MacBook Pro XDR or Pro Display XDR for one pass.