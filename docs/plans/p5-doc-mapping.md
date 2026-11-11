---
type: record
owner: docs
updated: 2026-11-06
---

# P5 文档映射表

*G1 审阅物。行号基于分支起点 `47644db`。删除/搬迁前用本表逐段核对；核对不上的段落**不删**，进问题清单。*

动作含义：

- **搬入**：整段字节不改搬走，只修路径/链接/过期模块名。
- **拆入**：一段内容按主题拆进 `reference/` 的不同文件（仅 `docs/08` 一节拆一个文件）。
- **收敛**：压成卡片里的一行或几行；细节必须在 `reference/` 有唯一出处。
- **补元数据**：只加 front-matter，内容一字不动。
- **移动**：`git mv` 后只改链接与 front-matter。
- **删除**：源文件删掉；本表已给出每一段的归宿。
- **dropped**：直接删除、不给归宿；只用于用户明确决定删除的内容。

## 1. 根文件

### `README.md`（51 行）→ 保留并改链接

| 源 | 类型 | 归宿 | 动作/备注 |
|---|---|---|---|
| `README.md:1-7` | 简介 + 状态 | `README.md`（简介三行）+ `docs/status.md`（stage 状态） | 状态段搬 status；README 只留一句并链接 |
| `README.md:9-20` | 布局 | `README.md`「目录」 | 按新结构改路径；不再复制 `docs/` 细节 |
| `README.md:22-32` | 导航表 | `docs/README.md`（生成） | 删表，改由生成 |
| `README.md:34-38` | 环境 | `AGENTS.md`「环境」 | 收敛 |
| `README.md:40-44` | 编码器红线 | `reference/encoder.md` + `AGENTS.md` 红线一句 | 细节搬入，根留一句 |
| `README.md:46-51` | 本地事实 | `reference/operations.md`（gitignore/本地目录）+ `AGENTS.md`「工作规则」 | 收敛 |

### `AGENT.md`（84 行）→ 内容并入新 `AGENTS.md`，旧文件归档

| 源 | 类型 | 归宿 | 动作/备注 |
|---|---|---|---|
| `AGENT.md:1-3` | 入口说明 | `AGENTS.md` 首段 | 保留“本文件只写规则与环境；简介看 README” |
| `AGENT.md:5-8` | 阶段状态 | `docs/status.md` | 搬入并更新到 P5 现状 |
| `AGENT.md:10-17` | 文档清单 | `AGENTS.md`「文档路由」+ `docs/README.md` | 收敛为按任务的路由表 |
| `AGENT.md:19-30` | 不可违反的约定（10 条） | 根 `AGENTS.md`「全局红线」只留「交付目标 Apple 设备 + SDR 回退」1 条；「遇到不确定」进根「工作规则」；其余 8 条去重后进 `server/AGENTS.md`「不许破坏」（短规则）+ 对应 `reference/`（细节） | 去重后下沉（用户 2026-11-05 决定） |
| `AGENT.md:32-43` | 协作 / Git / 团队 | `AGENTS.md`「工作规则」 | 原文保留 |
| `AGENT.md:45-59` | 环境（机器、编码器、验证器、iPad、沙箱、归档） | 根 `AGENTS.md`「环境」只留开发机/判图硬件 + 归档策略；其余去重后下沉：编码器 clone/集成测试 → `server/AGENTS.md`「环境」；验证器 → `tools/AGENTS.md`；共享契约 → `contract/AGENTS.md`；iPad 端/parity 夹具 → `apps/ios/AGENTS.md`、`client/AGENTS.md`；Mac 管线/沙箱 → `server/AGENTS.md`；m0-fixtures/visual-check → `tools/AGENTS.md`；Core Image buffer → `reference/encoder.md`；ImageIO 真相 → `reference/verification.md`；fixtures/media → `server/AGENTS.md`「环境」（中文环境事实进中文卡片，不混入英文 reference） | 去重后下沉（用户 2026-11-05 决定） |
| `AGENT.md:61-76` | 文档归属表（按主题） | `AGENTS.md`「文档路由（按任务查）」 | **重写**为按任务；旧表作废 |
| `AGENT.md:78-84` | 工作规则 | `AGENTS.md`「工作规则」 | 原文保留；文档规则从迁移期 `AGENTS.md` 合并 |

