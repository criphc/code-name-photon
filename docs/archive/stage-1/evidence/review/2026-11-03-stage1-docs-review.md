# stage 1 文档审阅 — 2026-11-03

**范围** 全部 15 个被跟踪 `.md`（`docs/01–07`、`README.md`、`AGENT.md`、`app/README.md`、`ipad/README.md`、`tools/{verify-heic,m0-fixtures,visual-check}/README.md`、`notes/`），约 2.1k 行 / 206 KB。行号基准 `ee0a8f8`（工作树干净，未修改任何被跟踪文件）。

**方法** Lead 通读全部文档并独立复核关键结论；两名 teammate 并行做机械核对：
- **fact-checker**：把文档里可检验的事实逐条对到代码/产物（`work/review/facts.md`，未跑测试套件）。
- **structure-auditor**：解析全部 159 个 markdown 链接 + 约 93 个 `§`/`Mx` 文本引用，核对单一归属与数字一致性（`work/review/structure.md`，481 行）。

**结论** 文档体系的**真实性**和**纪律性**都在高水位：DoD 逐条有证据、结果不是编的、单一归属规则执行得好（M2.1 契约是范本）。问题几乎全部集中在**"收尾记账"**：4 处结果段落与已安装产物不一致、约 12 句仍停留在"将来时"、6 个坏链接、以及**证据与交接不出仓库**这一结构性缺口。**stage 1 PASS 的结论不受影响。**

---

## 1. 复核后可以放心的部分（不必再动）

| 项目 | 结果 |
|---|---|
| 测试计数 `255 = 142 + 113`（docs/07:307） | 静态计数精确一致；`229 = 116+113` 在 M4 前提交上也精确 |
| `out/` 四个交付文件 | 字节数与 sha256 与 docs/07 §10 完全一致，且 `out/` 里只有这四个 |
| `photon deliver` CLI 面、默认值、encoder 解析顺序 | 与 `docs/07` §5.3 逐项一致 |
| 11 个 `PhotonError`、exit 1/2、8 个 check 名、`pass`/`failures` 读回重推导 | 全部存在且语义如文档所述 |
| 所有符号 / 工具 / 证据路径 | 存在（`EncodedHEICValidator`、`DeliveryVerifier`、`HighlightShape`、`work/m4/*`、`work/m5/*` …） |
| 环境事实（macOS 27.2 / M1 Max / Xcode 27.2 / Swift 6.4.2 / encoder `5dba4e2` / 无 simulator runtime） | 正确 |
| 仓库卫生 | 无 TODO/FIXME/占位符；60 个跟踪文件，无构建产物；链接图基本干净、无标题层级断裂 |

---

## 2. A 组 — 事实错误（值与产物不符，会误导读者）

| # | 位置 | 问题 | 修法 |
|---|---|---|---|
| A1 | docs/07:200 | `previewAgreement` 写作"measured on the trial data: mean 1.16, p99 5.27, 1.24 %"，但 `out/R0003777-P3.report.json` 实测 **mean 1.1902 / p95 3.37 / p99 5.42 / 1.373 %**（同文 §10:331 才是对的）。1.16/5.27/1.24 是 M0 的 lostless 标定值（`DeliveryVerifier.swift:118-126`） | 换成 report 值，或标为"M0 标定，非交付实测" |
| A2 | docs/07:333-335, 363 | "from the report … = 20.73 s"：`out/` 的报告是 **20.683 s**（preview 0.368 / encode 1.361 / verify 15.844）；20.73 来自 `work/m4/run1`，产物被后来的 `<id>` 运行覆盖。且列出的五项相加 = **18.18 s**，不等于 20.73 | 重引 `out/` 报告；补/删"= 合计"的算式（约 2.6 s 未列入分解） |
| A3 | docs/04:131 | "Nothing persisted consumes `renderKey()` yet（M2.1 只写进 `state.json`）" — M4 后 `{stem}.report.json` 与 `{stem}.recipe.json` 都持久化并消费 `renderKey` | 改为"M4 起 `report.json` 记录并消费它；缓存仍不消费" |
| A4 | docs/07:181 | 声称 §5.4 表"in report order"，实际代码/产物顺序是 …headroom, **clipping, baseDeltaE**…，表里是 baseDeltaE 在前（§10:322-331 顺序正确） | 调表顺序或在句末注明 |
| A5 | docs/07:178 | 报告里 `recipe` 字段是 camelCase（`liftStops` / `headroomCap` / `quality` / `depth`），表里写的是 schema 的 snake_case（`lift_stops` / `headroom_cap`） | 用报告的实际键名，schema 名加标注 |
| A6 | docs/07:199 | `fallback` 的 PASS 规则写着"(copy-vs-16-bit-base reported as diagnostic)"，但 `fallback.measured` 里没有这一项，`detail` 也没提——该诊断**未实现** | 删掉括号，或实现后再写 |
| A7 | docs/07:313 | "report.json differs only in timings" — `provenance.generatedAt` 也不同 | 改成 "timings 与 generatedAt" |

