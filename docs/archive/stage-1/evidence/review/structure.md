# Documentation structure audit — llm-photon

*Audit date 2026-11-03 · stage 1 is closed (docs/07 §10) · audit-only: no tracked file was modified.*

**Scope.** The 12 named files: `docs/01`…`docs/07`, `README.md`, `AGENT.md`, `app/README.md`, `ipad/README.md`, `tools/visual-check/README.md`. Three further **tracked** docs are outside the named set but matter to "the doc set as a set" and are reported in §D.3: `tools/verify-heic/README.md`, `tools/m0-fixtures/README.md`, `notes/Save to HEIC Using Core Image.md`.

**Method.** (1) Extracted every markdown destination in the 12 files — 159 links (157 internal, 2 external), resolved each against its source directory and checked existence. (2) Extracted every textual `§N` / `Mx` / `doc NN` reference (~93) and matched it against the target file's actual heading set. (3) Read all 12 files end to end; every finding below cites `doc:line`. (4) Cross-checked the M4 numbers against the installed artifacts (`out/R0003777-P3.report.json`, `work/m4/*.log`, `work/m4/probe/calibration.md`) where a doc claims "from the report".

**Headline.**

| area | result |
|---|---|
| A. links | 6 **BROKEN** (all one bug, in one file); 0 `#anchor` links in the set; 4 wrong-section + 4 imprecise section refs |
| B. single home | M2.1 is exemplary (docs/04:110 canonical, 9 docs point at it). 5 facts are nonetheless duplicated in detail — worst: `-H` (docs/03:73 ↔ docs/05:60, near-verbatim) |
| C. staleness | stage-1 closure is recorded consistently in 5 status sites, but 8 stale sentences survive in docs/02/03/05 + the README map |
| D. doc set as a set | 3 tracked docs have no owner/list entry; 4 description strings disagree; docs/04 is the only plan doc with no `§` numbering; header labels use 3 different schemes |
| E. numbers | 1 genuine defect (M4 timings: parts do not sum to the stated total and do not match the report); 1 mislabelled "measured" set (`previewAgreement`); 1 cross-recipe pair that needs a one-line label; 2 tiny rounding slips |

**Overall verdict: structurally sound, phase-boundary dirty.** The link graph, heading hierarchy and single-home discipline are in good shape for a doc set that grew M0→M5 in two days. The defects that matter are (a) one hard link bug (`tools/visual-check/README.md`), (b) one hard staleness bug (`docs/03` still says M4 work "remains"), (c) one hard numeric bug (M4 timings), (d) the doc-set bookkeeping (labels, ownership table, README map) which was not carried through when stage 1 closed.

---

## A. Link and anchor integrity

### A.1 BROKEN — 6 links, 1 root cause

Every broken link is in `tools/visual-check/README.md`, and every one uses `../docs/…` from a file that lives two levels down (`tools/visual-check/`). The correct prefix is `../../docs/…`. Nothing else in the 12 files is path-broken.

| # | source | target as written | resolves to | verdict |
|---|---|---|---|---|
| 1 | tools/visual-check/README.md:5 | `../docs/05-encoder-verification.md` | `tools/docs/05-encoder-verification.md` (absent) | **BROKEN** |
| 2 | tools/visual-check/README.md:56 | `../docs/03-considerations-beyond-the-plan.md` | `tools/docs/…` (absent) | **BROKEN** |
| 3 | tools/visual-check/README.md:58 | `../docs/07-m4-m5-output-and-acceptance.md` | `tools/docs/…` (absent) | **BROKEN** |
| 4 | tools/visual-check/README.md:90 | `../docs/07-m4-m5-output-and-acceptance.md` | `tools/docs/…` (absent) | **BROKEN** |
| 5 | tools/visual-check/README.md:96 | `../docs/03-considerations-beyond-the-plan.md` | `tools/docs/…` (absent) | **BROKEN** |
| 6 | tools/visual-check/README.md:99 | `../docs/03-considerations-beyond-the-plan.md` | `tools/docs/…` (absent) | **BROKEN** |

Fix: six `../docs/` → `../../docs/`. (This file was written new in M5.1 and is the only one of the four code-side READMEs whose links were not exercised; `app/README.md:135` and `ipad/README.md:6,7,84` use `../docs/…` correctly because they sit one level down.)

### A.2 WRONG-SECTION / IMPRECISE — section refs whose label does not match the target

No link in the set uses a `#anchor`; all section targeting is textual (`docs/05 §2`, `docs/04 M1`, …), so these can silently rot. Seven of ~93 refs are wrong or imprecise; the rest are OK.

| source | label | what the label promises | what is actually there | verdict |
|---|---|---|---|---|
| docs/04:16 | `docs/05` §2 | `-R` is inert under `-b` / headroom is content-derived | docs/05 §2 ("What the delivered file actually is") describes the container; the `-R` measurement and "what this settled" is **§3.1** | **WRONG-SECTION** (→ §3.1) |
| docs/04:143 | `docs/05` §2 | same claim in the risk table | same | **WRONG-SECTION** (→ §3.1) |
| docs/07:270 | `docs/05` §2 | same claim | same | **WRONG-SECTION** (→ §3.1) |
| docs/07:196 | `docs/03` §5 | "`calculatedContentHeadroom` reported as cross-check" | that fact is docs/05 **§3.3** ("Verifier behaviour"); docs/03 §5 only says "headroom is within 5 %" (docs/03:138) | **WRONG-SECTION** (→ docs/05 §3.3) |
| app/README.md:166 | `docs/01 §0` | "the SDR base is the Capture One export, **bit-exact**, and is never re-graded" | docs/01 §0 states the Capture One export is authoritative and the SDR look must match; it never says *bit-exact*. Bit-exactness is docs/03:139 ("bit-exact pass-through") and docs/04 M1:88 | **WRONG-SECTION** (imprecise) |
| app/README.md:75 | `` `AGENT.md` §Environment `` | the encoder-clone environment fact | AGENT.md has no English "Environment" heading; the section is `## 环境` (AGENT:41) and the fact is AGENT:44 | **WRONG-SECTION** (section name does not exist) |
| docs/03:150 | `docs/07` §2 | "the flat `--out` set" | the four-file contract is docs/07 **§5.3** (docs/07:132-146); §2 only holds the "Output layout" decision row (docs/07:46) | **IMPRECISE** (→ §5.3) |
| docs/07:19 | `docs/03` §5 | "records every check of docs/03 §5" | docs/03 §5 holds thresholds, the five-rung ladder and reject criteria; the 8-check list is docs/07 §5.3/§5.4 (and docs/05 §3.3 for two of them) | **IMPRECISE / over-claim** |
| docs/07:189 | `docs/03` §5 | "Numeric thresholds and reject criteria live in docs/03 §5" | `baseDeltaE`, the ladder and reject criteria do; `previewAgreement`, `fallback` and the container/identity/alpha thresholds are defined **in this very table** and in docs/05 §3.3 | **IMPRECISE / over-claim** |
| docs/06:198 | `§1.7–§1.9` | sections 1.7–1.9 of docs/06 | §1 has **no** sub-headings; these are acceptance **items 7–9** of the list at docs/06:14-25 — the `§N.N` notation collides with the heading notation used everywhere else (cf. docs/07:308 which writes "§1 item N") | **STYLE** (see D.4) |

### A.3 The three links called out in the brief