### `AGENTS.md`（29 行，迁移期）→ 归档

| 源 | 类型 | 归宿 | 动作/备注 |
|---|---|---|---|
| `AGENTS.md:1-3` | 迁移期说明 | `docs/archive/migration/AGENTS-migration.md` | 归档 |
| `AGENTS.md:5-11` | 文档表 | 归档；有效部分并入新 `AGENTS.md` 路由 | 归档 |
| `AGENTS.md:13-18` | 工作规则（含“文档只增不减”） | 新 `AGENTS.md`「工作规则」 | 保留有效条目，与新规则去重后合并 |
| `AGENTS.md:20-29` | 协作 / 团队 | 新 `AGENTS.md`「工作规则」 | 原文保留 |

## 2. 待删除的 6 个子项目 README

### `server/README.md`（348 行）→ `server/AGENTS.md` + 3 篇 reference（其余红线并入其它 reference）

| 源 | 类型 | 归宿 | 动作/备注 |
|---|---|---|---|
| `server/README.md:1-6` | 简介 | `server/AGENTS.md` 一句话；P4 待做 → `docs/status.md` | 收敛 |
| `server/README.md:8-13` | Contract map | `server/AGENTS.md`「去哪看」 | 收敛为链接 |
| `server/README.md:15-72` | 布局（逐文件说明 + 共享契约段） | `server/AGENTS.md`「布局」 | 布局代码块（17-62）原样搬入；64-72 的共享契约段删除（与 contract 卡片重复且含 P1 旧事实），其中仍有效的依赖链接事实补进 `contract/AGENTS.md`（2026-11-05 去重）；G9 收敛为包/模块地图（决策 #21） |
| `server/README.md:74-101` | 构建/测试命令 | `server/AGENTS.md`「命令」；DSH 沙箱/并行变量 → `AGENTS.md`「环境」 | 收敛 |
| `server/README.md:103-119` | CLI 用法 | `reference/cli.md` | 搬入 |
| `server/README.md:121-182` | M4 交付契约 | `reference/deliver.md` | 搬入 |
| `server/README.md:184-211` | Report schema 0 + 8 项检查 | `reference/deliver.md` | 搬入 |
| `server/README.md:213-245` | M2 服务（进程契约、鉴权、超时） | `reference/wire.md` | 搬入 |
| `server/README.md:247-315` | M2.1 wire 契约 | `reference/wire.md` | 搬入 |
| `server/README.md:317-348` | Contracts measured（14 条红线） | 对应 reference（分组：编码器/容器→`encoder.md`、色彩→`colour.md`、原子替换/缓存/幂等→`operations.md`、交付门禁→`deliver.md`、wire/令牌→`wire.md`） | **全部并入 reference，卡片不保留摘要**；逐条确认无事实丢失 |

### `contract/README.md`（117 行）→ `contract/AGENTS.md` + 3 篇 reference

| 源 | 类型 | 归宿 | 动作/备注 |
|---|---|---|---|
| `contract/README.md:1-7` | 简介 | `contract/AGENTS.md` 一句话 | 收敛 |
| `contract/README.md:9-22` | 源文件表 | `contract/AGENTS.md`「布局」 | 原样搬入（表格；2026-11-05 改为保留） |
| `contract/README.md:24-29` | 相邻契约家 | `contract/AGENTS.md`「去哪看」 | 收敛为链接 |
| `contract/README.md:31-50` | Wire contract + 金样例 | `reference/wire.md` | 搬入 |
| `contract/README.md:52-63` | IPC contract | `reference/ipc.md` | 搬入 |
| `contract/README.md:65-90` | Recipe schema 0 字段表 | `reference/recipe.md` | 搬入 |
| `contract/README.md:92-104` | 数学 | `reference/recipe.md` | 搬入 |
| `contract/README.md:106-117` | 校验 / 确定性 / `renderKey()` | `reference/recipe.md` | 搬入 |

