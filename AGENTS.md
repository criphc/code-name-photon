# AGENTS.md

本文件只写 agent 的工作规则与入口事实。项目简介见 `README.md`，当前状态见 `docs/status.md`，文档索引见 `docs/README.md`；各子项目的「不许破坏」与本地环境事实在各自的 `AGENTS.md`，按下面的路由表查。

## 命令

| 目的 | 命令 |
|---|---|
| 全部测试（contract + server + client） | `make test` |
| 集成测试（起真实 `appctl serve/deliver`） | `make integration` |
| shader parity（0 failure / 0 skip） | `make parity` |
| iOS 编译检查（普通终端/CI） | `make ios-build` |
| 合并门（DSH 内可跑） | `make check` |
| 合并门 + app 构建 | `make check-full` |
| 构建 CLI / 打印 help | `make appctl` / `make cli` |
| 合成测试图对 | `make fixtures` |
| 文档检查 / 死链修复 | `make docs-lint`（规则见 `tools/docs-lint.py`）/ `make docs-fix` |

- swift 调用一律带 `--disable-sandbox`；`TMPDIR` 与 clang module cache 在仓库内。
- 并行 agent：给每个构建独立的 scratch/cache，如 `make test SCRATCH=.build-mine TMP=$PWD/.tmp-mine MC=$PWD/.mc-mine`。

## 文档路由（按任务查）

| 我要改… | 先读 | 细节唯一来源 |
|---|---|---|
| wire / recipe 字段 | `contract/AGENTS.md` | `docs/reference/wire.md`、`docs/reference/recipe.md` |
| GUI↔CLI 进程契约 | `contract/AGENTS.md` | `docs/reference/ipc.md`、`docs/decisions/0010-appctl-process-contract.md` |
| 交付、report、8 项检查 | `server/AGENTS.md` | `docs/reference/deliver.md` |
| CLI 行为 | `server/AGENTS.md` | `docs/reference/cli.md` |
| 渲染 / 编码 / 验证实现 | `server/AGENTS.md` | `docs/reference/encoder.md`、`docs/reference/verification.md` |
| 客户端架构、状态、parity | `client/AGENTS.md` | `docs/reference/client.md` |
| iOS 屏幕与控件 | `apps/ios/AGENTS.md` | `docs/ui/spec/`（每块屏的区域/状态/控件/验收；不写数值） |
| UI 工作方式与踩坑 | `docs/ui/AGENTS.md` | `docs/ui/reference/`（布局、手势、预览、无障碍、token） |
| 视觉 token 与组件 | `design/Sources/Tokens/` | `design/Sources/Specimen`（值只在 Tokens；Components 先不建） |
| UI 设计顺序、进度与待决策 | `docs/ui/plan/v1-plan.md` | 同左 |
| 容器 / 色彩 / 运维规则 | — | `docs/reference/container.md`、`docs/reference/colour.md`、`docs/reference/operations.md` |
| 判图硬件与验收 | — | `docs/reference/hardware.md` |
| 性能数据 | — | `docs/reference/performance.md` |
| 验收工具 | `tools/AGENTS.md` | `docs/reference/verification.md`、`docs/reference/tools.md` |
| 当前做到哪 | `docs/status.md` | `docs/status.md` |
| 当前阶段计划 | `docs/plans/v2-plan.md` | v1/v2 均已收尾；下一阶段未定。 |
| 架构决策 | `docs/decisions/` | 同左 |

## 全局红线

- 改动前先读该任务对应的子项目 `AGENTS.md`：技术红线（编码器、容器、色彩、原子替换、report 门禁等）逐条在那里，细节在 `reference/`。
- **一个 diff 只做一件事**：不把不相关的改动混进同一提交（例如 UI 改动与 engine 改动分开）。

## 环境

- 开发机：macOS 27.2 / M1 Max / Xcode 27.2 / Swift 6.4；判图硬件：iPad Pro（M2，Liquid Retina XDR），iPadOS 27。Mac 内置 Studio Display 是 SDR-only，**不能**验证 HDR。
- 归档：`docs/archive/` 是冻结的历史文档与证据；**非必要不许阅读**，不要修改；新决策写进活文档。

## 工作规则

- 决策改变时，同一次改动里更新相关文档。`README.md` 和本文件保持简短——用户会经常手改。
- 不提交 `fixtures/media/`、`tools/toGainMapHDR/`，以及 `inbox/`、`work/`、`out/`、`cache/`、`docs/archive/stage-1/delivery/`。
- **一件事只详细写一次。** 详细内容只放在它的归属文档里（见路由表）；其他文档写一句加链接。发现重复时：先确定归属，把细节收敛到那里，其余改成引用，不要两边各写一遍。
- **测试只增不减是缺陷，不是勤勉。** 改行为时顺手检查：新用例是否让旧用例变得重叠？被更强用例覆盖的旧用例要**在同一个提交里删掉**，不要为"多几个 green"留着。判据是"这条规则有没有更强的地方在管"，不是用例数。
- **文档只增不减是缺陷。** 改动引入新细节时，同一个提交里必须删掉被它取代的段落。加进卡片的每一行，都要能回答"删掉它 agent 会做错什么"。叙事、动机、历史、未来计划不进卡片和 reference，只进 `docs/decisions`、`docs/plans`、`docs/archive`。
- **卡片的「布局」只写包/模块级地图，不写逐文件清单。** 文件级细节以源码为准；卡片变长会淹没「不许破坏」，`docs-lint` 对 > 40 行 warning、> 60 行报错。

### 与用户的协作方式

- 遇到不确定的事情尽快询问用户。多问问题是受欢迎的行为。
- 充分利用 git：一个阶段完成后立即提交；小改动直接提交到 `main`；较大改动先 `git switch -c <type>/<slug>`，验收通过后再合回。

### 智能体团队

- 主会话（Lead）负责设计：读文档、定方案、拆分任务、分配写作用域、最终 review 与提交。
- 子 agent 负责执行：按任务边界改代码/文档，自检后回报；写作用域互不重叠。
- 较大阶段用共享任务板跟踪：`write_scopes` 标预期写的文件，`blocked_by` 标依赖。
