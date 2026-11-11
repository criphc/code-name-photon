---
type: status
owner: docs
updated: 2026-11-10
---

# 状态

> 唯一的易变状态。最后更新 2026-11-10。

## 现在做到哪

- **迁移已结束**：包结构、wire 契约、交付门禁、parity 均已收口，`main` 上的 `make check` 绿。
- **v1 已收尾（2026-11-08）**：iPad UI 重做完成；规格固化在 [ui/spec/](ui/spec/00-index.md)，视觉值在 `design/Sources/Tokens`，token 与经验的归属见 [ui/AGENTS.md](ui/AGENTS.md)。
- **v2 已收尾（2026-11-09）**：server 与 engine——进程内 Core Image 编码器（ADR-0012）、profile 交付管线与 report schema 1、门禁重标定、`appctl deliver --batch`、缩略图端点 + 启动预热（ADR-0013）、verify 性能优化。计划、决策与实测全部见 [plans/v2-plan.md](plans/v2-plan.md)，本文不重复。
- **FPL05190 / R0003777 已用新 writer 重跑（2026-11-10）**：均 `10/half/rgb` 8/8 PASS，headroom gate 精确匹配（ADR-0011 的验收证据补齐）。
- **macOS GUI 推迟**：进程契约（`ServerControl` + ADR-0010）与 GUI 模板保留，app 不建。
- P0–P6 与 stage-1/2/3 的叙事停用；历史只作记录（[plans/](plans/)、[archive/](archive/)）。

## 下一步

- 下一阶段未定，开工时另写计划。v2 的剩余风险见 [plans/v2-plan.md](plans/v2-plan.md) 的「风险」。
- **UI 侧明确不做的**：snapshot 基线、UI 测试、`design/Sources/Components` —— identifier 已铺好，等真有需求再建。

## 与下一步相关的缺口

- **half-res `previewAgreement` 的 mean 未按 map 分辨率标定（2026-11-10 发现）**：R0003777 的 ADR-0011 极端 recipe（start 0 / transition 1 / cap 8）在 `10/half/rgb` 下 mean 2.71 > 2.5 FAIL——fractionAbove5 9.6% 在干净带内，full map 下同一 recipe PASS；合法 recipe 可触门禁，下次标定 half-res 阈值时处理。
- 4-stop/16 不在 v2，cap 仍停在 8（3 st）。
- 客户端侧遗留（v2 未覆盖、未排期）：base 纹理上传在主线程、`JudgeModel.reviews` 会话级无上限缓存。
- `apps/ios` 仍然没有测试 target：可测逻辑都放进了 `client` 包，app 里只剩布局；真要 UI 测试时才需要建。
- `make ui-check` 仍是占位：snapshot 与 UI 测试明确推迟，identifier 已铺好等将来。
- 工具栏溢出菜单里有一个 DEBUG-only 的「Clear Thumbnail Cache」临时项（验收后删掉）。
- 错误与提交结果都用 alert（已定，不进状态条）；提交成功的正文带 item 名和 renderKey 前 8 位。
- macOS GUI 的整体推迟项见 [ui/plan/v1-plan.md](ui/plan/v1-plan.md#非目标--已知遗留)。

## 门禁

- `make check` = test + integration + parity + docs-lint（DSH 内可跑）。
- `make check-apps` = `ios-build`（普通终端/CI；macOS 构建推迟）。
- 交付门禁：8 项在**每个 profile** 上须 PASS；`headroom` 的 5% advertised 匹配是 gate（ADR-0012）；`baseDeltaE` 按 profile（8-bit 2.5/6.0，10-bit 2.0/5.0）；half-res `previewAgreement` 10% PASS / 20% warning（mean 2.5 未按分辨率标定，见缺口）。
- **UI 验收 = `#Preview` + 用户实机确认**：改动留 `#Preview` 并指出文件/行号；agent 不启动模拟器、不截图，可用 headless preview 自检。
- `make parity` 0 failure / 0 skip；缺夹具或资源必须 fail，不 skip。
