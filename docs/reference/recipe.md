---
type: reference
owner: contract
updated: 2026-11-09
---

# Recipe Schema 0 and Maths

## Recipe schema 0 — field contract

`schema: 0` is the only accepted value; a renderer that receives another value must refuse, never
guess. Recipe fields only *select* rendering; **none of them may modify the SDR base pixels.**

| field | type | range / value | meaning |
|---|---|---|---|
| `schema` | int | `0` | contract version; bump on any semantic change |
| `source.path` | string | repo-relative (cwd-relative when the source is under the working directory) | provenance only — never resolved blindly from JSON, and never part of `renderKey()` (moving the repo or the same bytes elsewhere must not miss the cache) |
| `source.sha256` | string | 64 hex | source identity; a re-export changes it, which invalidates recipes and caches |
| `source.width` / `height` | int | > 0 | must equal the decoded image, else refuse |
| `base.profile` | string | `"DisplayP3"` | delivered SDR base colour space (no sRGB) |
| `base.tone_map` | string | `"c1_match_v1"` | identity pass-through of the Capture One export; changing it invalidates the SDR match |
| `hdr.start` | number | 0…1 | mask threshold as a fraction of SDR white, on Rec.709 luma of the linear working buffer |
| `hdr.lift_stops` | number | 0…4 | gain at full mask, stops above SDR white (mask 0 ⇒ 0 stops) |
| `hdr.transition` | number | 0.001…1 | roll-off width: `smoothstep(start, start+transition, luma)` |
| `hdr.headroom_cap` | number | 1.0…8.0, default 2^2 = 4 (2 st) | absolute linear clamp on the HDR rendition — the **only** control of delivered headroom (advertised ≈ `log2(cap)` stops, 0…3). The iPad presents it in stops (0.5…3.0) and stores the linear value; 8.0 is the v2 ceiling ([encoder.md](encoder.md)) |
| `encoder.tool` | string | `"coreimage"` or legacy `"toGainMapHDR"` | writer family; `coreimage` for new recipes, the legacy value is accepted so pre-v2 recipes decode unchanged |
| `encoder.quality` | number | 0…1 | HEIC quality; default 0.85 |
| `encoder.depth` | int | `8` or `10` | base bit depth; default 10 |
| `encoder.subsample` | bool | `true` (half-res map) or `false` (full-res map) | gain-map resolution; default `true` |
| `encoder.map` | string | `"iso-rgb"` or `"iso-mono"` | gain-map kind; default `iso-rgb` |
| `versions.recipe` | int | `0` | duplicate of `schema` for humans |
| `versions.tone_map` | int | `1` | implementation version of the tone map named in `base.tone_map` |
| `versions.encoder` | string | `"coreimage-1"`, or the tool's git short sha while the oracle is used | engine identity (not libheif's version) |
| `created` | string | RFC 3339 | metadata only; never affects pixels |

## Maths

```
luma    = 0.2126·r + 0.7152·g + 0.0722·b        # on the linear Display P3 base
m       = smoothstep(start, start+transition, luma)
gain    = 2^(lift_stops · m)
hdr     = base · gain                            # each channel clamped to headroom_cap
```

Reference white is 1.0; the SDR compare is the same base with `gain = 1`. The iPad's MSL shader is a
port of exactly this function and is gated at ≤ 1e-4 linear absolute error against
`HighlightShape`/`HDRRendition` (`client/Tests/ClientKitTests/ShaderParityTests.swift`). One maths, one
definition — never add a second renderer.

## Validation and determinism

Reject: an unknown schema, out-of-range values, `depth ∉ {8,10}`, `tool` not in
{`coreimage`, `toGainMapHDR`}, `map` not in {`iso-rgb`, `iso-mono`}, a dimension mismatch, or a
source-hash mismatch (a hash mismatch means a re-export: invalidate and re-judge, never pair
silently). Edge cases that are **legal**: `lift = 0` (base), `start = 1` (no mask),
`start + transition > 1` (luma ≤ 1 keeps the mask below 1), and both `subsample` values.

The `encoder` block is the item's default output profile (`10/half/iso-rgb`). A delivery may request
a list of profiles; each profile gets its own `{stem}-hdr-{profile}.heic` and its own entry in the
single report ([deliver.md](deliver.md)).

Same source + recipe ⇒ byte-identical output on the same machine and OS; `created` is excluded from
the render key and the provenance-only `source.path` is excluded too, while
`source.sha256`/width/height remain in it. `renderKey()` is the SHA-256 of the canonical render JSON
(`schema` + source identity + `base` + `hdr` + `encoder` + `versions`, sorted keys), recorded in the
delivery report so a changed recipe — including a changed profile — is always visible.

The cap range widened from 1.0…4.0 to 1.0…8.0 on 2026-11-07. It is a widening only — every old
recipe stays valid — so the schema version stays `0` and the golden fixtures are unchanged; an
implementation older than the widening rejects the new caps above 4.0.
