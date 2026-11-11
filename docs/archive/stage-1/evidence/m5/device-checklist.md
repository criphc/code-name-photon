# M5.2 device acceptance — owner checklist

iPad Pro (M2, Liquid Retina XDR), iPadOS 27; Reference Mode **off**, brightness ≈50 %, True Tone /
Night Shift off, moderate room light (docs/06 §6, docs/03 §9). Mac and iPad on the same Wi-Fi.

## 0. Transfer the bytes

1. **Photos route:** AirDrop these two files to the iPad and import both into Photos:
   - `out/R0003777-P3-hdr.heic` (the delivery)
   - `out/R0003777-P3-sdr.heic` (the map-stripped fallback copy)
2. **Safari route:** on the Mac, `python3 tools/visual-check/serve.py --root work/m5/viewer`,
   note the printed LAN URL, open it in iPad Safari (keyboard URL entry). Safari 26+ is required
   for HDR rendering in `<img>`; iPadOS 27 is past that line.
3. **A/B route:** AirDrop the four files in `work/m5/ab-set/` (randomised names) to the iPad
   Files/Photos. Do **not** open `work/m5/ab-key.json` yet.

Record the transfer time (start AirDrop → import finished) for `timings.json`.

## 1. Photos — View Full HDR on/off

Settings → Apps → Photos → **View Full HDR**. Judge the delivered file:
- [ ] The SDR view (toggle off) is indistinguishable from the Capture One export
      (compare against `-sdr.heic` in Photos, and against the Capture One P3 export on the Mac).
- [ ] The HDR view (toggle on) brightens **only** the highlighted regions the recipe authored
      (on this frame: sun reflections on cars/glass/road) — not a global lift.
- [ ] No glow/halo at high-contrast edges, no clipped or posterised highlights, no banding in sky
      or road, no black or alpha areas.
- [ ] Record the display headroom reading if available (Control Centre brightness, two levels:
      ~50 % and maximum) and whether the look changed with brightness (HAGC — expected).

## 2. Safari — the local page

- [ ] Section 1 (delivered HDR) renders with HDR in `<img>`: its highlight separation matches the
      Photos HDR view.
- [ ] Section 2 (SDR copy) is indistinguishable from the Capture One export.
- [ ] Section 3 (the two look references) renders; use them for the "which looks like the print?"
      judgement, not as pixel targets.
- [ ] Section 4 (report) shows PASS and 8/8 checks.
- [ ] If the HDR section looks identical to the SDR section, record that: it means Safari rendered
      the base (rung 3 fails).

## 3. Five-rung ladder (docs/03 §5) — record PASS/FAIL per rung in `ladder.md`

| rung | what it is | verdict |
|---|---|---|
| 1 | SDR-only viewer (old Mac Chrome/Preview, or Safari without HDR) — base only, looks like the export | |
| 2 | iPad Photos, View Full HDR on / off | |
| 3 | Safari 26+ local page (`<img>`) | |
| 4 | Preview / Quick Look / Files on the Mac | |
| 5 | the actual target app (how you would actually show the photo) | |

Name the first failing rung, if any.

## 4. Blind A/B (record in `ab-record.md`)

View the four randomised images in `work/m5/ab-set/`. Question: **"which one looks most like a
print?"** — not "which is HDR?". Record the order shown, the answer, and (if available) a second
observer's answer independently, before opening `work/m5/ab-key.json`. Then record the mapping and
whether the delivered HDR / the SDR copy / either look reference was chosen.

## 5. Reject criteria (docs/03 §5) — any hit fails the delivery

halo at high-contrast edges; skin shift > 2 ΔE or plastic sheen; clipped/posterised highlights;
banding in sky/wall; any change to the SDR base; authored headroom beyond the display; file > ~20 MB;
any viewer showing black or alpha. Record which, if any, was hit.

## 6. Timings — fill `timings.json`

Full render and verify are in `out/R0003777-P3.report.json` (`timings`). Record: AirDrop/import
transfer time, viewer start-up (Photos open → image shown; Safari page → image rendered), and the
two brightness levels used.

## 7. Verdict

Reply to the Lead with: ladder results, first failing rung (if any), A/B answers + key mapping,
reject-criteria outcome, timings and any deviation. The Lead records the M5 result in docs/07 §10
and closes stage 1 (M5.3).
