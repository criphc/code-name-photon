---
type: decision
owner: docs
updated: 2026-11-06
---

# ADR-0007：迁移期的文档与归档策略

- 状态：已接受（2026-11-05，P0；2026-11-06 修订 §5）
- 关联：[迁移目标结构](../plans/00-new-structure-description.md) R10；用户 2026-11-05、2026-11-06 的选择
- 影响阶段：P0、P5

## 背景

stage 1 的文档既有活文档（01/02/08/09），也有已冻结的归档（`docs/archive/stage-1/`）。
迁移会移动路径、改名模块、拆分 README；如果不先定规则，旧路径引用会到处漂移，归档也会被
顺手「修好」。

## 决策

1. **旧路径不留 redirect stub**。`docs/01-...`、`app/README.md`、`ipad/README.md` 等旧路径
   在迁移后不再存在；`docs/archive/` 里的旧链接允许断链。`docs-check` 只扫**活文档与代码注释**
   中的旧路径，不扫归档。
2. **归档冻结**。`docs/archive/stage-1/` 的内容不改；stage-1 的调研记录
   `notes/Save to HEIC Using Core Image.md` 归入 `docs/archive/stage-1/notes/`，同样按历史冻结。
3. **语言**：迁移来的旧文档保持英文原样（减少与搬家无关的 diff）；新写的根/子 `AGENT.md`、
   ADR、`docs/ui/` 规格用中文；根 `README.md` 重写为中文。
4. **一项内容只在一处写详细**。根 `AGENT.md` 维护文档归属表；其他文档写一句 + 链接。
5. **阶段文档与迁移计划分家**（2026-11-06 修订）。迁移计划放
   `docs/plans/00-new-structure-description.md`。`stage-2-handoff.md`、
   `design-01-app-concept-and-three-stages.md`、`design-02-hdr-highlight-finisher-workflow.md`
   留在 `docs/archive/stage-1/`，不再迁入 `docs/plans/`——原「阶段交接（原 `09`）也归
   `docs/plans/`」的表述作废，它们属于已弃用的 stage-1/2/3 叙事，只作历史记录。同时 v1 起不再用
   阶段叙事：stage-1/2/3 与 P0–P6 不是路线图，当前阶段计划只看
   [`docs/ui/plan/v1-plan.md`](../ui/plan/v1-plan.md)（v1 = design + UI 规格、iPad UI 重做；macOS GUI
   推迟）。（2026-11-10 修订：v2 起阶段计划见
   [`docs/plans/v2-plan.md`](../plans/v2-plan.md)；v1/v2 均已收尾，下一阶段未定。）

## 后果

- 文档重组与代码搬家可以分开提交；`docs-check` 的目标明确。
- 归档中的旧路径断链是预期行为，不是缺陷。
- 新规则必须进 `docs/decisions/`，不再往归档里补写。

## 备选与取舍

- **给旧路径留 redirect stub**：多一层永久维护的跳转，且归档仍会引用旧路径；拒绝。
- **把旧文档翻译成中文**：迁移期制造大量非搬家 diff，风险大于收益；拒绝（以后可单独做）。
- **把 notes 留在根目录**：新目标结构里没有 `notes/`，会成为一个无归属的例外；拒绝。

## 验证

P5 的 `make docs-check` 对活文档/代码注释报 0 条旧路径；归档为零改动。
