---
type: record
owner: docs
updated: 2026-11-05
---

本文档**仅用作参考**，**不是对你的直接要求**。这是用户咨询另一个 LLM 得到的执行指南。它不清楚本项目的具体内容，只知道目录结构（可能会过时）。你必须结合项目实际情况工作。用户对文档质量要求非常高，你有拿不准的地方，如发现矛盾（如`dpcs/`目录结构冲突）或有应当适当修改的内容（如DSH内不用`make`而是用Xcode MCP `BuildProject`），务必先询问用户的意见。

# 任务：重构本仓库的文档组织方式

你现在的目标是**重新组织已有的文档，而不是重写文档内容**。本任务结束时，仓库中每个子项目都只有一张不超过 40 行的卡片，所有精确事实集中在 `docs/reference/`，所有易变状态集中在 `docs/status.md`，并且有一个 `make docs-lint` 能阻止文档再次膨胀。

## 0. 总原则（必须先读，全程遵守）

1. **搬而不改。** 第一阶段只允许剪切和粘贴原文，不允许改写、精简措辞或“顺手优化”。技术事实一旦被你重新表述，就等于丢失细节。
2. **一条事实只能有一个归属地。** 详细内容只放在它的归属文件里，其他地方只写一句加链接。
3. **不许丢信息。** 你移动的每一段内容都必须能在映射表（见 §6）里找到新家。找不到新家的内容，就说明归属没定清楚，停下来问用户。
4. **不许改源代码。** 本任务不改任何 `Sources/`、`Tests/`、`Package.swift`、`.xcodeproj`、`Makefile` 的构建逻辑。只允许新增 `docs` 相关的 Makefile target。
5. **有疑问就问。** 尤其遇到 §2 里列出的冲突项，不要自己裁决。

## 1. 阶段 1：盘点与确认（不改文件）

先做三件事，然后向用户提问一次，拿到答复再往下走。

**1.1 清点现状**，把结果写进回复（不要写进仓库）：
- 列出所有 `README.md` / `AGENT.md` 及其行数。
- 每个文件按段落打标：`命令` / `契约事实` / `环境事实` / `布局` / `叙事`（背景、动机、历史、“未来可做”）/ `状态`（stage、进度、TODO）/ `其他`。

**1.2 找出重复**：同一事实出现在两个及以上文件的地方，逐条列出（例如 `renderKey()`、`schema 0`、`8 项检查`、协议字段名、build/test 命令）。

**1.3 必须向用户确认的问题**（一次问完，不要逐条打断）：
- 子项目卡片用 `AGENTS.md` 还是 `README.md`？你的 agent 工具是否会自动加载嵌套的 `AGENTS.md` 并与根文件合并？若不确定，选择 `README.md`。
- 归属冲突如何裁决：`server/*` 声明自己负责“M2.1 线协议”，而 `contract/*` 声明自己是“两端共享契约的唯一定义”。**默认裁决：wire/recipe 字段契约归 `contract`，交付契约与 report schema 归 `server`。** 需要用户确认。
- 文档中 `ipad/README.md` 指向的路径在仓库里实际是 `apps/ios/`，以哪个为准？
- `design/`、`tools/*` 是否需要独立卡片，还是合并为 `tools/` 一张表 + `design/` 一张卡？

## 2. 阶段 2：建立新骨架（只创建空文件和目录，不填内容）

```
docs/
  status.md                    # 唯一的易变状态
  reference/                   # 精确事实，一节一文件
	wire.md recipe.md deliver.md cli.md encode.md
  README.md                    # 稍后由脚本生成，此阶段先留占位
contract/AGENTS.md             # 或 README.md，按用户答复
server/AGENTS.md
client/AGENTS.md
apps/ios/AGENTS.md
apps/macos/AGENTS.md
design/AGENTS.md
tools/AGENTS.md
```

**不创建的子项目卡片**：`docs/`（它自己就是文档）、`fixtures/`。

每篇 `docs/reference/*.md` 和每张卡片都必须有 front-matter：

```yaml
---
type: reference        # reference | card | decision | plan | record
owner: server          # 归属子项目
updated: 2026-11-05
---
```

