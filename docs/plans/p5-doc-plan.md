---
type: record
owner: docs
updated: 2026-11-06
---

# P5 文档重构计划

*P5 的文档部分，分支 `docs/p5-doc-refactor`。本文件是 G0–G9 的计划记录；执行状态只维护在 [status.md](../status.md)。*

## 0. 范围

**做：** docs 结构重组、子项目卡片、`docs/reference/`、`docs/status.md`、根 `AGENTS.md` 与 `README.md`、`plans/`+`decisions/` 补 front-matter、根 agent 文件归档、docs 机器约束（规则与阈值到 G8 再定）。

**不做：** `workspace.xcworkspace`、`design/` 包、根 Makefile 的非 docs target、`docs/ui/` 内容（P6）、P4 macOS app、`docs/archive/stage-1/` 的任何修改。

**特殊：** `plans/p3-known-issue-preview-agreement.md` 只补 front-matter，内容一字不动（用户决定，后续手动处理）。

## 1. 已定决策

| # | 决策 |
|---|---|
| 1 | 根入口只留 `AGENTS.md`；旧 `AGENT.md` 与迁移期 `AGENTS.md` 归档到 `docs/archive/migration/` |
| 2 | 卡片统一 `<子项目>/AGENTS.md`，由根 `AGENTS.md` 的路由表指路 |
| 3 | docs 结构：`status.md` + `reference/` + `plans/` + `ui/`（P6）+ `archive/` + `README.md` |
| 4 | `01`/`02` → `plans/design-01-…`、`design-02-…`；`09` → `plans/stage-2-handoff.md` |
| 5 | `plans/` 与 `decisions/` 补 front-matter 并写进 `docs/README.md`；只有 `archive/` 豁免 front-matter 且不进索引 |
| 6 | `type` 取值：`reference` / `agent` / `decision` / `record` / `status`；`plan` 与 `report` 一律用 `record`；`docs/README.md` 豁免 |
| 7 | `owner` 统一 `docs`（plans/decisions）；`updated` 取 git 最后一次内容提交日，补 front-matter 不改它 |
| 8 | 语言：导航层（卡片/status/README/AGENTS/docs README）中文；`reference/` 保留英文原文，只修死链 |
| 9 | 文档规则（卡片 40 行、标题白名单、黑名单标题等）**G8 再议**，本计划不预设阈值 |
| 10 | `tools/` 只做一张 `tools/AGENTS.md` |
| 11 | `01`/`02` 内联的 `samples/…` 改为 `fixtures/media/…`，只改路径 |
| 12 | `docs/ui/` 本次不建 |
| 13 | 第一轮搬而不改：只修死链、旧路径、过期模块名；压缩改写放第二轮逐段确认 |
| 14 | 三个 README 的 Layout 节原样放进对应卡片「布局」；行数问题留到 G9（2026-11-05 改） |
| 15 | `server/README.md` 的 14 条 `Contracts measured` 全部进 reference，不在卡片保留摘要 |
| 16 | `09` 正文不重写、不去重：只 `git mv` + 改链接目标 + 补 front-matter |
| 17 | 根 `AGENTS.md` 只留 1 条全局红线（交付目标 + SDR 回退）与 2 条环境（开发机/判图硬件、归档策略）；其余红线与环境事实去重后下沉到子项目 `AGENTS.md` 与 `reference/` |
| 18 | 代码注释里的旧文档路径（165 处 / 54 文件）脚本机械替换；9 处错误消息/测试断言/注释字符串 G9 清零（原记 8 处，实为 7 字符串 + 2 注释） |
| 19 | docs-lint 规则分 error / warn 两档（G8 定；G9 增卡片 > 60 行与代码旧文档名 error，见 #18/#21）；`archive/`、生成的 `docs/README.md`、`external-reference*`/`user-note*` 全豁免（不 lint、不进索引） |
| 20 | server 卡片里的共享契约段与 contract 卡片重复且含 P1 旧事实，删除；依赖链接事实补进 contract 卡片 |
| 21 | G9：卡片「布局」收敛为包/模块地图，删除逐文件清单（G5 原样搬入的 Layout 到此结束）；不追 40 行硬限，`docs-lint` 以 > 60 行为 error、> 40 行为 warn（2026-11-06） |

## 2. 目标树

