---
type: reference
owner: docs
updated: 2026-11-09
---

# HDR HEIC Container

## "HDR HEIC" means three different files

| | Legacy Apple gain map | ISO 21496-1 (`tmap`) | True 10-bit HEIF |
|---|---|---|---|
| Base | 8-bit HEIC, P3 | 8- or 10-bit (profile) | 10-bit HEVC, `heix` |
| HDR carrier | auxiliary gain-map item + XMP `HDRGainMapHeadroom` | `tmap` derived item referencing base + map | PQ/HLG transfer in `colr`, optional `clli`/`mdcv` |
| SDR fallback | implicit (`pitm` = base) | `altr` entity group when present; this project also ships a separate 8-bit `{stem}-sdr.heic` | **none** — 8-bit-only decoders refuse the file |
| Written by | iPhone camera, AppKit HDR effect | `CoreImageHEICEncoder` (Path A); `toGainMapHDR` only as oracle | camera `.HIF`, `writeHEIF10Representation` |
| Reach | any HEIC reader sees the SDR base | iOS 18 / macOS 15+ renders HDR; others take the base | 10-bit-capable decoders only |

**What this project delivers:** the middle one — ISO 21496-1 with a Display P3 base (8 or 10-bit,
profile), an ISO gain map (half or full resolution, ISO RGB or mono), no alpha, and EXIF/TIFF/GPS
carried through. Every delivery also ships a separate 8-bit `{stem}-sdr.heic` with no auxiliary data
and the same capture metadata as the fallback proof.

- **Do not infer the layout from `fixtures/media/reference/IMG_7097.HEIC`.** ✔ It is a hybrid: major brand
  `heic`, compatible brands `mif1/MiHB/MiHA/heix` (and several others — including `tmap`, which is
  why it also carries an ISO aux, [verification.md](verification.md)), an 8×6 grid of 512 px 8-bit tiles, XMP items carrying
  headroom. Use it as a *look* reference, never as a container template.
- **10-bit base is a profile, not a red line.** ✔ ADR-0012 reverses the old "do not upgrade the base"
  rule: the SDR fallback is now a separate 8-bit file, so a 10-bit HDR file no longer loses its
  graceful fallback. 10-bit costs ~25 % more bytes for cleaner SDR gradients; the gain map, not the
  base, is the precision bottleneck. Default profile is 10-bit/half/ISO RGB.
- **The gain map is half or full, ISO RGB or mono.** Half is base/2; `420f` is RGB, `L008` is mono.
  The `container` check asserts the aux dimensions and `PixelFormat` against the profile.
- **Capture metadata is carried.** EXIF/TIFF/GPS are rewrapped from the source, XMP/IPTC/Photoshop
  are dropped, and orientation only passes the tag through — the filter and rewrap rules are
  documented once in [encoder.md](encoder.md#metadata).
- **Apple derives and applies an HAGC automatically** from the ISO gain map, so the same file changes
  with display brightness, ambient light and the View Full HDR setting. The iPad preview is a
  *rendering*, not a measurement ([hardware.md](hardware.md)).

## Delivering HDR: viewers and traps

- **Photos** is the reference renderer on XDR hardware; Settings → Apps → Photos → **View Full HDR**
  is the cheapest A/B switch. On SDR hardware Photos shows the base or a headroom-limited tone map.
- **Safari** renders HDR in `<img>` only from **Safari 26**; older Safari shows the base.
  Preview / Quick Look / Files may display SDR and may or may not preserve auxiliary data on export.
- **Transfer:** AirDrop and Files preserve the bytes; iMessage blue-bubble reportedly preserves the
  map, SMS/MMS strips it; Mail keeps the attachment but its inline preview is unreliable; Instagram is
  inconsistent; **print is SDR**; Chrome/Firefox render no HEIC gain maps; Android 14+ shows the base
  (its native HDR is Ultra HDR JPEG).
- **The verification trap: `sips` lies.** ✔ `sips -s format jpeg` and `sips -s format heic` silently
  strip the gain map, and so do Finder conversion and most Export commands. A file that looks SDR
  after a `sips` check is not necessarily broken. **Never judge HDR with `sips`, Finder or an Export
  command** — assert the auxiliary item with ImageIO and deliver a byte copy ([verification.md](verification.md)).
- **The SDR base is the photograph for most of the world.** It must be the approved Capture One
  rendition (not a clipped HDR render), with a P3 ICC tag, no alpha, correct orientation, and no
  dependency on any auxiliary item.
