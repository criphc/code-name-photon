# M3.6 — device acceptance record (2026-11-03)

*Evidence for docs/06 §6/§10. Gitignored by design (`work/`).*

## Setup

- iPad Pro (12.9-inch, 6th generation — `iPad14,5`, M2, Liquid Retina XDR), iPadOS **27.0** (24A435),
  Developer Mode on, paired/trusted over USB.
- Display: **Reference Mode off** (recorded as an M5 idea only), brightness ≈50 %, True Tone and
  Night Shift off, moderate room light. (For the two-brightness overlay check: max brightness.)
- Mac: `photon serve --batch samples/sources --work work/m3/server --port 8787 --token m3-device-token`
  from the M2.1 server (appVersion `0.3.0-m21`, encoder `5dba4e2`), LAN `192.168.10.139:8787`.
- App: `com.criphc.Photon`, Debug, built by `make build-device` (Xcode 27.2, iOS SDK 27.2, deployment
  target 26.0) and installed with `xcrun devicectl device install app`; launched with `devicectl`.
- Batch: `samples/sources` (six sources: three Display P3 + three Adobe RGB).

## Acceptance (docs/06 §6 steps)

| step | result |
|---|---|
| connect: manual host:port + token → `/api/health` → `/api/items` (6 items) | ✅ host `abbreviation.local` (= Mac), port 8787, token; health shows 6 items |
| prepare + preview: spinner on cold cache, 22.1 MB base download | ✅ cold prepare rendered the SDR base, then the base downloaded with progress |
| base view with no gain (hold-to-compare) | ✅ shows the same SDR base; compare mode is gain = 1 in the shader |
| default recipe (start 0.62 / lift 1.4 / transition 0.28 / cap 2.5) on the XDR | ✅ sun reflections lift; midtones/skin/white walls unchanged; not a global brightening; headroom readout 6.9–7.3× at ~50 % brightness |
| slider extremes (`start 0`, `lift 4`, `transition 1`) | ✅ no crash, image stays coherent (cap at 2.5 clips flat white as designed) |
| overlay at ~50 % brightness | ✅ amber band = authored above SDR white; dimmed base elsewhere; readout 7.2× |
| overlay at max brightness | ✅ readout dropped to 2.7×; still only the amber band — see "finding" below |
| Done / POST recipe | ✅ banner "recipe sent to the Mac; M4 writes the HEIC" + server `renderKey` |
| recipe round-trip (server-side check) | ✅ only `hdr` + `created` differ from `recipeDefaults`; `source` (incl. provenance `path`), `base`, `encoder`, `versions` preserved; server returned 200 + `renderKey` (state `recipe_received`) |
| non-Display-P3 source (422 `source_unreadable`) | ✅ `FPL05190.tif` shows "unsupported source … Adobe RGB (1998), which is not Display P3; export the SDR base as Display P3 from Capture One" and state `failed`; P3 siblings are unaffected |
| 409 `source_changed` re-judge flow | not triggered on device (optional in §6); covered by `ClientErrorTests`/`AppModel` logic |
| no crashes / unexpected exits during the run | ✅ (one app process stayed alive through all steps) |

## Findings and fixes made during acceptance

1. **Hold-to-compare did not receive press events** (SwiftUI `DragGesture(minimumDistance: 0)` and a
   hand-rolled `UILongPressGestureRecognizer` overlay both silently did nothing on device, while
   sliders/toggles in the same bar worked). Fixed by making it a real `Button` whose `ButtonStyle`
   reports `configuration.isPressed`, with a fixed 176×40 pt slot so neither the pill nor the control
   bar changes shape/size between states. Verified on device: pressed → SDR base, release → HDR.
2. **Stale drawable stretched after a canvas resize** (`isPaused` + `enableSetNeedsDisplay` did not
   redraw when a banner changed the canvas height): the photo appeared vertically squeezed until the
   next slider move. Fixed with `mtkView(_:drawableSizeWillChange:)` and `layoutSubviews` requesting a
   redraw. Verified: before fix the photo rect changed by 115 px vertically (1357 → 1242, aspect
   1.50 → 1.64); after fix the HDR vs compare photo rect is 2032×1357 vs 2030×1355 (0.1 %, within
   EDR/JPEG edge-threshold noise), and the posted banner keeps 3:2.
3. **Overlay's "beyond current display headroom" band has no pixels on this device** with the fixed
   `hdr.headroom_cap = 2.5`: `currentEDRHeadroom` was 6.9–7.3× at ~50 % brightness and 2.7× at maximum
   brightness, i.e. always above the 2.5× authored cap. That is correct behaviour, not a bug. The
   three-band classification is exercised by `ShaderParityTests` at headroom 2.0
   (`withinSDR=6080, aboveSDR=977, beyondHeadroom=1135`) and follows the live readout (7.3→2.7).
   Recorded in docs/06 §10 as a finding for M4/M5 and for the cap decision.
4. **Build-environment only (not product):** the Metal toolchain is installed (Xcode 27.2, `metal`
   32023.922); the MSL shader still ships as a bundle resource and is runtime-compiled (app and parity
   test share the text). Calling `metal` from the DSH shell needs its module cache pointed into the
   workspace (the sandbox denies the default one). Command-line xcodebuild needs `-disable-sandbox`
   for the macro plugin server; the signed device build needed keychain access outside the agent
   workspace sandbox.

## Evidence files

- `evidence/ipad-screenshots/` (iPad screenshots, HEIC, EDR capture):
  - `IMG_1783.HEIC` default-recipe HDR view (headroom 6.9×)
  - `IMG_1784.HEIC` hold-to-compare SDR base (same photo, tag "SDR base")
  - `IMG_1785.HEIC` overlay at ~50 % brightness (amber band, headroom 7.2×)
  - `IMG_1786.HEIC` overlay at maximum brightness (headroom 2.7×, still no beyond-headroom band)
  - `IMG_1787.HEIC` posted banner + `renderKey` (taken before finding 2 was fixed — kept as the
    record of the bug; the final build was verified visually by the user)
  - `IMG_1788.HEIC` / `IMG_1789.HEIC` final-build HDR vs pressed-compare pair used for the
    pixel-geometry measurement in finding 2
- `evidence/parity-macos.txt` — full `make parity` output (fixture + trial-base numbers)
- `evidence/server/items-final.json`, `evidence/server/recipe-*.json` — server-side state and the
  posted recipes (trial image = `recipe-R0003777-P3.json`); `health.json`
- `server/<sha>/preview-base.png`, `preview-meta.json`, `state.json`, `recipe.json` — the M2.1 server
  work tree for the trial item (base actually served to the iPad, 22,112,102 B)

## Gates at sign-off (2026-11-03)

- `cd app && make test` → **229 tests, 0 failures** (116 PhotonCore + 113 PhotonServer).
- `cd ipad && make test-macos` → **80 tests, 0 failures** (ClientKit + contract + wire/transport/base
  tests + the 5-test shader parity gate).
- Parity: fixture default max abs error **9.54e-07**, trial base (2560×1707, 4,369,920 px)
  **1.43e-06**, gate **≤1e-4 linear**; compare mode error 0; overlay bands at headroom 2.0 error
  1.49e-08.
- `make build-ios`/`make build-device` → BUILD SUCCEEDED; device install + launch OK.