```text
AGENTS.md                              # 入口：命令表 + 红线 + 文档路由 + 工作规则
README.md                              # 人读入口（短）
docs/
  README.md                            # 生成：按任务导航（do not edit）
  status.md                            # 唯一易变状态：迁移做到哪、下一步、相关缺口
  reference/                           # 精确事实（英文原文）
  plans/
    design-01-app-concept-and-three-stages.md
    design-02-hdr-highlight-finisher-workflow.md
    stage-2-handoff.md
    new-structure-description.md
    p0-report.md … p3-report.md
    p5-ref-doc-refactor-guide.md
    p5-doc-plan.md
    p5-doc-mapping.md
  ui/                                  # P6，本次不建
  decisions/                           # 10 篇 ADR，原地保留，补 front-matter
  archive/
    stage-1/                           # 冻结，不动
    migration/                         # 旧 AGENT.md + 迁移期 AGENTS.md
contract/AGENTS.md  server/AGENTS.md  client/AGENTS.md
apps/ios/AGENTS.md  tools/AGENTS.md
```

## 3. 类型与 front-matter

| 文件组 | type | owner | updated |
|---|---|---|---|
| `docs/status.md` | `status` | `docs` | 实际改动日 |
| `docs/README.md` | **豁免**（生成） | — | — |
| `docs/reference/*.md` | `reference` | 主题归属（`contract`/`server`/`client`/`tools`/`docs`） | 内容最后修改日 |
| `*/AGENTS.md` 卡片 | `agent` | 该子项目 | 内容最后修改日 |
| `docs/plans/*.md` | `record` | `docs` | git 最后内容提交日 |
| `docs/decisions/*.md` | `decision` | `docs` | git 最后内容提交日 |
| `docs/archive/**` | **豁免** | — | — |

历史文件的 `updated` 用 git 最后一次内容提交日，不用“补元数据”的当天；否则 25 篇历史记录会全部显示“今天改过”。

## 4. `docs/status.md`

结构已按「现在做到哪 / 下一步 / 相关缺口 / 门禁」落地；内容只维护在 [status.md](../status.md)，本文件不复制。与 `plans/stage-2-handoff.md`（产品 stage-2 计划）无重叠。

`plans/stage-2-handoff.md` 保持原内容，只改路径/链接 + 补 front-matter。

## 5. reference 拆分（G1 提案，G3/G4 可合并）

| 文件 | 吸收自 | owner |
|---|---|---|
| `wire.md` | server README「M2 server」+「M2.1 wire contract」+ contract wire 类型表 | `contract` |
| `deliver.md` | server README「M4 delivery」+「Report schema 0」（8 项检查、两种 base 比较） | `server` |
| `recipe.md` | contract README：schema 0 字段、数学、校验、`renderKey()` | `contract` |
| `ipc.md` | contract README「IPC」+ appctl 进程契约事实（细节指向 ADR-0010） | `contract` |
| `cli.md` | server README：`appctl prep/serve/deliver` 用法与参数 | `server` |
| `client.md` | client README：架构、控件语义、状态/错误、parity | `client` |
| `encoder.md` | 08 §3 | `docs` |
| `container.md` | 08 §1 + §2（容器方言、查看器陷阱） | `docs` |
| `colour.md` | 08 §4 | `docs` |
| `verification.md` | 08 §5 + tools/verify-heic README（检查项、report schema、ImageIO 观察） | `docs` |
| `operations.md` | 08 §6 | `docs` |
| `performance.md` | 08 §7 | `docs` |
| `hardware.md` | 08 §8 + client README「Device acceptance」 | `docs` |
| `tools.md` | visual-check + m0-fixtures 用法 | `tools` |

三个 README 的 Layout 节原样放进对应卡片的「布局」节（2026-11-05 决定；不建 `layout.md`）。G9 已按决策 #21 收敛为包/模块地图，不再保留逐文件清单。

## 6. 工作流