## 3. B 组 — 阶段边界的"将来时"（M5 之后仍像未完成）

| # | 位置 | 现状文本 | 事实 |
|---|---|---|---|
| B1 | docs/03:151 | "Recipe-keyed full renders and the FSEvents watcher remain M4/stage-2 work" | recipe-keyed 全分辨率渲染已由 M4 `photon deliver` 交付；只剩 watcher |
| B2 | docs/02:9 | "Stage 1 is the command-line loop **being built now** … delivered HEIC written in M4" | 已关闭 |
| B3 | docs/05:70 | "(M4 **will** add ΔE2000 per docs/03 §5.)" | M4 已加（`baseDeltaE`） |
| B4 | docs/05:97 | "M5.1 **will promote** a generalised copy into `tools/visual-check/`" | 已提交（`96f8ca1`） |
| B5 | README:12 | CLI 写作 "（prep / serve）" | 缺 `deliver` |
| B6 | README:18 | tools 树 "toGainMapHDR · verify-heic · m0-fixtures" | 缺 stage-1 唯一的**新提交工具** `visual-check/` |
| B7 | README:7 | 单段 928 字符的状态叙述，以"M0–M2.1 已完成"开头，随后 M3/M4/M5 一路铺开 | 落地页第一句就与"M5 已通过、stage 1 完成"冲突；每过一阶段都要重写整段 |
| B8 | docs/07:254 | §7 协议把 "screenshots" 列为 M5 证据 | `work/m5/` 没有任何截图（截图在 `work/m3/evidence/`，M5 是靠人眼判定） |
| B9 | app/README:46 | `main.swift` 描述为 "`photon prep …` and `photon serve …` CLI" | 缺 `deliver` |

> docs/05 里的 B3/B4 两类**不算错误**：该文件自我定位为"历史记录，不是规范"。正确修法是加一行归档横幅（"以下将来时的条目均已随后续里程碑完成：ΔE2000 见 M4，visual-check 见 M5.1"），而不是改写历史。

## 4. C 组 — 结构与卫生

| # | 位置 | 问题 | 修法 |
|---|---|---|---|
| C1 | `tools/visual-check/README.md:5,56,58,90,96,99` | 6 个链接用 `../docs/`，但文件在 `tools/visual-check/`，正确是 `../../docs/` — **全部 404** | 一处 sed 可修 |
| C2 | docs/04:16、docs/04:143、docs/07:270 | 用 `docs/05 §2` 支撑"`-R` 在 `-b` 下无效"，该证据在 **§3.1**（§2 是"交付文件是什么"） | 改 §3.1 |
| C3 | docs/07:196 | 把 `calculatedContentHeadroom` 交叉核对的归属指到 docs/03 §5，实际家在 docs/05 §3.3 | 改引用 |
| C4 | app/README:75 / :166 | 指 "`AGENT.md` §Environment"（无此标题，实为「环境」）；用 docs/01 §0 支撑 bit-exact（家应是 docs/03:139 / docs/04 M1） | 改引用 |
| C5 | 文档头部 | 三套编号并存：01–03 = "Design document N"、04–05 **无编号**、06–07 = "Plan document N"；docs/04 是唯一没有 `§N` 编号的计划文档，所以任何 "docs/04 §2.1" 都解析不了 | 统一头部格式 + 给 docs/04 补章节号 |
| C6 | AGENT「文档归属」表 | 缺 3 个被跟踪文件的行：`tools/verify-heic/README.md`、`tools/m0-fixtures/README.md`、`notes/…` | 补三行（notes 标"非规范"） |
| C7 | 行宽 | docs/04:125 = **1409 字符**、:131 = 1242、:127 = 1125、docs/03:113 = 1062、README:7 = 928、AGENT:52 = 840。这正好是"用户会经常手改"的文件 | 把这几条拆成 bullet（内容不变） |
| C8 | 术语 | `P3` / `Display P3` / `DisplayP3` 混用；"doc 03 §3" 与 "docs/03 §3" 混用；docs/01 用 "the Mac app" 指 stage 1 的 CLI（stage 1 没有 Mac UI） | 一次性统一 |
| C9 | 根目录与 docs/ | 有 `.DS_Store`（未跟踪，但会进备份/打包） | 删掉并确保 tar 排除 |

