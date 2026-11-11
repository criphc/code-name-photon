---
type: record
owner: docs
updated: 2026-11-09
---

# verify 性能调查

*2026-11-09 启动；84 s 的 verify 是 batch 的吞吐瓶颈。*

## 已知

- 一次 6000×4000 delivery 的 verify ≈ 84–86 s，总 deliver ≈ 94 s；decode/render/preview/encode 合计 ≈ 5 s。
- 主要嫌疑：`baseDeltaE` / `fallback` / `previewAgreement` 的全分辨率 ΔE2000 循环，以及 `DeliveryImageProbe` 的 strip render。
- 现有测量：[performance.md](../reference/performance.md)。

## 结果

### 测量方法

- benchmark：`server/Tests/EngineKitTests/VerifyPerformanceBenchmarkTests.swift`，opt-in（`PHOTON_VERIFY_BENCH=1`；加 `PHOTON_VERIFY_BENCH_EXPERIMENTS=1` 跑优化原型）。默认 `make server-test` 只编译并 skip。
- 输入：rejected `5314fd618b56` 的 `R0003777-P3-hdr.heic` + recipe + `fixtures/media/sources/R0003777-P3.tif`；用 `SourceDecoder`/`ToneMapper`/`HDRRendition`/`PreviewRenderer` 重建 `DeliveryVerificationInput`（与 `DeliveryPipeline.deliver` 同序）。
- 每项检查用 verifier 相同的 public probe 调用逐段计时（check body 是 private）；总数直接量 `DeliveryVerifier.verify`。各段之和 84.39 s vs 总数 84.94 s（差 0.65 %），所以拆分可信。
- 环境：M1 Max / macOS 27.2 / 6000×4000。**94 s 的 delivery 是 debug build**（`make appctl` 构建的就是 debug），所以主表用 debug；release 作为对照。
- 命令：

```bash
cd server && PHOTON_VERIFY_BENCH=1 PHOTON_VERIFY_BENCH_EXPERIMENTS=1 \
  TMPDIR=$PWD/../.tmp-verify CLANG_MODULE_CACHE_PATH=$PWD/../.mc-verify \
  swift test --disable-sandbox --scratch-path ../.build-verify --filter VerifyPerformanceBenchmark
```

### 每项检查（debug，verify = 84.94 s）

| 阶段 | 秒 | % verify |
|---|---:|---:|
| decode（共享） | 0.92 | 1.1 |
| container / identity / alpha / headroom | 0.00 | 0.0 |
| clipping | 3.26 | 3.8 |
| baseDeltaE | 41.59 | 49.0 |
| — ΔE pass | 20.51 | 24.1 |
| — — render only（float） | 0.04 | 0.05 |
| — — ΔE2000 loop | 20.47 | 24.1 |
| — LSB pass | 21.09 | 24.8 |
| fallback | 34.69 | 40.9 |
| — map-stripped copy write | 0.12 | 0.1 |
| — inspect（decode #1） | 0.08 | 0.1 |
| — copy decode（#2） | 0.00 | 0.0 |
| — LSB pair | 14.39 | 16.9 |
| — ΔE pair | 20.11 | 23.7 |
| — sha256 | 0.00 | 0.0 |
| previewAgreement | 3.92 | 4.6 |
| — preview render | 0.23 | 0.3 |
| — ΔE at preview scale | 3.68 | 4.3 |

### 热点

