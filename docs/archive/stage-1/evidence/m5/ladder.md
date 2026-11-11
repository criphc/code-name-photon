# M5 viewer ladder — five rungs (docs/03 §5)

Recorded: 2026-11-03 (owner, after M4 delivery) · file `out/R0003777-P3-hdr.heic`
(sha256 `826e27599cbbd6308d7695940dd3ec463a39ea5c8814024008bd6f36efb8df69`)

| # | rung | route | verdict | observed |
|---|---|---|---|---|
| 1 | SDR-only viewer | old/SDR-only renderer | **PASS** | base only; the SDR view looks like the Capture One export |
| 2a | iPad Photos — View Full HDR **off** | AirDrop | **PASS** | SDR view indistinguishable from the export |
| 2b | iPad Photos — View Full HDR **on** | AirDrop | **PASS** | only the authored highlights get brighter (sun glints); no halo/banding/clipping |
| 3 | Safari 26+ local page (`<img>`) | visual-check page | **PASS** | HDR in `<img>` matches the Photos HDR view; section 2 matches the export |
| 4 | Preview / Quick Look / Files | Mac | **PASS** | renders (SDR path, as expected on the SDR-only Studio Display) |
| 5 | actual target app | owner's usage | **PASS** | intended highlight separation visible |

**First failing rung:** none — all five PASS.

**Notes:** brightness ≈50 % and one maximum-brightness pass (Reference Mode off, True Tone/Night
Shift off); the headroom-bound behaviour at maximum brightness was as expected (HAGC). No reject
criterion from docs/03 §5 triggered.