- **`notes/Save to HEIC Using Core Image.md`** (docs/03:3): **OK.** The file exists (tracked, 282 lines), the destination is written in CommonMark angle-bracket form `(<../notes/Save to HEIC Using Core Image.md>)` because of the spaces, and resolves from `docs/` to `notes/`. Angle-bracket destinations with literal spaces are valid CommonMark/GFM — no `%20` needed. It is the only inbound link to `notes/` in the whole set.
- **`../app/README.md`** (docs/04:7): **OK** — resolves to `app/README.md`, which exists and is tracked.
- **"docs/04 §2.1"**: **no such reference exists anywhere in the 12 files.** This matters: `docs/04` has no `§` numbering at all (its headings are `### M0`, `### M1`, `### M2`, `#### M2.1`), so every ref to it in the set correctly uses milestone ids — `docs/04 M1` (docs/07:70), `docs/04 M2.1` (docs/07:72), `ipad/README.md:7` — and all of those ids resolve. The "M2.1 — the base-first contract" heading is a `####` heading with a suffix, so the prose refs "docs/04 的 M2.1 一节" (AGENT:52) and "『M2.1 — the base-first contract』" (docs/01:65, docs/03:151/182, docs/06:3) match the heading text.

### A.4 Full link inventory (all 159 links, grouped by source:target)

Verdict = path existence only, except where §A.2 records a wrong section label.

| source | target | lines | verdict |
|---|---|---|---|
| docs/01 | 02-hdr-highlight-finisher-workflow.md | 4 | OK |
| docs/01 | 03-considerations-beyond-the-plan.md | 4, 67 | OK |
| docs/01 | 04-stage-1-plan.md | 4, 65, 70, 75, 93 | OK |
| docs/01 | 05-encoder-verification.md | 4 | OK |
| docs/01 | 06-m3-ipad-edr-plan.md | 4, 66, 70, 87, 93 | OK |
| docs/01 | 07-m4-m5-output-and-acceptance.md | 4, 60, 67, 68, 70, 93 | OK |
| docs/02 | 01-app-concept-and-three-stages.md | 4, 9 | OK |
| docs/02 | 03-considerations-beyond-the-plan.md | 4 | OK |
| docs/02 | 04-stage-1-plan.md | 4, 9 | OK |
| docs/02 | 05-encoder-verification.md | 4 | OK |
| docs/02 | 06-m3-ipad-edr-plan.md | 4, 9 | OK |
| docs/02 | 07-m4-m5-output-and-acceptance.md | 4, 9 | OK |
| docs/03 | `../notes/Save to HEIC Using Core Image.md` | 3 | OK |
| docs/03 | 01-app-concept-and-three-stages.md | 4 | OK |
| docs/03 | 02-hdr-highlight-finisher-workflow.md | 4 | OK |
| docs/03 | 04-stage-1-plan.md | 4, 123, 151, 152, 182 | OK |
| docs/03 | 05-encoder-verification.md | 4, 115 | OK |
| docs/03 | 06-m3-ipad-edr-plan.md | 4, 135, 152 | OK |
| docs/03 | 07-m4-m5-output-and-acceptance.md | 4, 150, 156 | OK |
| docs/03 | `https://developer.apple.com/…/headroom-adaptive-gain-curve` | 26 | OK (HTTP 200) |
| docs/03 | `https://developer.apple.com/…/hdrgainmapimage` | 102 | OK (HTTP 200) |
| docs/04 | `../app/README.md` | 7 | OK |
| docs/04 | 01-app-concept-and-three-stages.md | 4, 5, 7, 133 | OK |
| docs/04 | 03-considerations-beyond-the-plan.md | 4 | OK |
| docs/04 | 05-encoder-verification.md | 7, 47 | OK |
| docs/04 | 06-m3-ipad-edr-plan.md | 5, 7, 108, 125 | OK |
| docs/04 | 07-m4-m5-output-and-acceptance.md | 5, 7, 7, 20, 150 | OK |
| docs/05 | 03-considerations-beyond-the-plan.md | 3 | OK |
| docs/05 | 04-stage-1-plan.md | 3, 103 | OK |
| docs/05 | 07-m4-m5-output-and-acceptance.md | 97 | OK |
| docs/06 | `../AGENT.md` | 120 | OK |
| docs/06 | 01-app-concept-and-three-stages.md | 3, 4, 137, 160, 175 | OK |
| docs/06 | 03-considerations-beyond-the-plan.md | 3, 137, 151, 181 | OK |
| docs/06 | 04-stage-1-plan.md | 3, 6, 137, 200 | OK |
| docs/06 | 07-m4-m5-output-and-acceptance.md | 4, 137, 143 | OK |
| docs/07 | 01-app-concept-and-three-stages.md | 4, 6, 36, 44, 48, 52, 56, 218, 260, 278, 366 | OK |
| docs/07 | 02-hdr-highlight-finisher-workflow.md | 46, 58 | OK |
| docs/07 | 03-considerations-beyond-the-plan.md | 4, 17, 19, 22, 32, 34, 51, 56, 66, 67, 71, 130, 189, 196, 197, 248, 252, 272, 337, 343 | OK (labels at 196/189 — see A.2) |
| docs/07 | 04-stage-1-plan.md | 4, 31, 58, 70, 72, 124, 226 | OK |
| docs/07 | 05-encoder-verification.md | 4, 18, 50, 66, 70, 198, 270 | OK (label at 270 — see A.2) |
| docs/07 | 06-m3-ipad-edr-plan.md | 3, 4, 54, 69, 127, 200, 213, 226, 242 | OK |
| README | docs/01 … docs/07 | 26, 27, 28, 29, 30, 31, 32 | OK |
| app/README | `../docs/04-stage-1-plan.md` | 135 | OK |
| ipad/README | `../docs/04-stage-1-plan.md` | 7 | OK |
| ipad/README | `../docs/06-m3-ipad-edr-plan.md` | 6, 84 | OK |
| tools/visual-check/README | `../docs/03-…` | 56, 96, 99 | **BROKEN** |
| tools/visual-check/README | `../docs/05-…` | 5 | **BROKEN** |
| tools/visual-check/README | `../docs/07-…` | 58, 90 | **BROKEN** |

### A.5 Non-markdown path references

Textual refs were checked too: `docs/03` §1…§9 all exist with the promised content (notably §5 = judging/ladder/reject/base-comparisons — the refs from docs/07:17,19,32,34,189,196,197,248,252,337,343 land in the right place); `docs/05` §2/§3.1/§3.2/§3.3/§4/§6/§7 all exist; `docs/06` §4.1/§4.5/§6/§10 exist; `docs/07` §2/§5.3/§5.4/§6/§7/§10 exist; `docs/01` §0/§1/§1.4/§2/§2.1 exist; `docs/04` M0/M1/M2/M2.1 exist; `AGENT.md` refs to `docs/03 §3` (AGENT:45), `docs/03 §6` (AGENT:24), `docs/07 §5.3/§5.4` (AGENT:25), `docs/03 §5` (AGENT:26), `docs/06 §4.1` (AGENT:47,71), `docs/07 §7` (AGENT:51,69) all match. The only dangling *name* is `AGENT.md §Environment` (app/README.md:75, A.2).

---

## B. Single-home violations

Ownership baseline = AGENT:57-73 plus the rule at AGENT:79 ("一件事只详细写一次 … 其他文档写一句加链接"). Legend for the verdict column: **(i) owned** = this doc is the AGENT-designated home for this content; **(ii) legitimate pointer** = one line + link, or content the doc's own ownership row covers; **(iii) real duplicate** = full detail stated outside the home, will drift.

### B.1 `-R` is inert under `-b` / headroom is content-derived

Home: docs/03 §3 (encoder behaviour, AGENT:45).