### `client/README.md`（180 行）→ `client/AGENTS.md` + 2 篇 reference

| 源 | 类型 | 归宿 | 动作/备注 |
|---|---|---|---|
| `client/README.md:1-14` | 简介 + contract map | `client/AGENTS.md` 一句话 +「去哪看」 | 收敛 |
| `client/README.md:16-47` | 布局 | `client/AGENTS.md`「布局」 | 原样搬入（含 apps/ios 段；2026-11-05 改为保留）；G9 收敛为模块地图，apps/ios 段移至 `apps/ios/AGENTS.md`（决策 #21） |
| `client/README.md:49-65` | 架构 | `reference/client.md` | 搬入 |
| `client/README.md:67-87` | 控件模型 / cap 语义 | `reference/client.md` | 搬入 |
| `client/README.md:89-111` | 状态与错误映射 | `reference/client.md` | 搬入 |
| `client/README.md:113-130` | 单一 MSL / parity gate | `reference/client.md` | 搬入 |
| `client/README.md:132-160` | 构建/测试 + Xcode 工程 | `client/AGENTS.md`「命令」；Xcode MCP/沙箱/包接线 → `AGENTS.md`「环境」 | 收敛 |
| `client/README.md:162-170` | 设备验收 | `reference/hardware.md` | 搬入 |
| `client/README.md:172-180` | 范围（P3/P6） | `client/AGENTS.md` 一句；P3/P6 状态 → `docs/status.md` | 收敛 |

### `tools/verify-heic/README.md`（168 行）→ `tools/AGENTS.md` + `reference/verification.md`

| 源 | 类型 | 归宿 | 动作/备注 |
|---|---|---|---|
| `tools/verify-heic/README.md:1-10` | 简介 | `tools/AGENTS.md` 表 + `reference/verification.md` 开头 | 收敛 |
| `tools/verify-heic/README.md:12-21` | 构建 | `tools/AGENTS.md`「命令」 | 收敛 |
| `tools/verify-heic/README.md:23-45` | 用法 | `reference/verification.md` | 搬入 |
| `tools/verify-heic/README.md:47-83` | 检查项 | `reference/verification.md` | 搬入 |
| `tools/verify-heic/README.md:85-131` | Report JSON | `reference/verification.md` | 搬入 |
| `tools/verify-heic/README.md:133-161` | ImageIO 观察 | `reference/verification.md` | 搬入 |
| `tools/verify-heic/README.md:163-168` | 与 app 的关系 | `reference/verification.md` | 搬入；`app/README.md` → `reference/deliver.md`，`PhotonCore` → `EngineKit` |

### `tools/visual-check/README.md`（62 行）→ `tools/AGENTS.md` + `reference/tools.md`

| 源 | 类型 | 归宿 | 动作/备注 |
|---|---|---|---|
| `tools/visual-check/README.md:1-12` | 简介 / 命令 / 依赖 | `tools/AGENTS.md` 表 + `reference/tools.md` 开头 | 收敛 |
| `tools/visual-check/README.md:14-25` | Viewer | `reference/tools.md` | 搬入 |
| `tools/visual-check/README.md:27-41` | 文件夹约定 | `reference/tools.md` | 搬入 |
| `tools/visual-check/README.md:43-54` | iPad 步骤 | `reference/tools.md` | 搬入 |
| `tools/visual-check/README.md:56-62` | limits / 红线 | `reference/tools.md` + `tools/AGENTS.md` 一句 | 搬入 + 收敛 |

