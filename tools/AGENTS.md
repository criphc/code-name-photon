---
type: agent
owner: tools
updated: 2026-11-10
---

# tools

三套非产品工具：`verify-heic`（ImageIO 容器验证）、`visual-check`（LAN 判图页）、`make-fixtures`（合成图对生成器）。不改产品行为。

## 命令

| 目的 | 命令 |
|---|---|
| 构建验证器 | `tools/verify-heic/build.sh` |
| 起判图页 | `python3 tools/visual-check/serve.py --root out/` |
| 生成合成图对 | `make fixtures`（产物在 `work/fixtures/`） |
| 文档检查 / 死链修复 | `make docs-lint` / `make docs-fix` |

## 不许破坏

- `verify-heic` 的 JSON report schema 保持稳定（验收靠它交叉核对）；它只做 ImageIO 断言，不改写文件。
- 合成图对必须是 4 通道 `RGBAf` float TIFF；3 通道会被 ImageIO 静默误读。
- `visual-check` 只展示、不解码/不改写 gain map；LAN only，never expose。
- `toGainMapHDR/` 是外部 MIT clone，不被本仓库跟踪；v2 起只是本地 differential oracle，不参与 `make test`。

## 环境

- `verify-heic`：`swiftc` + macOS SDK，无 SwiftPM 依赖；构建缓存留本地。
- `visual-check`：Python 3 标准库；iPad Safari 26+。
- `make-fixtures`：`swift` 直接跑脚本，无需 SwiftPM。

## 去哪看

- 验证项 / report / ImageIO 观察 → `../docs/reference/verification.md`
- 查看器与合成图对 → `../docs/reference/tools.md`
