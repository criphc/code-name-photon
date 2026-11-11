---
type: record
owner: docs
updated: 2026-11-09
---

# 已知问题：`previewAgreement` 在 authored peak < cap 时严重失败

- 状态：**已修复（2026-11-09）**：根因是 GPU `CIContext` 的 render 偶发不写 buffer，不是 encoder 归一化；`CIRender` 修复后压力测试 20/20、同一 recipe 8/8 PASS。证据与修复见 [preview-agreement-investigation.md](preview-agreement-investigation.md)。
- 日期：2026-11-05
- 现场：`migration/p3`，iPad 原型 post 的 `R0003777-P3` recipe 交付
- 证据（gitignored）：
  `work/p3-accept/bd486ca6e0a26734feba094190aec098d77c9a0e23a66c0cc641086f03916116/rejected/5314fd618b56/`

## 症状

iPad 上 post 的 recipe（`hdr.start = 0.288725`, `lift_stops = 1.4`,
`transition = 0.996266`, `headroom_cap = 2.5`）经 `appctl deliver`：

- 8 项检查里 **7 项 PASS**（container/identity/alpha/headroom/clipping/baseDeltaE/fallback）；
- **`previewAgreement` FAIL**：preview（同一 recipe、2560 px）vs 交付 HEIC 的 HDR decode，
  **ΔE2000 mean 40.1085、p99 39.99、83.48% 像素 > 5**（门限 mean < 2.5、p99 < 10、
  fractionAbove5 ≤ 5%）；
- 交付被门禁拒绝，什么都没安装（符合 report gate 规则）。

关键测量：

| 项 | 值 |
|---|---|
| authored peak | 2.1762693（cap 2.5） |
| `capEngaged` | **false** |
| contentHeadroom | 2.175782（expected 2.176269） |
| decoded peak | 2.483807 |
| fractionAboveOne | 19.72 % |
| preview mean ΔE | 40.11 |

## 对照（同一张 `R0003777-P3.tif`）

| recipe | 结果 |
|---|---|
| stage-1 归档已验收 recipe（start 0.1971 / lift 2.015 / transition 1.0 / cap 2.5） | **8/8 PASS**，preview mean 1.1902；authored peak 2.5（cap engaged） |
| 同一 posted recipe，仅把 `lift_stops` 改成 2.0 | **8/8 PASS**，preview mean 1.1756；authored peak 2.5（cap engaged） |

2026-11-09 复核：这个「cap 未触发」相关性不成立——失败是 GPU render 偶发不写 buffer，与 authored peak 是否到 cap 无关（见 [preview-agreement-investigation.md](preview-agreement-investigation.md)）。

## 复现

```bash
# 用 iPad post 的 recipe（路径见上）
.build/server/debug/appctl deliver \
  --source fixtures/media/sources/R0003777-P3.tif \
  --recipe work/p3-accept/<sha>/recipe.json \
  --out out/p3-issue --work work/p3-issue \
  --encoder tools/toGainMapHDR/bin/toGainMapHDR
# -> previewAgreement FAIL，exit 1，rejected/ 留下 HDR/SDR HEIC + report
```

## 复核结论（2026-11-09）

不是 encoder 归一化，也不是「authored peak < cap」的 edge case：在 `main` 上同一 recipe 的预览比较
20 次里 2–8 次失败（mean 7.75–51.1，正确值 1.1689），HEIC sha 不变；失败阶段是 GPU `CIContext` 的
render 偶发不写 destination buffer。复现、分阶段证据和修复建议见
[preview-agreement-investigation.md](preview-agreement-investigation.md)。

## 下一步（独立处理）

1. ~~最小复现~~ 已完成：`server/Tests/EngineKitTests/PreviewAgreementStressTests.swift`（现在是回归测试）。
2. ~~修 `PreviewRenderer.render`~~ 已完成：`CIRender`（`CIRenderDestination` + `waitUntilCompleted`，共享 `CIContext`）。
3. ~~压力测试转绿~~ 20/20；同一 recipe 8/8 PASS。
4. 交付门禁不再拒绝这类 recipe。

## 与 P3 验收的关系

用户决定：先不修；用**这条失败 recipe 的 rejected HEIC**（只用于视觉对照，不是合格交付）和
**一条 8/8 PASS 的 recipe** 两张图继续 iPad 的 Photos/Safari 验收。

P3 验收结果（2026-11-05）：iPad 上两张图的 Photos/Safari HDR 与 SDR 观感都正常；
`R0003777-P3-issue-hdr.heic` 没有肉眼可见异常（SDR 也像 Capture One）。因此 `previewAgreement`
的 40 ΔE 失败**不是肉眼可见的画质错误**，更像内部比较的 render 非确定性（2026-11-09 复核确认，
见 [preview-agreement-investigation.md](preview-agreement-investigation.md)）。交付门禁仍按规则
拒绝该文件；修好后需补交付回归。

P3 的结构迁移和 app placeholder/prototype 验收不等于这条 engine edge case 已解决；2026-11-09 修复后同一 recipe 8/8 PASS。