### `tools/m0-fixtures/README.md`（22 行）→ `tools/AGENTS.md` + `reference/tools.md`

| 源 | 类型 | 归宿 | 动作/备注 |
|---|---|---|---|
| `tools/m0-fixtures/README.md:1-7` | 简介 | `tools/AGENTS.md` 表 + `reference/tools.md` | 收敛 |
| `tools/m0-fixtures/README.md:9-15` | 用法 | `reference/tools.md` | 搬入 |
| `tools/m0-fixtures/README.md:17-22` | 已验证数值 + RGBAf 规则 | `reference/tools.md`；RGBAf 规则在 `reference/encoder.md` 已有一条，只链接不重复 | 搬入 + 去重 |

## 3. 进 `docs/plans/` 的三篇（`git mv` + 链接 + front-matter）

### `docs/01-app-concept-and-three-stages.md`（148 行）→ `docs/plans/design-01-app-concept-and-three-stages.md`

| 源 | 类型 | 动作/备注 |
|---|---|---|
| `01:1-6` | 头部 | 移动；链接改新路径（`08 → ../reference/…`、`09 → stage-2-handoff.md`） |
| `01:8-52` | §0 概念与架构 | 移动；`samples/sources` → `fixtures/media/sources` |
| `01:56-93` | §1 stage 1（含 1.1–1.4） | 移动；stage 状态已并入 `status.md`，节内保留历史 |
| `01:97-126` | §2 stage 2 | 移动 |
| `01:130-139` | §3 stage 3 | 移动 |
| `01:143-149` | §4 不是什么 | 移动 |

### `docs/02-hdr-highlight-finisher-workflow.md`（140 行）→ `docs/plans/design-02-hdr-highlight-finisher-workflow.md`

| 源 | 类型 | 动作/备注 |
|---|---|---|
| `02:1-9` | 头部 + scope 声明 | 移动；链接改新路径；`samples/reference` → `fixtures/media/reference` |
| `02:13-22` | the loop | 移动 |
| `02:24-34` | §1 导出 | 移动 |
| `02:36-45` | §2 Mac 准备 | 移动 |
| `02:47-83` | §3 iPad 调整（控件/判据/技巧） | 移动 |
| `02:85-99` | §4 输出 / 分享 | 移动 |
| `02:101-123` | 好/坏观感、排错表 | 移动 |
| `02:125-140` | Settings / 不覆盖范围 | 移动 |

### `docs/09-stage-2-handoff.md`（79 行）→ `docs/plans/stage-2-handoff.md`

| 源 | 类型 | 动作/备注 |
|---|---|---|
| `09:1-7` | 头部 | 移动；链接改新路径 |
| `09:9-26` | §1 现在有什么 | 移动；表内链接改到卡片 / `reference/` |
| `09:28-47` | §2 验收基线 | 移动；正文不动（用户决定），只改链接目标 |
| `09:49-65` | §3 已知缺口 | 移动；内容不动 |
| `09:67-79` | §4 要重开的决定 | 移动 |

## 4. `docs/08-technical-reference.md`（217 行）→ `reference/` 按节拆

| 源 | 归宿 | 动作/备注 |
|---|---|---|
| `08:1-13` | `docs/README.md` 前言 | 叙述性头部不进 reference；G8 生成器的固定前言承继两条仍有效的事实：「✔ = stage-1 实测、证据在 archive」与「归档非必要不读」；companion 链接改新路径 |
| `08:15-40` | §1 → `reference/container.md` | 搬入；`samples/reference` → `fixtures/media/reference` |
| `08:42-61` | §2 → `reference/container.md` | 搬入；`docs/09` → `../plans/stage-2-handoff.md` |
| `08:63-110` | §3 → `reference/encoder.md` | 搬入 |
| `08:112-128` | §4 → `reference/colour.md` | 搬入；`samples/` → `fixtures/media/` |
| `08:130-147` | §5 → `reference/verification.md` | 搬入 |
| `08:149-178` | §6 → `reference/operations.md` | 搬入；`docs/01`/`docs/09` 链接改新路径 |
| `08:180-202` | §7 → `reference/performance.md` | 搬入；`docs/01` 链接改新路径 |
| `08:204-217` | §8 → `reference/hardware.md` | 搬入 |

