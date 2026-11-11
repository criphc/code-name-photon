---
type: record
owner: docs
updated: 2026-11-05
---

# HDR Highlight Finisher — A Quick Guide

*Design document 2 · the user-facing guide to the app as it should feel once **stage 2** ships*
*Companion docs: [01 — app concept and three stages](design-01-app-concept-and-three-stages.md) · [docs index](../README.md) · [stage-2 handoff](stage-2-handoff.md) · [archived stage-1 plans](../archive/stage-1/)*

This document describes the intended experience, not the implementation. Rationale and engineering constraints live in docs 01 and 08 and in the code-side `AGENTS.md` cards (`server/`, `contract/`, `client/`).

> **Scope (2026-11-03): this guide is a stage-2 target, not a description of what exists today.**
> Stage 1 closed on 2026-11-03: `appctl serve` exposes the LAN API, the iPad judges and posts the recipe, and `appctl deliver` writes the full-resolution HEIC. Inbox watching, automatic pairing, the filmstrip, the Mac job UI and the Settings pane are **stage 2** features — they are excluded from stage 1 by [design-01 §1.4](design-01-app-concept-and-three-stages.md), and stage 2 has not started yet ([stage-2-handoff.md](stage-2-handoff.md)). Anything marked **(stage 2)** below does not exist yet.

---

## The loop

```
Capture One  →  Export  →  Inbox  →  Mac prepares  →  iPad adjusts  →  Mac outputs  →  Photos / Safari
                                        (seconds)        (your judgement)     (seconds)
```

One photograph goes around this loop once. The Mac does the rendering and the file writing; the iPad is where you actually see and decide the HDR. You never edit pixels on the iPad and you never juggle files.

---

## 1. Export from Capture One

1. Finish the photograph the way you normally would. This export is the **SDR photograph** — it must already be something you would happily deliver.
2. Export **16-bit TIFF, Display P3, full resolution** into the app's **Inbox** folder **(stage 2)** — in stage 1 you point `appctl serve --batch` at the export folder yourself and run `appctl deliver` to produce the file. Only Display P3 exports are accepted: an Adobe RGB / sRGB export is refused at decode rather than silently clipped (why: [colour.md](../reference/colour.md)).
3. Leave everything else alone. The app takes the file from here.

**What the app needs from the image:** highlight detail worth revealing. If the brightest areas are already flat white in Capture One, no tool can bring back their texture — protect the highlights at export, or pick a different frame.

**Pick an image with something to finish:** a window, a specular glint, a sunlit surface, a sky with texture.

---

## 2. Prepare on the Mac

- The image appears in the Mac app as a small job: *Importing → Preparing → Ready* **(stage 2; stage 1 has no Mac UI)**.
- Preparation takes seconds: the Mac renders the SDR image once; the iPad computes the HDR view from that base plus the three controls, so it never touches the original TIFF.
- The iPad app finds the Mac automatically on the same Wi-Fi (pair once, first run). The image appears there on its own — no file copying, no cloud, no cables. **(stage 2: stage 1 uses `--bind/--port` and a bearer token by hand.)**
- Nothing to do on the Mac. Its display cannot show HDR, so it is deliberately not the place to judge anything.

**First-run setup (stage 2):** install the Mac app and the iPad app, pair them on the local network, point the app at your Capture One export folder once.

---

## 3. Adjust on the iPad

This is the actual work. The iPad shows the photograph in **real HDR**, up to what the display can show at that moment.

### What you see

- The photograph, large.
- A strip of imported images below it **(stage 2: the filmstrip)**.
- Three sliders.
- **Hold to compare** (press and hold to see the SDR version).
- A **headroom overlay** you can toggle.
- **Done** — sends the settings back to the Mac.

### The three controls

| Control | What it does | How to set it |
|---|---|---|
| **Start HDR** | Chooses how bright a region must be before it gains extra brightness. | Raise it until only glints, windows, lamps and textured highlights are affected — not skin, pale walls or the whole sky. |
| **Highlight lift** | Chooses how much extra brightness those regions receive. | Raise until the highlight looks *lit* rather than *luminous*; back off as soon as surfaces start to glow. |
| **Transition** | Softens the boundary between lifted highlights and untouched midtones. | Widen it until you cannot see where the effect starts; narrow it only for a deliberately graphic look. |

### Judging aids