1. **scalar 逐像素循环 ≈ 96 %**：ΔE2000 44.3 s（52 %）+ LSB 35.5 s（42 %）+ clipping 的 `linearStats` 3.3 s（3.9 %）。
2. **Core Image render 合计 0.27 s（0.3 %）**：strip render 不是瓶颈（`baseDeltaE` 的 render-only 0.043 s）。2026-11-09 的 `CIRender` 共享 context 修复没有引入额外成本。
3. **ImageIO decode 合计 1.0 s（1.2 %）**：SDR+HDR decode 0.92 s；fallback 的两次额外 decode 0.076 s。
4. **fallback 的 re-encode/decode 不是热点**：copy write 0.12 s + inspect 0.075 s + decode 0.001 s = 0.2 s（0.2 %）；它的 34.7 s 全在两次全分辨率比较（LSB 14.4 + ΔE 20.1）。
5. `baseDeltaE` 的 LSB pass（21.1 s）比 fallback 的 LSB pair（14.4 s）慢：前者每个样本调用 `SDRQuantiser.encoded16`（一次 libm `pow`），72 M 次。
6. 副产物：benchmark 现在复现 `previewAgreement` ΔE mean **1.1689**（rejected report 是 40.1085），与 [preview-agreement-investigation](preview-agreement-investigation.md) 的结论一致——2026-11-05 的失败是 `CIRender` 之前的冷 context 竞态，不是 recipe/encoder。

### 实验：strip 级并行 + fast scalar 数学

ΔE pass 是 24 Mpx 的同一 reference/candidate；所有变体的 mean/p95 **完全一致**（`1.440605 / 4.1200`，n=24 000 000），LSB 的 mean/p99 也一致（`1.475296 / 7`，n=72 000 000）。

| 变体（debug） | ΔE pass 秒 | vs serial |
|---|---:|---:|
| serial，production math | 20.51 | 1.00× |
| serial，fast math | 9.81 | 2.09× |
| parallel strips，production math | 53.26 / 53.42（两次；上一轮 37.9 / 37.4） | **0.39×** |
| parallel strips，fast lab only | 1.86 | 11.03× |
| parallel strips + fast math | 1.49 | 13.76× |
| LSB serial | 21.09 | 1.00× |
| LSB parallel | 3.03 | 6.95× |

**关键发现：用现在的 `Colorimetry.lab` 直接并行会比串行更慢。** `p3ToXYZ` 是 `[[Double]]` 静态数组，debug 下每次 `lab()` 的内层数组 subscript 都带 ARC retain/release；10 个线程同时打同一组 refcount，cache line 争用把并行收益吃光（两次都是 0.39×，不是预热问题）。把矩阵换成 9 个 `Double` 常量后，同一个 parallel 循环（production `deltaE2000` 不变）是 1.86 s（11×）。所以 debug 下「并行」和「矩阵标量化」必须一起做。

fast math 原型（`pow(25,7)` 提常量、`x^7` 改乘法、`pow(x,2)` 改 `x*x`）与 `Colorimetry` 的最大差 **4.97e-14**（`testFastDeltaEMatchesProductionMath`，200k 随机对，0 个 non-finite 不一致），PASS 规则不受影响。

**投影（debug）**：ΔE 44.3 → 3.3 s、LSB 35.5 → 6.1 s，verify **84.9 → 14.5 s（5.9×）**。clipping 还没并行，再并行可到 ≈12.4 s。

### release 对照

`swift test -c release` 同一 benchmark：verify **16.27 s**（debug 的 5.2×）。

| 阶段 | 秒 | % verify |
|---|---:|---:|
| decode（共享） | 0.93 | 5.7 |
| clipping | 0.17 | 1.1 |
| baseDeltaE | 8.22 | 50.5 |
| — ΔE pass | 5.22 | 32.1 |
| — LSB pass | 3.00 | 18.4 |
| fallback | 5.44 | 33.4 |
| — LSB pair | 0.28 | 1.7 |
| — ΔE pair | 4.96 | 30.5 |
| previewAgreement | 0.93 | 5.7 |

release 下 ΔE2000 仍占 ≈68 %（11.1 s），LSB ≈20 %（3.2 s），decode 5.7 %，render 0.4 %。

release 的实验：

| 变体（release） | ΔE pass 秒 | vs serial |
|---|---:|---:|
| serial，production math | 5.24 | 1.00× |
| serial，fast math | 4.10 | 1.28× |
| parallel strips，production math | 0.72 / 0.70 | 7.25–7.54× |
| parallel strips + fast math | 0.55 | 9.49× |
| LSB serial | 2.97 | 1.00× |
| LSB parallel | 0.35 | 8.43× |