## 5. D 组 — 体系缺口（这是"文档情况"里最值得动的一层）

**D1 验收证据不进仓库（最严重）。** `work/`（m0–m5 全部 log/json/md/screenshot）、`out/`（四个交付文件）都在 `.gitignore` 里。docs/07 §10 引的每一个 sha、docs/05 §7 的复现命令、docs/06 §10 的设备记录，在干净 clone 里**一条都复核不了**；M0 的 `work/m0/real/render.swift` 更是"原型不提交"。
代价其实很小：`work/` 下全部文本证据只有 **1.5 MB / 150 个文件**（`*.log *.json *.md *.txt *.sh *.time`）。建议提交一份 `evidence/m4/`、`evidence/m5/`（只文本，不含 TIFF/HEIC），或把 §10 引用的字段直接内联进文档。这是 stage 1 关闭时唯一"丢了就补不回来"的东西。

**D2 缺一份 stage-2 交接清单。** 遗留项目前散在 6 处：EXIF/orientation rewrap（docs/07 §2 + docs/03 §6）、409 re-judge 流程未在设备上验证（docs/06 §10）、beyond-headroom band 在 2.5 cap 下不可观测（docs/06 §10 第 3 条）、verification 串行 ~15.8 s（docs/07 §9）、TLS/Bonjour 未排期（docs/03 §6）、无 Mac UI / 无队列（docs/07 §8）。建议在 `docs/01 §2`（或新建 `docs/08-stage-2-kickoff.md`）汇总成一张表，并在 docs/07 §10 末尾链过去。

**D3 `appVersion` 双常量没有文档归属。** 代码里有两个：server `0.3.0-m21`（预览缓存 key，docs/04:131 只提这个）与 delivery `0.4.0-m4`（report `provenance`，docs/07:176 只说"the delivery build's appVersion"不写值）。为什么不同只在 `DeliveryReport.swift:150-152` 的注释里。读 `report.json` 的人从文档得不到答案 → 归到 AGENT 环境事实。

**D4 性能数据没回填到归属文档。** docs/03 §7 是性能的唯一归属，但里面最新的实测是 M2.1；M4 的交付实测（20.7 s 分解、5.8 MB/1.9 MB 产物、verify 占 ~76 %）只在 docs/07 §10，M5 的 AirDrop `<5 s` 是估计值。按归属规则应回流一行（数字留在 docs/07，docs/03 §7 指过去，或反之）。

**D5 入口缺"现在在哪、先读哪篇"。** README 的文档表只列内容，不列阅读顺序/当前阶段；7 篇 docs + 4 个 README 的入口是靠正文里的交叉引用撑起来的。

---

## 6. 建议的收尾动作（按可独立提交的顺序）

1. `docs(m5): correct the stage-1 result numbers` — A1–A7（约 7 处，纯数值/引用修正）。这组最该先做：它们是"文档 vs 产物"的唯一真实冲突。
2. `docs: fix broken links and numbering` — C1–C6（含 6 个 404 链接、3 处错 §、表补 3 行、头部编号统一）。
3. `docs: close the stage-1 bookkeeping` — B2/B5/B6/B7/B8/B9 + docs/05 归档横幅 + D3/D4 各一行。README 状态段改写为 3 句：stage 1 已关闭（→ docs/07 §10）· 产物在 `out/` · stage 2 未启动（→ docs/01 §2）。
4. **需你拍板**：(a) 是否提交 `evidence/` 文本快照（D1，~1.5 MB）；(b) 是否新建 stage-2 交接文档（D2）。这两项会改变仓库结构，我没有擅自做。

> 做完 1–3 后，文档体系就是"clone 下来能读懂、引用能点开、数字对得上产物"的状态；D1/D2 决定它能不能"clone 下来能复核"。