## 3. 阶段 3：迁移内容（主体工作）

逐个文件处理，顺序：`contract` → `server` → `client` → `apps/ios` → `apps/macos` → `design` → `tools` → 根 `README.md` → `AGENT.md`。

对源文件里的每一个段落：

| 段落类型 | 去向 |
|---|---|
| 字段、schema、数学公式、检查项、协议、API 细节 | `docs/reference/<主题>.md`（原文整段搬入） |
| 构建/测试/运行命令 | 卡片里的一行 `make` target；若命令有复杂说明，正文进 reference |
| 目录与源码布局 | 卡片的 `## 布局` 节，一行一项 |
| 不变量、“改了会坏”的约束 | 卡片的 `## 不许破坏` 节 |
| 环境事实（机器、系统、设备、Xcode 版本） | 卡片的 `## 环境` 节；跨子项目通用的放根 `AGENTS.md` |
| stage、进度、TODO、里程碑 | `docs/status.md` |
| 叙事：背景、动机、为什么当初这么做、以后可以做 | `docs/decisions/` 或 `docs/archive/`；没有决策记录价值的直接删除，并在映射表里标 `dropped` + 一句话理由 |
| 与其他文件重复的内容 | 只留在归属处，其余改为 `详见 <链接>` |

**卡片固定骨架**，只有这 5 个标题，小标题为空时整节删除，不写“暂无”：

```md
---
type: card
owner: server
updated: 2026-11-05
---

# server
一句话：这台 Mac 上的常驻服务，把 recipe 渲染成 HEIC，经 appctl 交付给 iPad。

## 布局
- `Sources/ServerCore` — 渲染与校验
- `Sources/appctl` — CLI 入口

## 命令
| 目的 | 命令 |
|---|---|
| 全部测试 | `make test-server` |

## 不许破坏
- report schema 0 的字段顺序即契约，改字段等于改版本号，须同步 `contract`。

## 环境
- macOS 27.2 / M1 Max / Xcode 27.2 / Swift 6.4

## 去哪看
- 交付契约与 8 项检查 → `docs/reference/deliver.md`
- 协议字段 → `contract/AGENTS.md`
```

**禁止出现在卡片和 reference 里的标题**：概述、简介、背景、特性、设计思路、未来工作、TODO、Changelog。出现即说明内容归类错了。

**完成后删除**所有已被卡片取代的旧文件（`server/README.md`、`contract/README.md`、`tools/*/README.md`、`ipad/README.md` 等）。删之前确认：该文件的每一段都在映射表里有归宿。

## 4. 阶段 4：改根文件

根目录下旧的 `AGENT.md` 改造三处：

**4.1 删掉 `## 阶段状态` 整节**，内容原样搬进 `docs/status.md`。

**4.2 把“文档归属”表换成路由表**，行是任务不是主题：

