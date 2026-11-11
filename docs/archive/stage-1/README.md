# Stage 1 Archive — Read Only

Historical record of **stage 1** (the one-photograph prototype), closed on 2026-11-03 at commit
`ee0a8f8`. It is kept so a decision or a measured number can be traced; it is **not required reading**
for stage 2, and it is **not maintained** — prose and numbers were not rewritten when the project
moved to stage 2 (only the markdown link destinations were; see [MANIFEST.md](MANIFEST.md)), and no
rule should be taken from it without checking the live document that superseded it.

**Live doc set after stage 2 started:** [docs/01](../../01-app-concept-and-three-stages.md) ·
[docs/02](../../02-hdr-highlight-finisher-workflow.md) ·
[docs/08](../../08-technical-reference.md) · [docs/09](../../09-stage-2-handoff.md) ·
[app/README.md](../../../app/README.md) · [contract/README.md](../../../contract/README.md) ·
[ipad/README.md](../../../ipad/README.md) · [AGENT.md](../../../AGENT.md).

## What is here

| File | What it was | Where that content lives now |
|---|---|---|
| [03 — considerations beyond the plan](03-considerations-beyond-the-plan.md) | technical research notes + the encoder/colour/ops facts of stage 1 | encoder/container/colour/verification/ops/performance/hardware → [docs/08](../../08-technical-reference.md); judging protocol, product traps and the M0-measured narratives exist **only here** |
| [04 — M0–M2.1 Mac-side plan and results](04-stage-1-plan.md) | the Mac plan, M0/M1/M2 results, the recipe v0 contract, the M2.1 API contract | recipe schema → [contract/README.md](../../../contract/README.md); M2.1 wire contract → [app/README.md](../../../app/README.md); milestone history exists only here |
| [05 — M0 encoder verification](05-encoder-verification.md) | M0 measurements: container facts, headroom, base fidelity, iPad verdict | verifier behaviour → [docs/08 §5](../../08-technical-reference.md); the measurements exist only here (and in `evidence/m0/`) |
| [06 — M3 iPad EDR client](06-m3-ipad-edr-plan.md) | the iPad plan, architecture, work packages, device acceptance log | architecture/control semantics → [ipad/README.md](../../../ipad/README.md); device-acceptance history exists only here |
| [07 — M4/M5 output and acceptance](07-m4-m5-output-and-acceptance.md) | full-resolution delivery plan, the report contract, the M5 protocol, results | delivery contract + report schema → [app/README.md](../../../app/README.md); acceptance protocol/results exist only here |
| [MANIFEST.md](MANIFEST.md) | what was moved, what was deleted, sizes and hashes | — |
| `evidence/` | all stage-1 text evidence (logs, JSON reports, scripts, device notes, review audits). Paths mirror the old `work/`: `evidence/<dir>/…` was `work/<dir>/…`. | — |
| `delivery/` | the four delivered stage-1 files (`R0003777-P3-{hdr,sdr}.heic`, `.recipe.json`, `.report.json`) | **not in git** (see `.gitignore`); 7,759,245 B (7.40 MiB) local only |

`evidence/review/` is worth knowing about: it holds the two stage-1 documentation audits
(`facts.md`, `structure.md`) and the docs review. They list the defects that existed at closure — useful
when a stage-1 sentence looks wrong, not as a to-do list.

## Notes for a reader

- **Links between the archived docs were rewritten** to `../../0X-…` so they resolve from this folder;
  the prose and numbers are untouched. A link into `work/…` is a record of where evidence used to live —
  look under `evidence/` instead.
- **Binary material was deleted, not archived**: ~3.94 GB of render intermediates (TIFF/PNG/HEIC),
  build scratch and probe binaries under the old `work/` tree, plus the local Metal caches. The
  MANIFEST lists what went. Nothing deleted was version-controlled.
- `work/m21-final/` was deliberately **left in place** (not archived): `preview-base.png` +
  `meta.json` are the trial base that the iPad parity / BasePNG / WireModel tests read, and deleting
  them would make those gates skip silently.
- The stage-1 device screenshots were binary and were deleted with the rest; the textual acceptance
  records that interpret them are in `evidence/m3/` and `evidence/m5/`.
