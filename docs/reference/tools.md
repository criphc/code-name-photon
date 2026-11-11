---
type: reference
owner: tools
updated: 2026-11-06
---

# Tools

## visual-check

Tooling — **not product code**. A LAN viewer for judging the delivered gain-map HEIC on the iPad, plus
a script that prepares a blind A/B set. Promoted and generalised from the archived M0 viewer page
(archived: [evidence and §4](../archive/stage-1/05-encoder-verification.md)); it only displays,
it never decodes or rewrites the gain map.

```bash
python3 tools/visual-check/serve.py --root out/          # viewer, from the repo root
```

Python 3 standard library only: no dependencies, no build step, no network access beyond the LAN.

### Viewer

```bash
python3 tools/visual-check/serve.py [--root DIR] [--port 8765] [--bind 0.0.0.0]
```

- `--root` is the flat delivery folder (default: the current directory); `index.html` is served from
  next to `serve.py` and is never copied into the folder.
- The page fetches `/manifest.json` on every load; the server regenerates it per request and sends
  `Cache-Control: no-store`. Files are served at `/files/<name>`, HEIC as `image/heic`.
- Startup prints the LAN URLs to open on the iPad.
- Plain HTTP, no authentication, no TLS, no Bonjour: trusted LAN only, never expose it.

### Folder convention

The page has no hard-coded file names; it renders what the folder holds (case-insensitive):

| file | `kind` | shown as |
|---|---|---|
| `{stem}-hdr-{profile}.heic` (e.g. `10-half-rgb`; the legacy `{stem}-hdr.heic` still recognises) | `hdr` | section 1 — the delivered file Photos/Safari must render with the intended HDR |
| `{stem}-sdr.heic` | `sdr` | section 2 — the map-stripped fallback; must look like the Capture One export |
| other `.heic` `.heif` `.jpg` `.jpeg` `.png` | `reference` | section 3 — look references, “which looks like the print?” targets |
| `{stem}.report.json` | — | section 4 — verdict, checks and measured numbers (not an image entry) |
| `{stem}.recipe.json` | — | the recipe that produced the delivery, linked at the bottom |

Hidden files are ignored; other file types are not listed.

A folder with no viewable files shows the convention and the flag to use.

### iPad steps

1. Mac and iPad on the same Wi-Fi.
2. From the repo root, start the server on the delivery folder:
   `python3 tools/visual-check/serve.py --root out/`.
3. On the iPad, open Safari and type the printed LAN URL, e.g. `http://192.168.10.2:8765/`, in the address bar (keyboard URL entry; there is no discovery).
4. Safari **26+** is required. iPadOS 27 is past that line; older Safari shows the SDR base.
5. Let the user judge if the images looks good or not.

The page reports environment facts only — `navigator.userAgent`, whether
`matchMedia('(dynamic-range: high)')` matches, and the screen size. They describe the viewer, not a
promise that this file will render as HDR.

### limits

- **LAN only** Plain HTTP on a trusted network; never port-forward it.
- **HDR rendering depends on the viewer and the display.** Safari/OS version, View Full HDR, brightness,
  True Tone, Night Shift and thermals all change the rendering.
- Non-Safari browsers generally do not decode HEIC in `<img>`; the page shows a “could not render”
  box instead of pretending.

## make-fixtures

Deterministic synthetic base+HDR pair used for encoder verification:
a uniform linear-0.5 mid-grey Display P3 base plus a 32-bit-float linear-P3 ramp
peaking at **4.0 linear**. A known peak is what makes "the file really advertises
the headroom it should" testable. The unit suites do not read it — they generate
their own fixtures at run time.

```bash
make fixtures   # from the repo root -> work/fixtures/base.tif, work/fixtures/hdr.tif
```

The target runs `tools/make-fixtures/make-pair.swift`; the script exits non-zero if
the float/HDR values did not survive, which fails the make target.

Verified 2026-11-02: `base.tif` uniform linear 0.499986 (variance 0) and
`hdr.tif` ramp 0.021943 → 3.998057 linear; re-running produces identical bytes.

The TIFFs are generated, not committed. The 4-channel `RGBAf` float TIFF is
required — ImageIO silently misreads a 3-channel float TIFF, which is why the
generator writes `RGBAf` and why M1's HDR intermediate must do the same
([encoder.md](encoder.md)).
