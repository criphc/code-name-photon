# AGENT.md

本文件只写 agent 的工作规则与环境事实；项目简介见 `README.md`，设计文档见 `docs/`。

## 阶段状态

- **stage 1（原型：一张照片端到端）已于 2026-11-03 关闭。** 交付证据、里程碑计划与验收记录归档在 `docs/archive/stage-1/`。归档是**历史记录，不是必读**——只在追查"某条规则为什么存在、证据在哪"时才看，引用时写明是历史。
- **stage 2（批量、易用性、性能）尚未开始**：目标见 `docs/01` §2，起步清单与已知缺口见 `docs/09-stage-2-handoff.md`。

## 文档

1. `docs/01-app-concept-and-three-stages.md` —— 应用是什么、三个阶段边界、产品级决策。
2. `docs/02-hdr-highlight-finisher-workflow.md` —— 面向使用者的快速指南（stage 2 的目标形态；不写实现）。
3. `docs/08-technical-reference.md` —— 仍然生效的技术规则：HDR 容器方言、投递/查看器陷阱、编码器、色彩、容器验证、运维、性能、硬件。
4. `docs/09-stage-2-handoff.md` —— stage-2 交接：现在有什么、验收基线、已知缺口与待办。

契约放在代码旁边、一项内容只写一次：`server/README.md`（M2.1 线协议 + `appctl deliver` 交付契约 + report schema 0）、`contract/README.md`（recipe schema 0 + mask/gain 数学 + wire + IPC）、`client/README.md`（客户端架构、控件语义、设备事实）。

## 不可违反的约定

- 遇到不确定的事情尽快询问用户。多问问题是受欢迎的行为。
- Capture One 的 SDR 导出是权威图像；工具只增加高光亮度，绝不重新调色/重新 tone-map SDR 底图。
- **只接受 Display P3 源。** 非 P3（Adobe RGB / sRGB / 无 profile）在 decode 阶段抛 `PhotonError.unsupportedSource` 报错（HTTP 422 `source_unreadable`），不允许静默 clamp 破坏权威底图；原因见 `docs/08` §4。
- 交付目标是 Apple 设备（照片 App + Safari）的 gain-map HEIC（ISO 21496-1）；SDR 回退必须单独成立。
- 不要自己写 HEIF 容器写入器：`tools/toGainMapHDR -b` 已经完成 base+HDR → gain-map HEIC；`-H` 永不使用，`-R` 在 `-b` 下无效（`docs/08` §3）。
- 判断 HDR 只用 ImageIO（`tools/verify-heic`）；不要用 `sips`、Finder 或导出命令判断——它们会静默丢掉 gain map（`docs/08` §2/§5）。
- 编码器的 `exit 0` 不是成功：authored peak 必须 ≥ 1.05，否则拒绝编码；产物必须用 ImageIO 回读验证（ISO aux / `contentHeadroom` ±5% / 无 alpha）后才允许替换 `preview.heic`（`EncodedHEICValidator`，详见 `server/README.md` 的交付契约）。
- 可替换的产物一律用 `AtomicFile`（同目录 temp + POSIX `rename(2)`）落盘；不要 remove+move——两步之间目标文件不存在（`docs/08` §6）。
- 交付报告（`{stem}.report.json`，schema 0）是唯一门禁：8 项命名检查全部 PASS 才允许把四个交付文件装进 `--out`；任一 FAIL 或无法评估即整体不安装，诊断留在 `work/<sha>/rejected/<renderKey12>/`。报告的 `pass`/`failures` 必须由 checks 推导（读回时也重新推导），不能手写（见 `server/README.md` 的 report 一节）。
- `baseDeltaE` 区分两种比较：16-bit 渲染底图 vs Capture One 导出是"渲染目标"（bit-exact，mean ΔE2000 < 1 / p95 < 2）；HEIC 里解码出的 8-bit 底图是"容器规则"（mean ≤ 2.5 / p95 ≤ 6.0，因为 4:2:0 HEVC 重编码），两者不可混用（见 `server/README.md` 的 report 一节）。

## 协作方式

### 版本控制（Git）

- 每次提交只做一件事。小改动直接提交到 `main`；较大改动先 `git switch -c <type>/<slug>`，验收通过后再 `git switch main` 合并。
- 不改写已提交的历史，不 force push。

### 智能体团队

- 主会话（Lead）负责设计：读文档、定方案、拆分任务、分配写作用域、最终 review 与提交。
- 子 agent 负责执行：按任务边界改代码/文档，自检后回报；写作用域互不重叠，同一文件由 Lead 串行安排。
- 较大阶段用共享任务板跟踪：`write_scopes` 标预期写的文件，`blocked_by` 标依赖。

## 环境