| site | what it says | verdict |
|---|---|---|
| docs/03:71 | option list: "`-R` headroom cap (**ignored with `-b`, see next**)" | (i) owned |
| docs/03:72 | full measurement: three `-R` values byte-identical; `AlternateHeadroom ≈ log2(authored peak)`; "no CLI flag caps delivery headroom"; evidence → docs/05 | (i) owned |
| docs/05:57 | full restatement of the same measurement + the rule ("The headroom cap must be applied to the HDR rendition pixels; no CLI flag does it"), with a −0.005-stop offset | (ii) borderline — docs/05 is the M0 evidence home (AGENT:65), the *numbers* belong here, but the bolded rule sentence duplicates docs/03:72 |
| docs/04:16 | decision 2 restates the rule **and** the measurement values (`AlternateHeadroom = log2(2.5) = 1.321928`, decoded `contentHeadroom = 2.4999998`) | **(iii) real duplicate** — a decision record should state the decision and cite docs/03 §3 + docs/05 §3.1 |
| docs/04:66 | recipe-field table: "`-R` does not do this" | (ii) legitimate pointer |
| docs/04:143 | risk table row + link to docs/05 §2 (wrong § — A.2) | (ii) legitimate pointer |
| docs/05:7 | "read this note together with the updated docs/03 §3" | (ii) |
| docs/05:119 | "`hdr.headroom_cap` … the only control of delivered headroom … `-R` must not be relied on" | (ii) summary |
| docs/05:125 | changelog: docs/03 §3 corrected | (ii) |
| docs/05:129 | constraint 1: "Clamp the HDR rendition pixels; `-R` cannot do it" | (ii) one-line constraint |
| docs/07:66 | constraints list: "`-R` is inert under `-b`" + links | (ii) legitimate pointer |
| docs/07:96 | component table: "…rely on `-R`" (as a "must not") | (ii) |
| docs/07:270 | risk row + link (wrong § — A.2) | (ii) |
| app/README.md:162 | "`-R` is inert with `-b`; the cap is authored into the pixels (docs/05 §3)" | (ii) legitimate pointer |

Assessment: the *rule* has one home (docs/03:72) but is restated as a rule in 5 other places, and the measurement values live in both docs/03:72 and docs/04:16. Not the worst case, but docs/04:16 is a genuine (iii).

### B.2 `-H` corrupts the metadata and clips

Home: docs/03 §3 (AGENT:45).

| site | what it says | verdict |
|---|---|---|
| docs/03:73 | full: re-enables headroom analysis, hard-codes `AlternateHeadroom = 2.300450`, clips (4.0 → 2.01), switches map `nclx` PQ→sRGB | (i) owned |
| docs/05:53 | `-H` row of the M0 measurement table (bytes, headroom, peak) | (ii) evidence |
| docs/05:60 | **near-verbatim** copy of docs/03:73: "hard-codes `AlternateHeadroom = 2.300450` (over-promising 2.45× where the content peaks at 2.01×), normalises the gain … clipped (authored 4.0 → 2.01), and switches the map's `nclx` transfer from PQ to sRGB" | **(iii) real duplicate** — the two sentences will drift independently |
| docs/05:125 | changelog | (ii) |
| docs/05:132 | "Never `-H`, and always pass `-b` (see §3.1)" | (ii) |
| docs/05:135 | "no working subsampling route (`-H` is broken)" | (ii) |
| docs/04:70 | recipe-field table: "✔ M0 measured it corrupts the headroom metadata and clips highlights" | (ii) one-line measured claim |
| docs/04:143 | risk row: "`-H` writes wrong metadata and clips" | (ii) |
| docs/07:66 | "never `-H`" + links | (ii) |
| docs/07:96 | component table: "use `-H`" (must-not) | (ii) |
| docs/07:270 | risk row | (ii) |
| app/README.md:19 | "Encoder.swift … (never `-H`, always `-b`)" | (ii) |
| app/README.md:105 | "encodes with the external tool (`-b`, never `-H`)" | (ii) |

Assessment: **the clearest violation in the set** — docs/05:60 is a full duplicate of the home sentence, not a pointer, and it is the one fact where a re-verification would require editing two prose blocks word-for-word.

### B.3 The 1.05 authored-peak floor (+ `EncodedHEICValidator` read-back)

Home: docs/03 §3 (tool behaviour, docs/03:78) + docs/04 M1 (pipeline enforcement, docs/04:95) — a two-part home that is itself a mild smell but is stated in the AGENT table (docs/03 = encoder details; docs/04 = implementation).

| site | what it says | verdict |
|---|---|---|
| docs/03:78 | "if the HDR peak is < 1.05 the tool warns and writes a plain SDR HEIC with alpha, exit code 0 … the pipeline enforces this (`docs/04` M1)" | (i) owned |
| docs/04:95 | M1 result: `PhotonError.hdrTooDim`, the reason, `EncodedHEICValidator` read-back (ISO aux / headroom ±5 % / no alpha / dims) and "the shared assertion the M4 delivery report reuses" | (i) owned (docs/04 owns M1 implementation/result) |
| docs/05:131 | constraint 3: assert the peak, "below it the tool silently writes an SDR HEIC *with alpha* and exits 0" | (ii) evidence-derived constraint; the italic detail duplicates docs/03:78 |
| docs/07:18 | M4 acceptance item 3: "the encoder's 1.05 floor is asserted *before* encoding (docs/05 §6)" | (ii) legitimate pointer |
| docs/07:66 | constraints list: "1.05 read-back floor before encoding" + links | (ii) |
| docs/07:106 | data flow step 4: "Assert the authored peak ≥ the 1.05 floor" | (ii) |
| docs/07:157 | error table: "authored peak below the encoder's 1.05 floor → `hdrTooDim`" | (ii) — contract, docs/07's own |
| docs/07:198 | `clipping` check: "authored peak ≥ 1.05" | (i) — report spec, docs/07's own |
| app/README.md:104 | "refuses a rendition below the encoder's 1.05 floor" | (ii) |
| app/README.md:163-165 | full standalone rule: "the encoder's `exit 0` is not proof: the authored peak must be ≥ 1.05 before encoding (below it the tool silently writes an SDR HEIC) and `EncodedHEICValidator` reads the encoded file back (ISO gain-map aux, `contentHeadroom` ±5%, no alpha)…" — **no doc reference** | **(iii) real duplicate** of AGENT:23 + docs/03:78 + docs/04:95 |
| AGENT:23 | the rule + validator + "详见 `docs/04` M1" | (i) — AGENT owns the non-negotiable rules |