```md
## 文档路由（按任务查）

| 我要改… | 先读 | 细节唯一来源 |
|---|---|---|
| wire / recipe 字段 | `contract/AGENTS.md` | `docs/reference/wire.md` |
| 交付、report、8 项检查 | `server/AGENTS.md` | `docs/reference/deliver.md` |
| CLI 行为 | `server/AGENTS.md` | `docs/reference/cli.md` |
| 屏幕行为、状态、parity | `apps/ios/AGENTS.md` | `docs/ui/screens/*` |
| 视觉 token | `design/AGENTS.md` | `docs/ui/tokens.md` |
| 当前做到哪 | `docs/status.md` | `docs/status.md` |
```

**4.3 在“工作规则”末尾追加**（与现有“测试只增不减是缺陷”并列）：

```md
- **文档只增不减是缺陷。** 改动引入新细节时，同一个提交里必须删掉被它取代的段落或链接改指。
  加进卡片的每一行都要能回答“删掉它 agent 会做错什么”，答不出来就删。
  叙事、动机、历史、未来计划不进卡片和 reference，只进 `docs/decisions`、`plans`、`archive`。
- **卡片是硬预算**：每个子项目卡片 ≤ 40 行。超了删内容或把细节搬去 reference，不许放宽阈值。
- **同一事实只允许一处非链接出现。** 发现重复时先定归属，把细节收敛过去，其余改成引用。
```

把改造后的内容放进 `AGENTS.md`，归档旧 `AGENT.md`。

## 5. 阶段 5：加机器约束

新建 `tools/docs-lint.py`，并在 `Makefile` 加 `docs-lint` 与 `docs-index` 两个 target（挂进 pre-commit 与 CI）。

脚本必须实现：

1. `make docs-lint` 检查项：
   - 所有 `type: card` 文件行数 ≤ 40（> 40 警告，> 60 退出码 1）
   - card 文件的 `## ` 标题集合必须是白名单子集：`布局 命令 不许破坏 环境 去哪看`
   - card 内单个代码块 > 4 行 → 失败（代码属于源码或 reference）
   - 黑名单标题（§3 列表）出现在 card 或 reference → 失败
   - 每篇 `docs/**` 与卡片必须有 `type`、`owner`、`updated` 三个 front-matter 键
   - 所有相对 markdown 链接必须可解析，否则失败
   - 关键标识符 `renderKey()`、`schema 0`、`8 项检查` 在 `docs/` 之外的非链接出现次数必须为 1（逐个可配置成列表）
   - `docs/README.md` 与 `make docs-index` 的生成结果一致（`--check`），不一致则失败
2. `make docs-index`：扫描 `docs/**` 的 front-matter 与一级标题，按 `reference / plans / decisions / ui / archive` 分组重写 `docs/README.md`。生成的文件顶部标注 `<!-- generated by make docs-index, do not edit -->`。

阈值设定顺序：**先按当前实际值上线跑绿，之后每轮收紧 5 行，直到 40 行**。不要一上来就设 40 让 CI 红着。

## 6. 阶段 6：交付物

提交信息格式：`docs: <阶段> — <一句话>`。建议顺序，每个提交都必须 `make test` 与 `make docs-lint` 通过：

1. `docs: 盘点 + 新增 reference 骨架`
2. `docs: 把各 README 细节整段搬进 reference`（此提交只增不删）
3. `docs: 各子项目 README/AGENT 收敛为卡片并删除旧文件`
4. `docs: AGENT.md 去阶段状态、换路由表、加文档规则`
5. `docs: 加 docs-lint 与 docs-index`

最终回复里必须给出**映射表**，一行一个源段落：

| 源文件:行范围 | 类型 | 去向 | 处理 |
|---|---|---|---|
| `server/README.md:12-58` | 契约事实 | `docs/reference/deliver.md` | 原样搬入 |
| `server/README.md:60-64` | 叙事 | — | dropped：stage 1 试点记录，无决策价值 |
| `ipad/README.md:30-44` | 重复 | `docs/reference/wire.md` | 改为链接 |

## 7. 验收标准（自查清单）

- [ ] 仓库中不再存在子项目级 `README.md`（除根 README 与 `docs/README.md`）
- [ ] 每张卡片 ≤ 40 行，标题只用白名单
- [ ] `make docs-lint` 与 `make test` 全绿
- [ ] 映射表覆盖所有被删文件的所有段落，无 `unmapped` 行
- [ ] 在 `docs/` 里搜任意一个关键标识符（如 `renderKey`），只有一个定义点，其余是链接
- [ ] `docs/status.md` 是唯一出现 stage/进度/TODO 的地方
- [ ] 没有修改任何源码文件（`git diff --stat` 里只有 `docs/`、`*_/AGENTS.md`、`Makefile` 的 docs target）

## 8. 停止条件

遇到以下情况**立刻停下问用户**，不要自行决定：

- 某段内容找不到归属文件（说明 §1.3 的裁决不够用）
- 发现两个文件对同一个技术事实的表述**互相矛盾**（不是重复，是冲突）
- 需要删除的内容超过原文 30%（可能说明你把该保留的事实误判成叙事）
- 卡片在 40 行内放不下，且 reference 里也没有合适位置

---

**一句话总结给 agent**：把长 README 里的技术事实原样搬进 `docs/reference/`，把各子项目文件收敛成 40 行卡片，把状态移进 `docs/status.md`，然后上一个 lint 让文档再也不可能变长。