`docs/08-technical-reference.md` 源文件在 G6 删除：八节已全部搬入 `reference/`；头部叙述（1-13 行）留给 G8 的 `docs/README` 固定前言。

## 5. `plans/` 与 `decisions/` 补 front-matter（G7，内容一字不动）

| 文件 | type | owner | updated |
|---|---|---|---|
| `plans/new-structure-description.md` | record | docs | 2026-11-05 |
| `plans/p0-report.md` | record | docs | 2026-11-05 |
| `plans/p1-plan.md` | record | docs | 2026-11-05 |
| `plans/p1-report.md` | record | docs | 2026-11-05 |
| `plans/p2-plan.md` | record | docs | 2026-11-05 |
| `plans/p2-report.md` | record | docs | 2026-11-05 |
| `plans/p3-plan.md` | record | docs | 2026-11-05 |
| `plans/p3-report.md` | record | docs | 2026-11-05 |
| `plans/p3-known-issue-preview-agreement.md` | record | docs | 2026-11-05 |
| `plans/p5-ref-doc-refactor-guide.md` | record | docs | 2026-11-05 |
| `decisions/0001…0010`（10 篇） | decision | docs | 2026-11-05 |

说明：`p3-known-issue` 只补元数据，内容不动；它因此会出现在 `docs/README.md` 索引里（用户 2026-11-05 决定）。

## 6. 新建 / 改写文件

| 文件 | 来源 | 动作 |
|---|---|---|
| `AGENTS.md` | 旧 `AGENT.md` + 迁移期 `AGENTS.md` | G5 重写 |
| `README.md` | 现 `README.md` | G5 改路径 + 状态改链接 |
| `docs/README.md` | 全库 front-matter + 一级标题 | G8 由 `docs-index` 生成 |
| `docs/status.md` | `AGENT.md:5-8` + 新内容 | G5 新建 |
| `docs/reference/wire.md` | server 213-315 + contract 31-50 | G3 新建 |
| `docs/reference/deliver.md` | server 121-182、184-211 | G3 新建 |
| `docs/reference/recipe.md` | contract 65-117 | G3 新建 |
| `docs/reference/ipc.md` | contract 52-63 | G3 新建 |
| `docs/reference/cli.md` | server 103-119 | G3 新建 |
| `docs/reference/client.md` | client 49-130 | G4 新建 |
| `docs/reference/encoder.md` | 08 §3 | G4 新建 |
| `docs/reference/container.md` | 08 §1+§2 | G4 新建 |
| `docs/reference/colour.md` | 08 §4 | G4 新建 |
| `docs/reference/verification.md` | 08 §5 + verify-heic 23-161 | G4 新建 |
| `docs/reference/operations.md` | 08 §6 | G4 新建 |
| `docs/reference/performance.md` | 08 §7 | G4 新建 |
| `docs/reference/hardware.md` | 08 §8 + client 162-170 | G4 新建 |
| `docs/reference/tools.md` | visual-check + m0-fixtures | G4 新建 |
| `contract/AGENTS.md` | contract README | G5 新建 |
| `server/AGENTS.md` | server README | G5 新建 |
| `client/AGENTS.md` | client README | G5 新建 |
| `apps/ios/AGENTS.md` | client README 的 apps/ios 部分 | G5 新建 |
| `tools/AGENTS.md` | 3 个 tools README | G5 新建 |
| `plans/design-01-…` / `design-02-…` / `stage-2-handoff.md` | docs/01、02、09 | G6 移动 |

## 7. 重复事实的唯一归属