| 门 | 内容 | 产出 | 用户审 |
|---|---|---|---|
| **G0** | 计划确认 | — | 已完成 |
| **G1** | 映射表 + 计划定稿 | 本文件 + `p5-doc-mapping.md` | **逐行审映射** |
| **G2** | 骨架：目录、空壳、front-matter 模板、根 `AGENTS.md` 路由表草稿 | 骨架文件 | 结构、路由 |
| **G3** | reference 第一批：`wire/deliver/recipe/ipc/cli` | 5 篇 | 逐字读 |
| **G4** | reference 第二批：`client/encoder/container/colour/verification/operations/performance/hardware/tools` | 9 篇 | 逐字读 |
| **G5** | 卡片 5 张 + 根 `AGENTS.md` + `README.md` + `status.md` + `docs/README.md` | 9 个文件 | 逐字读 |
| **G6** | 搬迁 01/02/09；删除 6 个旧 README + 拆完的 08；归档 `AGENT.md`（`AGENTS.md` 已在 G5） | 移动 + 删除 | 删除清单 + 映射回执 |
| **G6.5** | 代码注释旧路径机械替换（54 文件 / 159 行，零逻辑） | 注释 diff | 抽读 diff（应只含 `//`/`*` 行） |
| **G7** | 24 个历史文件补 front-matter（含 p3-known-issue 只补元数据） | 机械 diff | 抽读 diff |
| **G8** | 机器约束：`docs-lint`（4 error + 4 warn）与 `docs-index`，Makefile 接入 | `tools/docs-lint.py` | 规则确认 |
| **G9** | 全库链接、`docs-check` 0、用户逐字通读 → 合 `main` | 收尾 | 最终验收 |

每个门只交付四样：变更清单 + 映射、前后行数、按优先级排序的阅读清单、拿不准的问题。

## 7. 规模

- 源：13 个活文档 / 1,645 行。01/02/09（367 行）只搬不改；重写集中在 08（217 行）+ 4 个 README（897 行）+ 根文件（164 行）。
- 目标：reference 约 930 行、卡片约 290 行（含三处 Layout，超 40 行暂不处理）、根文件约 70 行、status 约 30 行、plan/mapping 约 450 行、front-matter 约 100 行。
- 删除 6 个文件；移动 5 个文件（01/02/09 + 两个根 agent 文件）；代码注释 165 处旧路径机械替换（54 文件）。行数不再作为本轮约束，G9 再定。
- 9 个工作门 + G0；9 个提交；最重的是 G1 与 G3/G4。

## 8. 机器约束（G8 定稿）

`tools/docs-lint.py`：只有 error 让 `make docs-lint` 失败，warn 不失败。

| 检查 | 档位 |
|---|---|
| front-matter 三键齐全（`docs/**` 除 archive/ 与生成的 `docs/README.md`；卡片也要） | error |
| 相对链接可解析（`docs/**` 除 archive + 根文件 + 卡片） | error |
| `docs/README.md` 与 `docs-index` 生成结果一致 | error |
| 旧路径（`samples/`、`app/README`、`ipad/README`、`docs/0X-`）只扫活文档 | error |
| 代码注释/字符串里的旧文档名（`AGENT.md`、子项目 `README.md`、`docs/0X-`、`08-technical-reference`） | error |
| 卡片行数 > 60 | error |
| 卡片行数 > 40、标题不在白名单、代码块 > 4 行 | warn |
| 卡片与 reference 的黑名单标题 | warn |

豁免：`docs/archive/**`、生成的 `docs/README.md`、以及文件名以 `external-reference` 或 `user-note` 开头的所有文件（用户手动维护：不 lint、不进索引，加文件无需重新生成索引）。

Makefile：`make docs-lint`、`make docs-index`；`make docs-check` 是 `docs-lint` 的别名；`make check` 已包含 `docs-lint`。

## 9. 执行规则

- 分支 `docs/p5-doc-refactor`；每门一个提交；最终验收后合 `main`。
- 第一轮搬而不改；压缩改写单独一轮，逐段给 before/after。
- 删除必须附映射回执；找不到归宿的段落原样保留并进问题清单。
- 停止条件：找不到归属 / 两个文件事实冲突 / 删除超原文 30% / 卡片放不下且 reference 无位置 / 需要改语义。
- 子 agent 只做只读核查；所有写入由 Lead 做。

## 10. 完成判据

- 根目录只有 `AGENTS.md` 一个 agent 入口；旧文件已归档；
- 6 个子项目 README 已删除，每段都有映射归宿（三处 Layout 已原样放进卡片）；
- `docs/README.md`、`docs/status.md`、`docs/reference/` 建成；`plans/` 与 `decisions/` 有 front-matter；
- 活文档死链 0（`archive/` 按 ADR-0007 豁免）；代码注释与字符串里的旧文档路径已清（G9）；
- 用户逐字读完所有新文档；
- G8 的检查全绿（按其最终规则）；
- 合并回 `main`。
