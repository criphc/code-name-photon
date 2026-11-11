---
type: reference
owner: docs
updated: 2026-11-05
---

# Colour

- **Display P3 sources only**, enforced at decode: `SourceDecoder` refuses Adobe RGB, sRGB and
  untagged sources with `PhotonError.unsupportedSource` (HTTP 422 `source_unreadable`) instead of
  silently clamping out-of-gamut samples. Capture One must export the `-P3` TIFF. The Adobe RGB
  originals in `fixtures/media/` are regression references only.
- **Work in linear extended Display P3 float, output Display P3.** Rec.2020 buys nothing on these
  displays. Tag the base with an ICC P3 profile — some viewers ignore `nclx`.
- **ICC vs `nclx` is not symmetric.** The ISO `tmap` route signals colour through `nclx`, the Apple
  base-image path is ICC-tagged; readers that honour only one may mis-render the other. Check the
  decoded file's profile, not the encoder's input.
- **Never double tone-map.** The Capture One export *is* the base; only highlights are extended. A
  second filmic curve makes the gain map encode the difference and the HDR drifts from the SDR look.
- **Dither before 8-bit quantisation** and check a 100 % ramp; 8-bit base + wide transition + coarse
  map is exactly how skies band.
- **Set headroom to the actual peak.** Inflating it wastes map precision; understating it clips
  speculars. The cap is the recipe's `headroom_cap` (default 2^2 = 4 linear = 2 stops, range 1…8,
  [recipe.md](recipe.md)) and is authored into the pixels.