| 事实 | 唯一归属 | 其余处理 |
|---|---|---|
| `renderKey()` 定义 | `reference/recipe.md` | `wire.md`/`deliver.md`/卡片只链接 |
| 8 项检查 | `reference/deliver.md` | `server/AGENTS.md` 一句 + 链接 |
| recipe schema 0 字段 | `reference/recipe.md` | `wire.md`/`deliver.md` 引用 |
| HTTP 端点/状态码/错误码 | `reference/wire.md` | `contract/AGENTS.md` 不重复 |
| `appctl` 命令与参数 | `reference/cli.md` | 卡片命令表一行 |
| 构建/测试命令 | `AGENTS.md` 命令表 | 卡片只列包级命令；沙箱细节只在 `AGENTS.md` |
| 机器/工具链/沙箱事实 | `AGENTS.md`「环境」 | `hardware.md` 只放判图硬件 |
| Display P3 源规则 | `reference/colour.md` | `AGENTS.md` 红线一句 |
| `sips` 陷阱 | `reference/container.md` | `verification.md` 引用；`AGENTS.md` 红线一句 |
| `AtomicFile` | `reference/operations.md` | `server/AGENTS.md` 一句 |
| headroom cap 2.5 | `reference/recipe.md`（字段语义） | `deliver.md` 检查阈值引用它 |
| 设备验收梯子 | `reference/hardware.md` | `client/AGENTS.md` 链接 |
| 归档策略 | `AGENTS.md` 工作规则 | ADR-0007 是记录 |
| 旧文档路径（代码注释） | `docs/reference/*` / `docs/plans/*` | 165 处注释机械替换；9 处错误消息/测试断言/注释字符串于 G9 清零 |
| stage 进度 | `docs/status.md` | `README.md` 一句 + 链接 |
| stage-2 已知缺口 | `plans/stage-2-handoff.md` | `status.md` 不重复 |

## 8. 归档

| 源 | 归宿 |
|---|---|
| `AGENT.md` | `docs/archive/migration/AGENT.md`（`git mv`，不改内容） |
| `AGENTS.md`（迁移期） | `docs/archive/migration/AGENTS-migration.md`（G5 先 `git mv` 腾出根文件名，不改内容） |

## 9. 明确不动

- `docs/archive/stage-1/**`（冻结；断链按 ADR-0007 接受）；
- `docs/plans/p3-known-issue-preview-agreement.md` 的正文（只补 front-matter）；
- `fixtures/media/`、`tools/toGainMapHDR/`、`work/` 等 gitignored 目录；
- 任何 `Sources/`、`Tests/`、`Package.swift`、`.xcodeproj`、Makefile 的构建逻辑；代码注释只改文档路径（G6.5）；9 处错误消息/测试断言/注释字符串于 G9 清零。
- 文件名以 `external-reference` / `user-note` 开头的文档（用户手动维护：docs-lint 全豁免，也不进 docs 索引）。

## 10. 自查

- 6 个待删 README 的每一段都有归宿：**是**（第 2 节逐节列出）；
- 找不到归宿的段落：**0**；
- 根 `AGENTS.md` 只留 1 条全局红线 + 2 条环境；其余条目在第 1 节逐条给出下沉去向；
- 无 dropped 的技术内容；三处 Layout 曾原样进入卡片，G9 起收敛为包/模块地图、逐文件清单删除（决策 #21）；只有 README 里被 `status.md` 取代的状态重复被删；
- 代码注释 165 处旧路径已替换（54 文件，零逻辑）；9 处字符串/注释于 G9 清零；
- docs-lint 0 error；卡片 > 40 行仍为 warn，> 60 行为 error（计划 §8）。
- 技术事实无删除：server 的 14 条红线全部进 reference，卡片不保留摘要；
- 预计净行数：**-5%~-10%**（布局删除与 front-matter 新增大致抵消）；
- 本表在 G6 删除前逐段复核；复核不过的段落不删。
