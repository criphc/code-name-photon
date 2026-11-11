# Stage 1 Archive Manifest

- Date: 2026-11-03 19:03 CST (Asia/Shanghai)
- Repo state: `llm-photon` @ `ee0a8f8` — "docs(m5): record the device acceptance and close stage 1"
- Scope: archive the stage-1 design documents and text evidence; delete the binary/build-scratch material under `work/`, `out/` delivery handoff, and local Metal scratch.
- Evidence files were moved byte-for-byte; the five design docs were moved with `git mv` so file
  history follows them. Their prose, numbers and structure are untouched; the **only** post-move edit
  is the markdown link destinations inside them, rewritten from `0X-…md` to `../../0X-…md` (and
  `../app/…`, `../AGENT.md`, `../notes/…` to `../../../…`) so the links still resolve from this folder.
  The SHA-256 values below are therefore of the **pre-move** content (verifiable at `ee0a8f8`).

## 1. Why

Stage 1 closed at HEAD `ee0a8f8`. The owner decided to archive the stage-1 material so stage 2 starts from a clean tree: keep the human-readable design docs, delivery outputs, and text evidence; drop the multi-GB render/encode intermediates, Metal module caches, Mach-O probe binaries, and macOS `.DS_Store` litter.

## 2. Design docs (moved with `git mv`, filenames unchanged)

| Old path | New path | Size (bytes) | SHA-256 (content unchanged) |
| --- | --- | ---: | --- |
| `docs/03-considerations-beyond-the-plan.md` | `docs/archive/stage-1/03-considerations-beyond-the-plan.md` | 32,174 | `01256df28e73c8a601fd41eb57fb4ef15ceea1edd203e2df4a6e041935cbc09c` |
| `docs/04-stage-1-plan.md` | `docs/archive/stage-1/04-stage-1-plan.md` | 21,269 | `452c883c4060b1f75f424d4388160d2609a4735ce1381a53d12e998090006ec0` |
| `docs/05-encoder-verification.md` | `docs/archive/stage-1/05-encoder-verification.md` | 14,300 | `629b7d9cecff197f452df5a5f3befe07c19548a1b4071af63f04b1513a870605` |
| `docs/06-m3-ipad-edr-plan.md` | `docs/archive/stage-1/06-m3-ipad-edr-plan.md` | 22,400 | `79dccf8f205ff589731f7cb650d84f835a5281e762468524af967ea4e3072ca6` |
| `docs/07-m4-m5-output-and-acceptance.md` | `docs/archive/stage-1/07-m4-m5-output-and-acceptance.md` | 42,163 | `f6e2ccb5ff354b6f5b3cdc1cef7dff1faa25919e9027eae9765e926f7dfb84c8` |

## 3. Evidence inventory (`docs/archive/stage-1/evidence/`)

Paths mirror the old `work/` layout: `work/<dir>/<path>` -> `docs/archive/stage-1/evidence/<dir>/<path>`.
Only text files were taken (json, txt, md, log, sh, time, py, html, swift, sha256, exit, css, js, plus 2 `.xmp` metadata dumps that are plain ASCII). Files under `.mc/`, `.tmp/`, `.build/`, `.dd*` scratch subdirectories were deliberately not archived (all were build/temp scratch and were deleted). `work/m21-final/**` was excluded entirely and kept.

**Total: 199 files, 1,428,578 bytes (~1.4 MiB).**

| Source dir | Files | Bytes | Extensions |
| --- | ---: | ---: | --- |
| `work/m0` | 117 | 970,463 | txt×47, json×25, exit×20, log×10, swift×7, xmp×2, py×2, md×2, sh×1, html×1 |
| `work/m4` | 24 | 161,710 | json×9, log×7, time×2, sh×2, md×2, txt×1, swift×1 |
| `work/m5` | 12 | 59,204 | json×7, md×4, log×1 |
| `work/m1-integration` | 9 | 38,157 | json×4, swift×3, txt×1, sh×1 |
| `work/m3` | 25 | 35,693 | json×18, swift×5, txt×1, md×1 |
| `work/review` | 5 | 130,728 | md×5 |
| `work/lead-e2e` | 2 | 23,141 | json×2 |
| `work/lead-smoke` | 4 | 6,542 | swift×3, sha256×1 |
| `work/probe` | 1 | 2,940 | swift×1 |

Extension histogram (whole evidence tree):

| ext | files | bytes |
| --- | ---: | ---: |
| json | 65 | 838,129 |
| md | 14 | 185,405 |
| swift | 20 | 173,881 |
| txt | 50 | 142,486 |
| log | 18 | 36,178 |
| py | 2 | 25,657 |
| sh | 4 | 16,779 |
| html | 1 | 4,315 |
| xmp | 2 | 4,056 |
| time | 2 | 1,554 |
| sha256 | 1 | 98 |
| exit | 20 | 40 |

Most important records (all present, paths relative to `evidence/`):

- `m4/run-m4.sh` (6,330 B) — M4 encode/verify driver
- `m4/deliver-run1.log`, `m4/deliver-run2.log` (1,397 B each) — delivery runs; `m4/deliver-run1.time`, `m4/deliver-run2.time`
- `m4/verify-heic-hdr.json` (28,177 B) + `.log` — HEIC HDR verification
- `m5/ladder.md` (1,297 B), `m5/ab-record.md` (889 B), `m5/ab-key.json` (1,377 B) — M5 A/B acceptance record
- `m3/notes.md` (6,770 B), `m3/evidence/parity-macos.txt` (6,049 B)
- `m0/verify/reports/` — 60 files, 438,330 B (verify exit/stdout/json per case), including `final.json`, `alpha-diff.*`, `headroom-mismatch.*`, `real-R0003777-M0.*`
- `review/*.md` — 5 files, 130,728 B: `2026-11-03-m3-code-review.md`, `2026-11-03-project-review.md`, `2026-11-03-stage1-docs-review.md`, `facts.md`, `structure.md`
- `m0/real/notes.md`, `m0/synthetic/findings.md` (15,937 B)