Assessment: 11 sites for one rule; only app/README:163-165 is a real (iii) because it restates the whole contract without a pointer. (docs/07's five mentions are pointer/contract-shaped and acceptable.)

### B.4 `CIImage(bitmapData:)` buffer-ownership rule

Home: docs/03 §3 (docs/03:113).

| site | what it says | verdict |
|---|---|---|
| docs/03:113 | full: neither copies nor retains the `Data`; symptom (25 % RMSE preview, 149× peak, 1 run in 4); correct `bitmapInfo`; P1-3 covers all writers | (i) owned |
| docs/04:93 | M1 result records the bug: "a 25 % RMSE preview and a 149× decoded peak in 1 run of 4 … gotcha is recorded in `docs/03` §3" | (ii) borderline — legitimate as a result record, but it repeats the two symptom numbers that docs/03:113 also states |
| docs/07:67 | constraint: build via provider-backed `CGImage`; "no new `CIImage(bitmapData:)` in the delivery path" + link | (ii) |
| app/README.md:25, 177-178 | "ImageBuffers … provider-backed CGImage/CIImage chain (P1-3)" / "a `CIImage` must own its buffer … (docs/03 §3)" | (ii) |
| AGENT:53 | rule + "症状与正确 bitmapInfo 见 `docs/03` §3" | (i) |

Assessment: **clean.** This is how the rule should be handled everywhere (docs/04:93 is the only soft spot).

### B.5 Display-P3-only source enforcement

Home: docs/03 §4 (colour/why, docs/03:123) + docs/04 decision 1 (the contract/enforcement, docs/04:15).

| site | what it says | verdict |
|---|---|---|
| docs/03:123 | "Stage 1 accepts Display P3 sources only", why (Adobe RGB gamut), "✔ Since 2026-11-03 the decoder enforces it: `SourceDecoder` refuses … `PhotonError.unsupportedSource` instead of clamping (review P1-4)" | (i) owned |
| docs/04:15 | decision 1: "Enforced since 2026-11-03 (review P1-4): `SourceDecoder` refuses any source that is not Display P3 (`unsupportedSource` → HTTP 422 `source_unreadable`) instead of letting 16-bit quantisation silently clamp out-of-gamut samples" | **(iii) partial duplicate** — the *why* and the P1-4 enforcement narrative repeat docs/03:123; docs/04 should keep only "Display P3; refusal is `unsupportedSource`; mapping in the errors section (docs/04:129)" |
| docs/04:129 | error table: 422 `source_unreadable` also covers non-P3 | (i) — API contract, docs/04's own |
| docs/07:68 | "No alpha (decision 5) and Display P3 only (decision 1, enforced at decode)" | (ii) |
| docs/07:156 | error table: non-P3 → `unsupportedSource` | (ii) contract |
| docs/06:73, 127 | data-flow step "422 `source_unreadable`" / contract fact "A readable but non-Display-P3 source fails `prepare` with 422" | (ii) — docs/06 explicitly says it does not repeat the M2.1 contract (docs/06:6) |
| app/README.md:16, 172 | "(Display P3 sources only …, P1-4, docs/03 §4)"; "only Display P3 sources are accepted … (P1-4, docs/03 §4)" | (ii) |
| docs/01:34, 74 | product-level statement + link to docs/03 §4 | (ii) |
| docs/02:27 | user-level statement + link | (ii) |
| README:50 | "工具只接受 P3 那份 … 见 `docs/03` §4" | (ii) |
| AGENT:19 | rule + "P3 导出路径见 `docs/04` decision 1，原因见 `docs/03` §4" | (i) |

Assessment: two docs narrate the same P1-4 enforcement story in detail (docs/03:123, docs/04:15); the rest are pointer-shaped and fine.

### B.6 `AtomicFile` / `rename(2)` rule

Home: docs/03 §6 (docs/03:154).

| site | what it says | verdict |
|---|---|---|
| docs/03:154 | "The implementation is `AtomicFile` (`rename(2)`, P1-7) — remove-then-move is not atomic and is forbidden." | (i) owned |
| docs/04:96 | M1 P1 note: preview/meta/png "replaced by `rename(2)` (`AtomicFile`) instead of remove-then-move" | (ii) result record |
| docs/04:131 | M2 cache paragraph: "Every sidecar, the base PNG and `preview.heic` are replaced with temp file + `rename(2)` (`AtomicFile`)" | (ii) result record |
| docs/07:22 | acceptance item 7: "every replaceable file goes through `AtomicFile` (docs/03 §6)" | (ii) pointer |
| docs/07:71 | constraints: "`AtomicFile` for every replaceable artifact" | (ii) |
| docs/07:98 | component table: "every file replaced atomically / `AtomicFile`" | (ii) |
| docs/07:144-146 | "Every installed file goes through a same-directory temp file + `rename(2)` (`AtomicFile`) … the four files are not one transaction" | (ii) — mostly the M4-specific transaction nuance, but the mechanism sentence duplicates docs/03:154 |
| app/README.md:34, 175-176 | layout "temp file + rename(2) atomic replacement (… P1-7)" / "never remove-then-move (P1-7, docs/03 §6)" | (ii) |
| AGENT:24 | rule + `docs/03` §6 | (i) |

Assessment: acceptable; the only overlap to collapse is one mechanism sentence in docs/07:144.

### B.7 The two base comparisons (render bit-exact vs container ΔE)

Home: docs/03 §5 (docs/03:139).

| site | what it says | verdict |
|---|---|---|
| docs/03:139 | full: render comparison (bit-exact, ΔE 0.000, target mean < 1 / p95 < 2) vs container comparison (4:2:0 HEVC, measured 1.44 / 4.12, gate mean ≤ 2.5 / p95 ≤ 6.0); "do not conflate them" | (i) owned |
| AGENT:26 | both rules with numbers + `docs/03` §5 | (i) — AGENT owns non-negotiable rules; has the pointer |
| docs/07:17 | acceptance item 2 restates both thresholds + link | (ii) acceptable |
| docs/07:197 | `baseDeltaE` check row: gate + "see the two-comparison rule in docs/03 §5" + measured 1.44 / 4.12 | (i) — docs/07 owns the verification report |
| docs/07:337-344 | "Deviation recorded (M4.3)": re-explains the rule, the 8-bit/4:2:0 reason, the numbers (1.4406 / 4.1200), the quantisation split (~0.268 / 0.59) and the conclusion | **(iii) real duplicate** — the *deviation* is M4-specific and belongs here, but the rule + numbers are docs/03 §5's; this paragraph should be 3 lines + a link |
| docs/05:70 | "(M4 will add ΔE2000 per docs/03 §5.)" | stale pointer (see C.1) |
| docs/07:329 | measured 1.4406 / 4.1200 in the result table | (i) result |

Assessment: 6 sites, and this is exactly where drift has already happened elsewhere (`previewAgreement` numbers in §5.4 vs §10 — E.2).

### B.8 The 2.5 headroom cap

Home: docs/04 decision 2 (the cap value and that it is enforced on pixels, docs/04:16) + docs/04 recipe field (docs/04:66) + docs/06 §2/§4.3 (M3 fixed it, docs/06:34/89).

| site | verdict |
|---|---|
| docs/04:16, 66 | (i) owned (but 16 carries measurement numbers — B.1) |
| docs/06:34, 89, 91, 93 | (i) owned — M3 decision/control model/cap semantics |
| docs/07:53 ("cap and maths … 2.5, fixed by M3"), 196 (headroom check), 218 ("2.5 cap stays as M3 left it") | (i)/(ii) — docs/07 owns the delivery contract |
| docs/01:65, 87 | (ii) stage-1 DoD, product-level |
| docs/02:131 | (ii) user-facing setting (docs/02 owns UX) |
| docs/05:119 | (ii) |
| docs/03:129 ("Set headroom to the actual peak", generic) | (ii) |

Assessment: 11 mentions but nearly all are one-liners; no action beyond docs/04:16's numbers.

### B.9 M2.1 base-first decision

Home: docs/04 §M2.1 — the heading itself says "canonical home; every other doc points here" (docs/04:110).

| site | verdict |
|---|---|
| docs/04:110-133 | (i) owned |
| docs/01:65, 75, 87 | (ii) product-level + link |
| docs/03:175, 182 | (ii) — and explicitly "this section keeps only the measurements that motivated it" (docs/03:182). Model behaviour |
| docs/06:3, 6, 12, 43, 129 | (ii) — "this document does not repeat the M2.1 endpoints or error table" (docs/06:6) |
| docs/07:103, 218, 371 | (ii) |
| app/README.md:135-139 | (ii) — "The API contract lives in one place" + link |
| README:7 | (ii) |
| AGENT:52 | (ii) |
| docs/02:39-40 | (ii) |

Assessment: **no violation.** This is the reference pattern for the rest of the set.

### B.10 The five most serious violations (ranked)

1. **`-H` full duplicate** — docs/05:60 repeats docs/03:73 almost verbatim, and docs/05:53 adds the same table row. The home (docs/03 §3) is unambiguous, so docs/05:60 should become one sentence + "see docs/03 §3".
2. **Two base comparisons** — home docs/03:139, but fully re-explained with numbers in docs/07:337-344 on top of docs/07:17/197 and AGENT:26. This is the fact where drift is *already observable* in a sibling metric (E.2), so it is the highest-risk duplicate.
3. **1.05 floor + `EncodedHEICValidator`** — one contract, 11 sites; app/README.md:163-165 states the whole rule with **no pointer to any doc**, so it is a third independent copy alongside AGENT:23 and docs/03:78/docs/04:95.
4. **Encoder measurements inside docs/04 decisions** — docs/04:16 (and to a lesser degree docs/04:143) restates `-R` inertness and the measured `AlternateHeadroom`/`contentHeadroom` values that belong to docs/03:72 + docs/05 §3.1. A decision record should freeze the decision, not the evidence.
5. **Display-P3 enforcement narrative** — the P1-4 story ("refuses instead of silently clamping, `unsupportedSource`") is written in detail twice (docs/03:123, docs/04:15); pick docs/03 §4 for the *why* and leave docs/04 with the decision + error mapping.

Honourable mentions: docs/03:113 ↔ docs/04:93 (CIImage symptom numbers duplicated); docs/07:144-146 (AtomicFile mechanism sentence duplicated from docs/03:154); 2.5 cap (11 sites, but mostly legitimate one-liners — no action).

---

## C. Staleness / phase-boundary inconsistency

### C.1 Stale sentences

The conclusion "stage 1 closed" is recorded correctly in docs/01:60, docs/04:7, docs/06:6, docs/07:6 and README:7. The residue is concentrated in the two *older* docs and in the top-level map.

| # | doc:line | stale text (abridged) | corrected fact | severity |
|---|---|---|---|---|
| C1 | **docs/03:151** | "**M2 status:** … Recipe-keyed full renders and the FSEvents watcher remain M4/stage-2 work." | recipe-keyed full renders **shipped in M4** — that is exactly what `photon deliver` is (docs/07 §5.3, §10; AGENT:50). Only the FSEvents watcher remains stage 2 (docs/01 §2.1). | **high** |
| C2 | **docs/02:9** | "Stage 1 is the command-line loop **being built now** … the delivered HEIC **is written at full resolution in M4**." | stage 1 is **closed 2026-11-03** (docs/01:60, docs/07 §10); the loop is `photon prep` / `photon serve` + **`photon deliver`** at full resolution. The sentence also omits `deliver` from the stage-1 description. | **high** |
| C3 | docs/02:27 | "in stage 1 you point `photon prep` / `photon serve --batch` at the export folder yourself" | stage 1's output step is `photon deliver … --out` (docs/07 §5.3, app/README:92-99); prep/serve alone do not produce a deliverable. | medium |
| C4 | docs/05:97 | "**M5.1 will promote** a generalised copy into `tools/visual-check/`" | done — `tools/visual-check/` exists with `serve.py`, `index.html`, `make-ab-set.py`, `README.md` (docs/07 §10 M5). | high |
| C5 | docs/05:70 | "(**M4 will add** ΔE2000 per docs/03 §5.)" | M4 added it: docs/07 §5.4 `baseDeltaE`, measured mean 1.4406 / p95 4.1200 (§10). | medium |
| C6 | docs/05:5 / docs/05:95 | "…passes in both viewers. **M1 may start.**" / "M0 is green; **M1 may start**." | M1–M5 all closed. docs/05 is declared "历史证据，不是规范" only in AGENT:65 — the file itself carries no "historical record, executed 2026-11-02" banner (it has the date at docs/05:3 but not the "M1–M5 complete" context). Add a one-line banner; otherwise these read as pending gates. | medium |
| C7 | docs/05:134 | "…and ΔE2000 in M4" | M4 has it (docs/07 §5.4); same class as C5. | low |
| C8 | **README.md:12** | "`app/` Mac 端 SwiftPM 包：PhotonCore（M1 管线）+ PhotonServer（M2 LAN API）+ **photon CLI（prep / serve）**" | CLI is `prep` / `serve` / **`deliver`** (AGENT:50, app/README:92); the package also carries `DeliveryPipeline`/`DeliveryReport`/`DeliveryVerifier` (app/README:27-33). The map a newcomer reads first is stale. | **high** |
| C9 | **README.md:18** | tools tree: "toGainMapHDR/ · verify-heic/ · m0-fixtures/" | missing `visual-check/` (M5.1, docs/07 §10; AGENT:51). | medium |
| C10 | docs/06:23 | acceptance item 8: "`cd app && make test` is **229** tests and green" | current count 255 (docs/07:307, app/README:65). Correct **for M3 acceptance** (docs/06:195) but the acceptance rule reads as live. Add "at M3 acceptance". | low |
| C11 | docs/04:108 | "**Deliberately out of M2:** … full-resolution render of a posted recipe (M4 — the recipe is stored and validated, not applied)" | true of M2, but at HEAD the parenthetical reads as "no full-res render exists". Add "(shipped in M4 — docs/07 §10)". | low |
| C12 | docs/04:4 | "Read doc 01 §1 and doc 03 §3 first; **this file only turns them into work packages**." | false: docs/04 also carries the recipe schema (docs/04:51) and the canonical M2.1 API contract (docs/04:110, and the doc says so at docs/04:7/150). | low |
| C13 | docs/03:152 | "**M2 status:** LAN HTTP + a per-session bearer token only. … **Until then** the server is plain HTTP…" | the facts survive through M5/M3 (TLS/Bonjour still unscheduled), but a 3-milestone-old "M2 status" label in the current tense is misleading; keep the fact, retitle. | low |
| C14 | docs/06:143 / docs/06:179-181 | "Acceptance passes; **M4 can start**" / "**## 9. Handoff to M4**" + present tense "M4 applies the posted recipe…" | M4 and M5 are done (docs/07 §10). Acceptable as a historical plan table, but §9 reads as pending — mark it "completed (docs/07 §10)" or make it a results link. | low |
| C15 | docs/06:206 | "This is a note for M4/M5 and for any later revisit of the cap" | M4/M5 done; the note is now for a later cap revisit only. | low |
| C16 | docs/07:3 | "created 2026-11-03 · starts after M3" | historical, correct at authoring; fine. (Listed only to show it was checked.) | — |
| C17 | AGENT:50-52 | "M4 交付 … / M5 视觉验收工具 … / M2 服务 …" | **checked: no stale or future claim.** M4/M5 are described in the present tense and match docs/07 §10, `tools/visual-check/`, app/README. The "M2 服务" / "M2.1 起" framing is historical but factual. AGENT is the one file that was carried through the closure correctly. | OK |

Phase-boundary verdict: the closure itself is consistent; what was not carried through is (a) the two older docs (docs/02, docs/03), (b) docs/05's future-tense pointers, and (c) the README map. No doc still claims a *milestone plan* is unstarted, and no doc claims stage 2 started.

### C.2 Doc-title / label scheme after stage 1

Header label lines:

| doc | line 3 label | assessment |
|---|---|---|
| docs/01 | "**Design document 1** · derived from …" | scheme A |
| docs/02 | "**Design document 2** · the user-facing guide …" | scheme A |
| docs/03 | "**Design document 3** · derived from …" | scheme A |
| docs/04 | "*Prepared at end of the design session; M0 executed 2026-11-02.*" | **no number/label** |
| docs/05 | "*Stage 1, milestone M0 · executed 2026-11-02 …*" | **no number/label** |
| docs/06 | "**Plan document 6** · created 2026-11-03 · inputs: …" | scheme B |
| docs/07 | "**Plan document 7** · created 2026-11-03 · starts after M3 …" | scheme B |

So the set uses **three** numbering conventions: "Design document N" (01–03), "Plan document N" (06–07), and nothing (04–05) — the two documents that are the *most* plan-like (04 is the M0–M2.1 plan; 05 is the M0 result record) are the ones without a label, and the "Plan" label is on the two docs that contain plan **and** results. In addition, docs/04, 06, 07 all begin their H1 with "**Stage 1 —**", a phase token that no longer distinguishes a document now that the phase is closed; docs/01 also covers stages 1–3 but is not prefixed, and docs/02 is explicitly a stage-2 target.

Is **docs/04's title** ("Stage 1 — M0–M2.1: Mac-Side Plan and Results") still coherent after stage 1? **Yes as scoped, no as presented.** The document declares at docs/04:5/7/133/150 that it stays the M0–M2.1 record and only points at M3/M4 results — so the title is not false. But its Status paragraph (docs/04:7) now summarises M3 and M4 completion, and its "## Next" section (docs/04:148-150) exists solely to say "nothing more here" — a hybrid that a reader will misread as "this doc covers everything through stage 1". Recommendation: either retitle it (e.g. "Stage 1 — M0–M2.1 (Mac side): plan, results and the M2.1 contract"), or move the M3/M4 status sentence and the "Next" section to a 2-line "Closure" paragraph and keep the title purely M0–M2.1. Separately, normalise the header label across all 7 docs (one of: keep "Design document N" for all, or drop the labels and rely on `NN-` filenames — the current split Design/Plan/none is not derivable by a reader).

---

## D. Coverage and consistency of the doc set

### D.1 Presence matrix

Legend: ✓ = listed; — = not listed; ✗ = missing and should arguably be listed.

| doc | docs/01 companion (01:4) | docs/03 companion (03:4) | README doc table (26-32) | AGENT "文档" list (7-13) | AGENT ownership table (61-73) |
|---|---|---|---|---|---|
| docs/01 | — (self) | ✓ | ✓ 26 | ✓ 7 | ✓ 61 |
| docs/02 | ✓ | ✓ | ✓ 27 | ✓ 8 | ✓ 62 |
| docs/03 | ✓ | — (self) | ✓ 28 | ✓ 9 | ✓ 63 |
| docs/04 | ✓ | ✓ | ✓ 29 | ✓ 10 | ✓ 64 |
| docs/05 | ✓ | ✓ | ✓ 30 | ✓ 11 | ✓ 65 |
| docs/06 | ✓ | ✓ | ✓ 31 | ✓ 12 | ✓ 66 |
| docs/07 | ✓ | ✓ | ✓ 32 | ✓ 13 | ✓ 67 |
| app/README.md | — | — | — | — | ✓ 68 |
| ipad/README.md | — | — | — | — | ✓ 70 |
| tools/visual-check/README.md | — | — | — | — | ✓ 69 |
| contract/ | — | — | — | — | ✓ 71 |
| README.md / AGENT.md | — | — | — | — | ✓ 72 / 73 |
| **tools/verify-heic/README.md** | — | — | — | **✗** | **✗** |
| **tools/m0-fixtures/README.md** | — | — | — | **✗** | **✗** |
| **notes/Save to HEIC Using Core Image.md** | — | — | — (README:16 mentions `notes/` only as a directory) | **✗** | **✗** |

Findings:
- All 7 design docs are present everywhere they should be. The three code-side READMEs are only in the ownership table — defensible (the "文档" list is scoped to `docs/`), but nothing says so, and README's doc table gives a reader no link to `app/README.md`, `ipad/README.md`, `tools/visual-check/README.md` or `contract/`.
- **Three tracked docs have no owner and no list entry** (D.3): this is the biggest coverage gap. `tools/verify-heic/README.md` is 205 lines of *normative* content (a check table with PASS conditions, "ImageIO observations M4 must know") that overlaps docs/05 §3.3 and docs/03 §3 — with no ownership row it is free to drift from both, and it already has (stale "M4 will add ΔE2000", stale "M0 now, M4/M5 later").
- docs/04/05/06/07 do not carry a companion-doc line (only 01/02/03 do) — acceptable (their header lines carry `inputs:`/`scope:` instead), but it means the "Companion docs" convention is only 3/7 applied.

### D.2 Description-string comparison (same doc, different descriptions)

| doc | AGENT "文档" | AGENT ownership | README table | companion label (docs/01:4, docs/03:4) | issue |
|---|---|---|---|---|---|
| 01 | "应用是什么、阶段边界、stage-1 DoD" | "产品概念、阶段边界、范围、stage-1 DoD、产品级决策" | "应用是什么；原型 → 体验优化 → 反馈三个阶段" | "app concept and three stages" | minor drift (README's framing is fine, but three variants) |
| 02 | "面向使用者的快速指南：导出 → 准备 → 调整 → 输出" | "用户使用体验（stage 2 的目标形态；不写实现）" | same as AGENT list | "the quick guide" | **AGENT contradicts itself**: line 8 omits "stage 2 target", line 62 says the doc is a stage-2 target and must not write implementation. docs/02:127 does write recipe fields/CLI flags (`hdr.headroom_cap`, `encoder.quality`, `--preview-edge`) — arguably a small violation of its own "不写实现" row |
| 03 | "杂项：格式、色彩、判断、运维、实测数据" | "技术细节：格式、编码器、色彩、判断方法、运维、性能、硬件" | "杂项：格式、色彩陷阱、判断方法、运维、实测性能" | "considerations beyond the plan" | **3 variants**; README omits 编码器 and 硬件, which are 2 of the doc's 9 sections |
| 04 | "M0–M2.1 的 Mac 侧计划/结果、recipe schema、M2.1 传输/API 契约" | "…、编码期决策、M2.1 传输/API 契约（端点、错误码、状态机、缓存）" | "M0–M2.1 里程碑、recipe schema、M2.1 API 契约" | "Mac-side plan (M0–M2.1)" | consistent enough |
| 05 | "M0 的实测记录与 iPad 验收结论（历史记录，不是规范）" | same | "M0 实测：容器事实、headroom、基图保真、iPad 验收结论" | "M0 encoder/iPad verification" | README **drops the "historical record, not a spec" caveat** — the one thing that decides how to read the doc |
| 06 | "M3 iPad EDR 判图端的架构、工作包、验收" | "M3 iPad 客户端的架构、工作包、验收与风险" | "EDR 判图架构、三个 gain 控件、工作包、验收" | "M3 iPad client" | fine |
| 07 | "M4/M5 全分辨率输出、验证报告、交付验收" | "M4/M5 全分辨率输出、验证报告、Photos/Safari 交付验收" | same as AGENT list | "M4/M5 output and acceptance" | fine |

Also: README:13 describes `contract/` as "recipe schema + mask/gain 数学" while AGENT:47/71 add "Rec.709 luma 与工作缓冲类型" — the README short form drops half the package's contents; low severity but it is the same description-drift pattern.

### D.3 Missing docs / wrong list entries

1. `tools/verify-heic/README.md` (tracked, 205 lines) — no list entry, no ownership row, referenced only *textually* by README:44 ("构建与用法见其 README") without a link. It contains normative check tables (its `basePreserved` photo thresholds `|meanSignedDiff| ≤ 0.5 / meanAbsDiff ≤ 2.5 / absDiffP99 ≤ 16`) that duplicate docs/05 §3.3 and are used by the M4 report — a fact with two homes and no owner. It is also stale: line 3 "(M0 now, M4/M5 later)" and "M4 will add ΔE2000" (~line 94).
2. `tools/m0-fixtures/README.md` (tracked, 22 lines) — no list entry/owner; duplicates the fixture facts of docs/05 §3.1 (uniform 0.499986 base, 0.021943→3.998057 ramp, `RGBAf` requirement).
3. `notes/Save to HEIC Using Core Image.md` (tracked, 282 lines) — linked from docs/03:3 as the source session and described at README:16 as "原始调研记录（不作为规范）". It is explicitly non-normative, which is a defensible reason not to own it — but the ownership table should say so, otherwise it is an invisible 282-line source.
4. `tools/visual-check/README.md` is owned (AGENT:69) and its *content* is right, but its links are broken (A.1).
5. No list entry points at the wrong content; the only "wrong content" issues are the description-drift rows in D.2 and README:12 (stale CLI list) / README:18 (missing tool).

### D.4 Section-numbering style

| doc | H2 numbering | H3 numbering | note |
|---|---|---|---|
| docs/01 | §0–§4 (5) | §0's H3s **unnumbered** ("The constraint", …); §1's are §1.1–§1.4 | mixes numbered and unnumbered H3 inside one doc; starts at 0 (unique in the set) |
| docs/02 | §1–§4 + **5 unnumbered H2** ("The loop", "What good looks like", "If something looks off", "Settings worth knowing", "What this guide deliberately does not cover" — docs/02:13, 101, 110, 125, 138) | 4 unnumbered H3 | a numbered doc with unnumbered siblings interleaved; refs to it would be ambiguous |
| docs/03 | §1–§9 (9) | §1.1 only | consistent |
| docs/04 | **none** — "Decisions", "Work packages", "Risks to watch", "Next" | M0/M1/M2 (H3), M2.1 (H4) | **only plan doc with no § numbering**; all refs to it use `M0`/`M1`/`M2.1` ids, never `§N` |
| docs/05 | §1–§7 (7) | §3.1–§3.3 | consistent |
| docs/06 | §1–§10 (10) | §4.1–§4.6 | consistent |
| docs/07 | §1–§10 (10) | §5.1–§5.6 | consistent |
| README / app / ipad / visual-check | none | none | code-style docs; fine |

Findings: docs/04 is the structural outlier — its `§`-less headings are the reason the whole set has a second reference notation (`docs/04 M1`) that no other doc uses. That is *self-consistent* (all `M1`/`M2.1` refs resolve — A.3) but it breaks the "everything is `§N`" expectation and is what makes "docs/04 §2.1"-style refs impossible. docs/06:198's "§1.7–§1.9" is the reverse error: it borrows the `§N.N` heading notation for list items, which is ambiguous because §4.5 etc. are real heading sections.

### D.5 Heading hierarchy

- No level jumps anywhere (checked programmatically over all 12 files): every `####` has a `###` parent (`docs/04:51` under `### M0`, `docs/04:110` under `### M2`), `###` always has an `##` parent.
- Exactly one real H1 per file. The apparent extra H1s in docs/05 (lines 144, 151, 154, 160) and app/README.md (lines 87, 98, 142) are `#`-comments **inside fenced code blocks**, not headings — correct in rendering, but they defeat naive heading scans (worth knowing if a doc tool is ever added).
- docs/02 is the only doc with numbered and unnumbered H2s at the same level (D.4).
- docs/01 §0's unnumbered H3s under a numbered H2 are not an error, but they are why refs into §0 have to say "docs/01 §0" without a sub-anchor (app/README:166 does this).

---

## E. Cross-doc numeric contradictions

Cross-checked every repeated quantity. Sources for "truth": `out/R0003777-P3.report.json` (installed delivery, generatedAt 2026-11-03T13:42:38+08:00), `work/m4/deliver-run1.log`, `work/m4/deliver-run2.log`, `work/m4/deliver-by-id.log`, `work/m4/probe/calibration.md`, `work/m4/probe/calibration.json`, plus the on-disk HEIC sizes.

| # | quantity | sites and values | verdict |
|---|---|---|---|
| E1 | **`previewAgreement` measured** | docs/07:200 (§5.4) "mean 1.16, p99 5.27, 1.24 % above 5"; docs/07:331 (§10) "mean 1.1902 / p95 3.37 / p99 5.42, 1.37 % > ΔE 5" | **NOT a genuine contradiction — but mislabelled.** §5.4's numbers are the M4.3 **calibration on the M0 deliverable with the M0 recipe**: `work/m4/probe/calibration.md` (frozen-thresholds table) and its §c table row "lossless pipeline analogue" = mean 1.1642 / p50 0.81 / p95 3.30 / p99 5.27 / 1.24 % > 5 — i.e. the *pre-delivery probe*, not the delivered check. §10's are the actual check on the M4 delivery with the M3-posted recipe (start 0.1971 / lift 2.0151 / transition 1.0). The defect is the phrase "**Measured on the trial data**" at docs/07:200, which a reader will pair with §10's "trial data". Fix: say "calibration on the M0 deliverable with the M0 recipe (calibration.md §c); the delivered run measures 1.1902 / 3.37 / 5.42 / 1.37 % (§10)". |
| E2 | **`fractionAboveOne`** | docs/04:89 and docs/05:68 = **10.94 %**; docs/07:310 = **25.64 %** | **Explained by a different recipe, but not said anywhere.** 10.94 % belongs to the M0/M1 default recipe (start 0.62 / lift 1.4 / transition 0.28 — docs/04:40, docs/06:18/86-88); 25.64 % belongs to the M3-posted recipe (start 0.1971 / lift 2.0151 / transition 1.0 — docs/07:227, 294). Same cause for docs/07:310's `fractionAtCap` 0.75 % vs 0.43 %/0.431 % (docs/05:68, docs/04:89, calibration). Both recipes are recorded, so this is not contradictory — but the two numbers sit in different docs with no cross-note; add one clause at docs/04:89 ("default recipe") and docs/07:310 ("posted recipe; the default recipe gives 10.94 % — docs/04 M1"). |
| E3 | **base preview PNG size** | docs/03:175, docs/03:179 "22.1 MB"; docs/04:105, docs/06:200 "22,112,102 B" | **OK** — 22,112,102 B = 22.11 MB decimal; the two forms agree. (It is 21.09 MiB, so any future MiB label would differ — don't switch units.) |
| E4 | **`preview.heic` size** | docs/04:90, docs/04:96, docs/03:178 = **881,253 B**; docs/05:36 = "**883 KB** for the 2560×1707 preview" | **OK, different milestones.** 883 KB is the M0 preview (`work/m0/verify/real-snapshot/R0003777-M0-2560.heic` = 882,761 B); 881,253 B is the post-P1-2 M1 preview (docs/04:90/96 and docs/03:178 explain the 882,091→881,253 change). Both are correctly attributed by the surrounding text; no action needed, though "883 KB" could say "M0 preview, 882,761 B" for clarity. |
| E5 | **M4 timings** | docs/07:333-335 `decode 0.29 + render 0.19 + preview 0.26 + encode 1.22 + verify 16.22 = **20.73 s** (from the report)`; docs/07:363 repeats the five values + 20.73 | **GENUINE DEFECT, two ways.** (a) The five parts sum to **18.18 s**, not 20.73 s — the 20.73 is the wall-clock total and ≈2.55 s (source hashing, staging, install) is unlisted. (b) The values are not "from the report": the installed `out/R0003777-P3.report.json` has decode 0.2867 / render 0.1967 / preview 0.3680 / encode 1.3611 / verify 15.8443 / total **20.683**, which matches `work/m4/deliver-by-id.log` ("0.29 + 0.20 + 0.37 + 1.36 + 15.84 = 20.68"). The published split (1.22 encode, 16.22 verify, 20.73 total) matches **run 1** (`work/m4/deliver-run1.log`) whose report is no longer the installed one. Fix: either quote the installed report's values, or label the numbers "run 1 log" and say the total is wall-clock and includes ~2.5 s of hashing/staging/install. |
| E6 | decoded HDR peak | docs/04:90 "decoded peak ≈ **2.93×**"; docs/05:72 "peak **2.92×**"; calibration.json / probe "2.9227" | **Rounding slip in docs/04:90** (2.9227 → 2.92, not 2.93). Trivial; fix only if the file is touched anyway. |
| E7 | `calculatedContentHeadroom` | docs/07:327 = 2.7451 (M4 delivery); calibration.md frozen-thresholds table = 2.6240 (M0 deliverable) | **OK** — different files, each labelled; both are cross-check diagnostics only (docs/07 §5.4 headroom row gates on `contentHeadroom`). |
| E8 | test counts | docs/04:87 82 (M1) → docs/04:106 229 (M2) → docs/06:23/195 229 (M3) → docs/07:307 255 (M4); app/README:54/65 255; ipad 80→85 (docs/06:196, ipad/README:44) | **OK chronologically** (82→229→255 is consistent with the stated +26 and +0 deltas). Only issue: docs/06:23 states 229 as a live acceptance rule — see C10. |
| E9 | peak RSS | docs/04:92 5.2 GB (M1 prep), docs/03:177 5.2 GB; docs/07:334 4.6 GB (M4 deliver); `work/m4/deliver-run1.time` max RSS 4,675,076,096 B = 4.68 GB | **OK** — different pipelines; docs/07:335 explicitly says the docs/03 §7 ~5 GB estimate still holds. |
| E10 | 2.5 cap ⇄ stops | 2.5 linear = 1.321928 stops asserted in docs/04:16/89, docs/05:68/119, docs/07:310/327, docs/03:72, docs/06:41 | **OK** — one value, consistently rounded (1.321928 or ≈1.32). Note docs/03:129's "2.8× is 1.49 stops" is a generic example, not the cap — no contradiction, but it sits in the same §4 as delivery advice; leave it. |
| E11 | `baseDeltaE` | docs/03:139 "mean 1.44, p95 4.12"; docs/07:197 "mean 1.44, p95 4.12"; docs/07:329 1.4406 / 4.1200; docs/07 §1 item 2 gate 2.5/6.0; report 1.4406/4.1200 | **OK** — consistent to 2 dp; the render-target vs container-gate distinction is stated in all three places (B.7). |
| E12 | preview `p99` vs report | docs/07:331 "p95 **3.37** / p99 **5.42**"; report p95 3.37 / p99 5.42 | **OK.** Note the *calibration* row has p95 3.30 (not quoted in docs), so only E1 needs the label. |

**Genuine contradictions to fix: E5 (timings), and E1's label ("measured on the trial data" → calibration on the M0 deliverable). E2 is a different-recipe pair that should be labelled but is not factually contradictory. E3/E4/E6/E7/E8/E9/E10/E11/E12 are explained or trivial rounding.**

---

## F. Prioritised fix list

**P0 (facts/links are wrong as written)**
1. `tools/visual-check/README.md:5,56,58,90,96,99` — `../docs/` → `../../docs/`.
2. `docs/03:151` — delete "Recipe-keyed full renders … remain M4" (shipped: docs/07 §10); keep only the FSEvents-watcher/stage-2 half.
3. `docs/07:333-335, 363` — fix the timings: quote the installed report's five values (or label "run 1 log"), and stop writing the parts as a sum equal to the wall-clock total.
4. `docs/07:200` — relabel the §5.4 `previewAgreement` measurement as the M0-recipe calibration (or replace with §10's delivered values).

**P1 (phase boundary / navigation)**
5. `docs/02:9` (and `:27`) — stage 1 is closed; include `photon deliver` in the stage-1 loop.
6. `docs/05:70`, `docs/05:97` — "will add"/"will promote" → done (docs/07 §5.4/§10, `tools/visual-check/`). Add a "historical M0 record (M1–M5 have since closed)" banner near docs/05:3, and adjust docs/05:5/:95/:134.
7. `README.md:12` — add `deliver` to the CLI list and the M4 modules; `README.md:18` — add `visual-check/`.
8. Wrong-section refs: docs/04:16 & docs/04:143 & docs/07:270 → `docs/05 §3.1`; docs/07:196 → `docs/05 §3.3`; app/README.md:75 → `AGENT.md` `## 环境`; app/README.md:166 → docs/03 §5 or docs/04 M1; docs/03:150 → docs/07 §5.3; docs/07:19/189 → narrow the "every check/thresholds in docs/03 §5" claim.

**P2 (single-home consolidation, in severity order)**
9. docs/05:60 → one sentence + "see docs/03 §3" (keep docs/05:53's table row as evidence).
10. docs/07:337-344 → keep the *deviation* (3 lines) and link docs/03 §5 + calibration.md; drop the rule re-explanation and the repeated 1.4406/4.1200.
11. app/README.md:163-165 → one line + pointer to AGENT:23 / docs/03 §3 / docs/04 M1.
12. docs/04:16 → drop the measured `AlternateHeadroom`/`contentHeadroom` numbers, keep "cap enforced on HDR pixels; `-R` does nothing (docs/03 §3, docs/05 §3.1)".
13. docs/03:123 ↔ docs/04:15 → docs/03 keeps the *why* + P1-4; docs/04 keeps the decision + error mapping.
14. docs/03:113 ↔ docs/04:93 → docs/04:93 may keep the story but drop the duplicated symptom numbers.

**P3 (doc-set bookkeeping / style)**
15. Normalise the 7 header labels (Design/Plan/none → one scheme); decide whether "Stage 1 —" stays on 04/06/07 now that the stage is closed; align docs/04's title/Status/Next per C.2.
16. AGENT ownership table: add `tools/verify-heic/README.md`, `tools/m0-fixtures/README.md`, `notes/…` (with "non-normative source" for notes), or state why they are unowned; fix the stale lines in `tools/verify-heic/README.md` (~line 3, ~line 94).
17. Unify description strings: AGENT:8 vs AGENT:62 (docs/02 stage-2 target); AGENT:9 / AGENT:63 / README:28 (docs/03 contents); README:30 (docs/05 "historical, not a spec" caveat); README:13 (contract contents).
18. docs/02: numbered §1–§4 plus 5 unnumbered H2 — pick one style; docs/01 §0 unnumbered H3s — number them or drop §0; docs/06:198 "§1.7–§1.9" → "§1 items 7–9".
19. README: link `app/README.md`, `ipad/README.md`, `tools/visual-check/README.md`, `tools/verify-heic/README.md` from the doc table (or say the doc table is `docs/` only).
20. docs/04:4 ("only turns them into work packages") → self-description now also includes the schema and the M2.1 contract; docs/06:143/§9 mark M4 as completed.