- macOS 27.2 / M1 Max / Xcode 27.2 / Swift 6.4；iPad Pro（M2，Liquid Retina XDR），iPadOS 27。Mac 屏幕（Studio Display）是 SDR-only，**不能**验证 HDR（`docs/08` §8）。
- 编码器：`tools/toGainMapHDR/bin/toGainMapHDR`（独立 MIT clone，不被本仓库跟踪）。**干净 clone 里跑 `make test` 前先执行** `git clone https://github.com/chemharuka/toGainMapHDR.git tools/toGainMapHDR`。编码器集成测试（`EncoderTests`、`DeterminismTests`）在编码器缺失时明确失败（XCTFail），。
- 验证器：`tools/verify-heic/`（`build.sh` 构建，ImageIO 断言 ISO aux / headroom / alpha / 基图漂移），用法与检查项见其 README。
- 共享契约：`contract/`（SwiftPM 包 `ContractKit`，无 I/O）是 recipe schema/校验、mask/gain 数学、Rec.709 luma、工作缓冲类型、HTTP wire 负载（`ContractKit/Wire`）与 appctl→GUI IPC 事件（`ContractKit/IPC`）的唯一定义；`server` 与 `client` 两个包以 path dependency 链接它，`apps/ios` 通过 SwiftPM product 链接同一份定义。字段表、wire/IPC 与金样例见 `contract/README.md`。
- iPad 端：`apps/ios/iOS.xcodeproj`（target `PhotonClient`，bundle id `com.criphc.Photon.Client`）+ `client/` 包测试（`swift test`，macOS host）。本机在 P0 已装 iOS 27.2 simulator runtime；agent 内 app 构建用 Xcode MCP，根 `make ios-build` 供普通终端/CI；设备 UDID `00008112-001E055E3EF0C01E`。
- 验收基线（只认"全绿 + 0 skip"，不认用例数）：根 `make test` 必须全绿（contract + server + client）；`make parity` 必须 0 failure、0 skip（`make parity` 自带 `PHOTON_TRIAL_BASE_PARITY=1`，普通 `make client-test` 把 trial-base 用例留成 opt-in，因此默认有且只有 1 个预期 skip）。用例数会随修剪双向移动，不是指标。`make parity` 与 `BasePNGTests` 的试机夹具是本机文件 `work/m21-final/preview-base.png`、`work/m21-final/meta.json`（缺失时测试 skip，见 `docs/09` §2）。
- Mac 端管线：`server/`（SwiftPM：`EngineKit` 库 + `ServerKit` + `ServerControl` + `appctl` CLI）。根 `make test` / `make integration` / `make appctl` 是入口；直接 `swift test` 需 `cd server` 并用 `--disable-sandbox` + 本地 `TMPDIR`/clang module cache（并行 agent 可用 `SCRATCH=… TMP=… MC=…` 分开构建目录）。CLI 与默认值、M2.1 服务行为、readiness 与 deliver 行为见 `server/README.md`；`make cli` 打印 `appctl --help`。
- 合成测试图对：`tools/m0-fixtures/make-pair.swift`（4.0 linear 已知峰值），用于编码器断言。
- 视觉验收工具：`tools/visual-check/`（`serve.py --root <交付目录>`。只是展示工具，不是产品代码，用法见其 README。
- Core Image 的 `CIImage(bitmapData:)` 不拥有 buffer：必须用 CGImage/provider-backed 的图，或让 buffer 活到整个滤镜链结束（症状与正确 bitmapInfo 见 `docs/08` §3）。
- 容器的真相以 ImageIO（`kCGImageSourceDecodeToHDR`）为准；检查工具与用法见 `docs/08` §5。
- `fixtures/media/`（gitignored）：`sources/` = 每张素材各有 Adobe RGB 与 P3 两份 Capture One 16-bit 导出；`reference/` = iPhone HDR 图片做观感参考。
- 归档：`docs/archive/stage-1/`（五份 stage-1 文档 + `evidence/` 文本证据 + `delivery/` 四个交付产物，后者不入库）。**归档非必要不许阅读**。不要修改归档文档，新决策写进活文档。

## 文档归属（一项内容只在一处写详细）

| 文档 | 唯一负责的内容 |
|---|---|
| `docs/01-app-concept-and-three-stages.md` | 产品概念、阶段边界、范围、stage-1 DoD（历史）、stage-2/3 目标、产品级决策 |
| `docs/02-hdr-highlight-finisher-workflow.md` | 用户使用体验（stage 2 的目标形态；不写实现） |
| `docs/08-technical-reference.md` | 技术规则：容器方言、投递/查看器陷阱、编码器、色彩、容器验证、运维、性能、硬件 |
| `docs/09-stage-2-handoff.md` | stage-2 交接：现状、验收基线、已知缺口/待办、要重新打开的决定 |
| `server/README.md` | Mac 端构建/测试、CLI、代码布局；**M2.1 线协议、`appctl deliver` 交付契约、report schema 0 与 8 项检查** |
| `contract/README.md` | recipe schema 0 字段契约、mask/gain 数学、校验与 `renderKey()`（两端共享契约的唯一定义） |
| `client/README.md` | client 包与 apps/ios：目录、build/test/device 命令、Xcode 与沙箱环境事实；**客户端架构、控件语义、状态/错误、parity gate、设备事实** |
| `tools/verify-heic/README.md` | 独立容器验证器的检查项与用法 |
| `tools/visual-check/README.md` | 交付验收页面的用法 |
| `tools/m0-fixtures/README.md` | 合成测试图对生成器 |
| `README.md` | 入口：是什么、目录、环境 |
| `AGENT.md` | 规则、环境事实、不可违反的约定 |

## 工作规则

- 决策改变时，同一次改动里更新相关文档。`README.md` 和本文件保持简短——用户会经常手改。
- 不提交 `fixtures/media/`、`tools/toGainMapHDR/`，以及 `inbox/`、`work/`、`out/`、`cache/`、`docs/archive/stage-1/delivery/`。
- **一件事只详细写一次。** 详细内容只放在它的归属文档里（见上表）；其他文档写一句加链接。发现重复时：先确定归属，把细节收敛到那里，其余地方改成引用，不要两边各写一遍。
- **测试只增不减是缺陷，不是勤勉。** 改行为时顺手检查：新用例是否让旧用例变得重叠？被更强用例覆盖的旧用例要**在同一个提交里删掉**，不要为"多几个 green"留着。判据是"这条规则有没有更强的地方在管"，不是用例数。同一交付里同时出现"新增测试"和"删除测试"是正常的好提交。
- 小步提交，不扩范围。