## 4. Delivery files (`docs/archive/stage-1/delivery/`, moved from `out/`)

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `R0003777-P3-hdr.heic` | 5,798,146 | `826e27599cbbd6308d7695940dd3ec463a39ea5c8814024008bd6f36efb8df69` |
| `R0003777-P3-sdr.heic` | 1,946,906 | `d639359abd87bc9c311d2f7351f79d307e34225269fc21c9236f144f96805b0e` |
| `R0003777-P3.recipe.json` | 543 | `b4cec8a2540d5fad9cc2487c58378a649312b5108ced368404d0ae5f13cc8261` |
| `R0003777-P3.report.json` | 13,650 | `d7d512d13ace18b3247896ea4562f2b3f41f6361e268bf1879003a2faf768bd2` |

## 5. Deleted material

All deletions are recursive removes of paths verified under `/Users/criphc/Sites/llm-photon/work/` plus the named scratch paths. Sizes are per-directory `du -sh` captured before the text evidence was extracted; the "files removed" column counts what was deleted after extraction.

| Path | Size (du) | Files removed after evidence extraction |
| --- | ---: | ---: |
| `work/lead-e2e` | 504 MB | 3 |
| `work/lead-smoke` | 40 MB | 83 |
| `work/m0` | 835 MB | 316 |
| `work/m1-integration` | 1.1 GB | 166 |
| `work/m21-timing` | 0 B (empty) | 0 |
| `work/m3` | 111 MB | 86 |
| `work/m4` | 1.1 GB | 99 |
| `work/m5` | 38 MB | 12 |
| `work/probe` | 4 KB pre-extract, then empty | 0 |
| `work/review` | 140 KB pre-extract, then empty | 0 |
| `.mc-metal/` | 19 MB | 58 |
| `.tmp-metal/` | 24 KB | 3 |
| `.DS_Store` (root, `docs/`, `samples/`; 2 more inside deleted `work/m3`) | 6 KB each | 5 |

**Totals: 829 files deleted, 3,942,479,881 bytes (~3.94 GB; 3.67 GiB) freed.** `work/` dropped from 3.7 GB to 42 MB (the kept fixture below); `du -sh work` after cleanup: 42 MB.

Binary material removed by category (pre-archive counts):

- TIFF render intermediates: 19 `.tif`, 3,330,880,674 B (~3.1 GiB) — the bulk of the reclaimed space (m0/m1/m4 chains).
- Audio/dump `.pcm`: 408 files, 425,407,400 B.
- HEIC renders/inputs: 39 `.heic` (71,573,067 B) + 9 `.HEIC` (15,074,708 B) + 2 `.JPG` + 2 `.jpg` + 1 `.jpeg` (~11.1 MB).
- PNG previews: 9 files, 64,950,424 B.
- Metal/Swift build caches: 209 `.swiftmodule` (799,912 B), `.swiftdoc`, `.swiftsourceinfo`, 1 `.dylib`, 58 `.pcm` in `.mc-metal/`.
- Mach-O probe binaries (extensionless): 15 executables, 2,870,504 B (`probe`, `probe2`, `probe4`, `metalprobe`, `renderer-test`, `previewdebug`, `calibrate`, …).
- macOS metadata: `.DS_Store` (5 files total).

## 6. Intentionally kept: `work/m21-final/` (do not move/delete)

`work/m21-final/` is still in place, untouched (`work/` is gitignored and now contains only this directory):

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `work/m21-final/preview-base.png` | 22,111,140 | `560889ebeb9952f7d2a354e135c627b92c1dd581353758a9090f4422fbf2d84a` |
| `work/m21-final/work/bd486ca6…/preview-base.png` | 22,111,140 | `560889eb…d84a` (same content, nested path) |
| `work/m21-final/{meta.json,p1.json}` + nested `preview-meta.json`, `state.json` | 4,851 | — |

This 22 MB PNG is the iPad parity test fixture, read from that exact path by the M3/iPad parity tests. It was **not** moved into the archive and must not be deleted; do not relocate it.

## 7. Notes / surprises

- No text-extension file turned out to be binary, and no evidence move collided or failed (199/199 moved).
- Two `.xmp` files (`m0/real/logs/aux-metadata-{full,preview}.xmp`, 2,028 B each) are ASCII exiftool metadata dumps. They are not in the listed text extensions but are text evidence, so they were archived under `evidence/m0/real/logs/` rather than deleted.
- `work/m0/real/.tmp/probe*.swift`, `work/m4/probe/.tmp/orient.swift`, and `work/m4/probe/.build/PhotonContract.abi.json` were text but sat in `.tmp`/`.build` scratch dirs, so per the rule they were not archived and were deleted with the scratch trees.
- `samples/.DS_Store` was deleted per the "every `.DS_Store` in the repo" instruction; no file under `samples/` itself changed.
- `.git/` was never touched. Text files under git-tracked `docs/` were not modified, only the five `git mv` renames above.