release 下 optimizer 把 `[[Double]]` 的 retain/release 消掉了，所以 **parallel 单独就有 7.3×**，矩阵标量化只再多 1.3×。**投影（release）：verify 16.3 → 3.9 s。**

## 建议

| # | 优化 | 预期收益 | 风险 | 说明 |
|---|---|---|---|---|
| 1 | strip 级并行（`DispatchQueue.concurrentPerform`，per-strip 累加器合并）+ `Colorimetry.lab` 矩阵标量化 | debug 84.9 → ≈14.5 s（5.9×）；release 16.3 → ≈3.9 s（4.2×） | 低 | 已实测：debug ΔE 13.8× / LSB 7.0×，release ΔE 9.5× / LSB 8.4×；mean/p95/p99 与串行完全一致。矩阵标量化是 debug 并行的前提（否则 0.39×）。 |
| 2 | `make appctl` 改 release（或给 `appctl deliver` 一个 release 构建） | debug 84.9 → release 16.3 s（5.2×） | 低（构建/运维） | 不改 verifier 代码；94 s 的 delivery 本来就是 debug build。release 下并行仍有效，但收益从 13.8× 降到 9.5×。 |
| 3 | clipping 的 `linearStats` 并行 | debug 3.26 → ≈0.4 s | 低 | 同一个 strip 并行模式；peak/fraction 可精确合并。 |
| 4 | LSB 的 `quantised8` 去掉每样本 `pow`（LUT / 多项式） | base LSB 比 fallback LSB pair 多出的 ≈2.7 s 主要在 72 M 次 `pow` | 中 | 改报告数值（LSB 是 cross-check，不 gate）；并行后只剩 ≈0.3 s，优先级低。 |
| 5 | 复用 fallback 的三次 decode、合并 `baseDeltaE` 的两次 render | < 0.5 s | 低 | 已证明不是热点（0.2 % / 0.3 %），不值得做。 |
| — | 降分辨率跑 `baseDeltaE` / `fallback` / `clipping` | — | 高 | 会改 PASS 规则（全分辨率分布），不做；`previewAgreement` 已经是 preview 尺度。 |

**不建议**：vImage/Accelerate 的 Lab/ΔE 向量化。ΔE2000 的主体是 `atan2`/`sin`/`cos`/`exp`/`sqrt`，没有精确的向量等价物；标量 fast math + 并行已经拿到 13.8×，SIMD 的边际收益小、验证成本高（要重跑 34 对 Sharma 表）。如果还要再快，先做 1–3。

**语义边界（8 项检查不变）**：并行只改「谁算」，不改「算什么」——per-strip 直方图合并后 mean 是精确和、percentile 是同一组 bin 的最近秩，实测与串行逐位一致；fast math 与 `Colorimetry` 的最大差 4.97e-14，远低于所有阈值。

### 应用（2026-11-09）

- #1 已应用：`DeliveryImageProbe` 的 ΔE/LSB/clipping strip 循环改为 `DispatchQueue.concurrentPerform`，per-strip 累加器合并；`Colorimetry.lab` 的 `[[Double]]` 改成 9 个 `Double` 常量。
- #2 已应用：`make appctl` 改 release（`Makefile` 的 `APPCTL` 指向 `.build/server/release/appctl`）。
- #3 已应用：`clipping` 的 `linearStats` 并行。
- 实测：debug delivery 20.48 s / verify 11.14 s；release delivery 8.10–8.38 s / verify 3.96–3.97 s；8/8 PASS，ΔE/LSB 数值与串行一致（1.4406 / 4.1200；1.475296 / 7）。
- 未做：#4（LSB 的 `pow` LUT，优先级低）；#5（fallback decode 复用 <0.5 s）；vImage（不建议）。
