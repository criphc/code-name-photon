# M5 evidence — Mac-side preparation (M5.1 / M5.2 prep)

*2026-11-03 · iPad device steps are the owner's (docs/07 §7); this file records what was prepared
on the Mac and the exact commands. Everything here is gitignored.*

## Delivered file under test

`photon deliver` with the M3-posted recipe (docs/07 §2 "Acceptance image"), installed in `out/`:

| file | bytes | sha256 |
|---|---|---|
| `R0003777-P3-hdr.heic` | 5,798,146 | `826e27599cbbd6308d7695940dd3ec463a39ea5c8814024008bd6f36efb8df69` |
| `R0003777-P3-sdr.heic` | 1,946,906 | `d639359abd87bc9c311d2f7351f79d307e34225269fc21c9236f144f96805b0e` |
| `R0003777-P3.recipe.json` | 543 | `b4cec8a2540d5fad9cc2487c58378a649312b5108ced368404d0ae5f13cc8261` |
| `R0003777-P3.report.json` | 13,650 | (report; see `out/`) |

Recipe renderKey `0bb774682c9d178c852f085b3badf2813397485c422dc50e79efc3e0be5fb747`, created
`2026-11-03T11:45:38+08:00`; authored peak exactly 2.5 linear (1.321928 stops), cap engaged;
report verdict PASS (8/8). M4 evidence: `work/m4/` (`deliver-run1.log`, `deliver-run2.log`,
`verify-heic-hdr.json`, `verify-heic-sdr.json`, `out-sha256.txt`).

## Viewer folder (M5.1 page)

`work/m5/viewer/` holds the delivered HDR + SDR fallback copy + report + recipe, plus the two look
references (`samples/reference/IMG_7097.HEIC`, `IMG_7473.JPG`), so the folder-driven page has every
section:

```bash
python3 tools/visual-check/serve.py --root work/m5/viewer      # prints the LAN URL(s)
```

Server sanity-check recorded in `work/m5/evidence/manifest.json`: hdr/sdr/reference classified,
report section extracted from the real schema-0 report (verdict PASS, 8 checks, headroom
`contentHeadroom` 2.4999998, baseDeltaE mean 1.4406 / p95 4.12, sizes, timings, renderKey, HEIC
sha256), HEIC served as `image/heic` with `Cache-Control: no-store`.

## Blind A/B set

```bash
python3 tools/visual-check/make-ab-set.py --out work/m5/ab-set --key work/m5/ab-key.json \
    out/R0003777-P3-hdr.heic out/R0003777-P3-sdr.heic \
    samples/reference/IMG_7097.HEIC samples/reference/IMG_7473.JPG
```

Randomised names/order in `work/m5/ab-set/`; the key is `work/m5/ab-key.json` (seed
`9900937501100669718`). **Do not open the key before the answer is recorded.**

## Still the owner's (device, cannot be automated)

`work/m5/device-checklist.md` — the ladder, Photos/Safari checks, blind A/B, reject criteria and
timings to fill in. Record the outcome in `work/m5/ladder.md`, `work/m5/ab-record.md`,
`work/m5/timings.json`; then §10 of docs/07 records the M5 verdict.