- **Hold to compare** shows the SDR image — exactly what anyone without HDR will see. If that version is not right, nothing else matters.
- **Headroom overlay** shows two different things as colour bands: brightness that goes above SDR white, and brightness that exceeds what *this* display can show right now. A large second band means the effect will be clipped on this screen.
- Keep the two look references in mind (`fixtures/media/reference/IMG_7097.HEIC` and `IMG_7473.JPG`): they define how much HDR is desirable.

### Judging tips

- Compare the HDR against the SDR, not against a brighter screen. If you only notice "brighter", the effect is wrong.
- Watch pale skin, white walls and overcast skies — they expose an over-eager threshold first.
- Judge at a comfortable, consistent screen brightness. The iPad's HDR headroom changes with brightness, so a preview judged at full brightness is not what a dimmed screen shows.
- The iPad is a consumer XDR display, not a calibrated reference. Judge naturalness and detail, not numbers.

Tap **Done**. The settings — a small recipe, not pixels — go back to the Mac.

---

## 4. Output on the Mac

- The Mac renders the photograph at full resolution with your settings, writes the HDR file, and checks it before telling you it is done.
- Each finished image is marked **Verified** or shows a specific problem. Do not ignore a failure: a file that was not verified is not a deliverable.
- Output lands in the app's **output** folder, next to a small settings file so the same image can be re-rendered later **(stage 2 UI; in stage 1 the files land in the directory you pass with `--out`)**. If you re-export the TIFF from Capture One, the app notices and asks you to judge it again.
- **Your final check — in the real viewers:** open the file in **Photos** and in **Safari** on the iPad (Safari 26 or later shows HDR images). Both must show the intended HDR, and the SDR view must still look like Capture One. The app cannot prove this for you; those two viewers are the delivery.

### Sharing

- On Apple devices (Photos, Safari) the HDR is visible when the screen supports it.
- In apps and devices that do not support gain-map HDR, the file displays as the SDR photograph — which is why the SDR version was required to be right in step 1.
- For anywhere that needs plain SDR, export the SDR version instead of sending the HDR file.
- Remember that messaging apps and social platforms re-compress images; the HDR effect may not survive the upload.

---

## What good looks like

- The SDR compare view looks like the Capture One export.
- The HDR view separates lights and reflections; it does not brighten the whole photograph.
- No glowing skin, no halos around dark edges, no banded skies, no clipped specular highlights.
- The file looks intentional in Photos **and** in Safari, at normal screen brightness.

---

## If something looks off

| Symptom | What to do |
|---|---|
| The image looks almost SDR on the iPad | Raise screen brightness or turn on HDR viewing in Photos; the display may have little headroom left. |
| The effect is invisible in Photos or Safari | Check the image says **Verified**. If it does, the viewer or the display was not using the HDR data — try the other viewer, and check the file on a second device. |
| Highlights glow or skin looks luminous | Lower **Highlight lift**, raise **Start HDR**. |
| Banding in skies or smooth walls | Widen **Transition** slightly; raise `encoder.quality` (stage 1) or the output quality setting (stage 2). |
| The effect is too subtle on an iPhone | Normal — its display headroom differs. Judge on the iPad; check the headroom setting. |
| Colours differ from Capture One | Check the SDR output profile setting; do not judge colour on the Mac. |
| The iPad cannot find the Mac | Same Wi-Fi network, app open on both, pair again. |
| A re-export looks wrong | Capture One produced a new file; the app should ask you to judge that image again. |

---

## Settings worth knowing

**(stage 2 — there is no Settings pane in stage 1.)** The equivalents are recipe fields and CLI flags: `hdr.headroom_cap` and `encoder.quality` in the recipe, `--preview-edge` / `--out` on the CLI, and the output profile is fixed to Display P3 for stage 1.

Defaults are chosen so you should not need these often:

- **HDR headroom cap** — how much extra brightness the file is allowed to advertise. Stage 1 fixes this at 2.5× (≈1.32 stops); the display end is adapted by Apple's HAGC. Lower it if files look over-bright on other devices.
- **SDR output profile** — Display P3 by default; sRGB for destinations that ignore colour profiles.
- **Output quality / size** — trade file size against highlight cleanliness.
- **Inbox and output folders** — where images come in and go out.

---

## What this guide deliberately does not cover

Batch handling, presets, finer tonal controls and additional output formats are later stages (see design-01 §2–3). Engineering details — encoder behaviour, colour spaces, verification — are in [docs index](../README.md) and the code-side READMEs.
