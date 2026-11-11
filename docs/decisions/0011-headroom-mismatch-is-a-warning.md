---
type: decision
owner: docs
updated: 2026-11-07
---

# ADR-0011：advertised headroom 不匹配暂时记为 warning

- 状态：已被 [ADR-0012](0012-core-image-encoder.md) 取代（2026-11-09）：新 writer 准确写 `AlternateHeadroom`，5% 匹配恢复为 gate。
- 原状态：已接受（2026-11-07，**临时**；engine/gain-map 修好后按「重审条件」处理）
- 关联：[encoder.md](../reference/encoder.md)、[deliver.md](../reference/deliver.md)、
  [verification.md](../reference/verification.md)、
  [p3-known-issue-preview-agreement.md](../plans/p3-known-issue-preview-agreement.md)
- 影响阶段：交付门禁（`EncodedHEICValidator`、`DeliveryVerifier`）；不改变 recipe/wire

## 背景

读回门禁原本要求编码后的 `contentHeadroom`（或 `calculatedContentHeadroom`）与
`min(recipe cap, authored peak)` 相差不超过 5%，否则 `EncodedHEICValidator` 直接
`encoderOutputInvalid`，连 report 都不会写。

2026-11-07 用 iPad 实际 post 的 `FPL05190-P3` recipe（8423×5599，start 0.4123 /
lift 1.4904 / transition 0.5005 / cap 2.0）交付：

| 项 | 值 |
|---|---|
| authored peak | 2.0000（cap engaged） |
| `contentHeadroom` | **1.3232**（−33.84 %） |
| `calculatedContentHeadroom` | 1.7480 |
| HDR decode 峰值 | 1.7089 |
| 肉眼观感 | 用户确认「看不出问题」 |
| 结果 | 被 encoded-headroom 门禁拒绝，8 项 report 未运行 |

同一批的 `R0003777-P3`（cap 8，authored 2.2127）读回 2.2109，8/8 PASS。差异不在 cap
大小，而在 FPL05190 的高光面积很小：gain map 的 headroom 由（会被下采样/量化的）增益图
决定，微小高光会被少报。这是 encoder/gain-map 的能力问题，不是渲染或配方错误。

## 决策

1. **结构性读回仍是硬门禁**：`EncodedHEICValidator.validate` 只 gate ISO aux 存在、
   SDR 无 alpha、尺寸、HDR decode；advertised headroom 的 5% 匹配不再让它抛错。
   plain-SDR 退化仍会被 ISO-aux 检查拒绝（review P0-1 的原意没有丢）。
2. **report 里记为 warning**：`DeliveryVerifier` 的 `headroom` check 仍把
   authored peak 越界、缺 gain map 判 FAIL；5% 不匹配改为
   `pass: true` + `detail` 以 `WARNING (not gated)` 开头，`measured` 增加
   `warning: true` / `withinTolerance: false`。8 项检查仍然全 PASS，交付安装。
3. **`verify-heic` 保持严格**：它是独立的 ImageIO 交叉验证，不是门禁；
   FPL05190 这类文件在它那里仍会报 `headroomWithin5pct=FAIL`，这是预期的证据，
   不是门禁回退。
4. **不改 recipe/wire/parity**；cap 范围仍是 1…8，默认 2 st（2026-11-10 修订：
   原文误写「1.5 st」，现行默认见 recipe.md）。4-stop/16 的能力问题
   仍按 encoder 工作单独处理。

## 后果

- FPL05190 现在 8/8 安装，report 的 `headroom` 行留下完整数字和 warning。
- 不再有「advertised headroom 必须匹配」的硬拒绝；直到 engine 修好前，交付可能带着
  比 authored peak 低的 advertised headroom 安装。
- 结构性错误、no gain map、clamp 错误仍然拒绝；不会把 plain SDR 当 HDR 交付。
- 证据（gitignored）：`out/v1-check/FPL05190-P3.report.json`、
  `out/v1-check/R0003777-P3.report.json`、`work/v1-check/` 的 staging/rejected 副本。

## 重审条件

engine/gain-map 能稳定保住小高光的 headroom（包括 4-stop/16 的工作）后，重跑
FPL05190 与 R0003777；若 advertised 与 authored 稳定在 5% 内，把 `headroom` 的 5% 匹配
改回 gate（或至少在 report 里升为 FAIL），并同步
[deliver.md](../reference/deliver.md)、[verification.md](../reference/verification.md)、
[encoder.md](../reference/encoder.md)。在那之前不要删掉 warning 文案。
