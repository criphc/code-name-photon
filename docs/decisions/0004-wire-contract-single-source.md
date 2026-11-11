---
type: decision
owner: docs
updated: 2026-11-05
---

# ADR-0004：wire 契约单一定义在 ContractKit/Wire，金样例随包

- 状态：已接受（2026-11-05，P0）
- 关联：[迁移目标结构](../plans/00-new-structure-description.md) R2、R4
- 影响阶段：P1（契约）、P2/P3（两端接入）

## 背景

stage 1 里 HTTP JSON 的 Codable 定义在 `app/Sources/PhotonServer/APIModels.swift`，iPad 侧在
`ipad/ClientKit/Wire/APIModels.swift` 有一份镜像。两边靠测试和人工同步；schema 0 能对上，但这是
最容易漂移的一处。新的 `contract/` 包已经在承载 recipe schema 与 mask/gain 数学，正好把 wire
也收进去。

## 决策

- HTTP JSON 的 **Codable 定义只存在于 `contract/Sources/ContractKit/Wire/`**。server 与 client 都
  `import ContractKit`，**禁止镜像文件**；删除两端现有的同名 DTO 副本。
- `contract/Tests/ContractKitTests/Fixtures/schema-0/` 是金样例的**唯一家**，作为 package
  resource 随包；server 与 client 的测试从 `Bundle.module` 或相对路径读同一份字节，跑
  「新 server 读旧 client 字节 / 新 client 读旧 server 字节」。
- 迁移期间 JSON 形状保持 **schema 0 不变**；队列新状态（rendered/encoded/verified 等）属于
  stage 2，届时单独定 schema 版本与兼容策略。
- `ContractKit/IPC` 只放 GUI↔CLI 的可序列化事件（ready/status），不放 HTTP 类型；进程的
  argv/env 契约由 `ServerControl` 定义（[ADR-0010](0010-appctl-process-contract.md)）。
- recipe schema 0 与 mask/gain 数学继续留在 `ContractKit`（原 `PhotonContract` 内容原样搬家，
  只改名）。

## 后果

- 任何 wire 形状变化都只改一处，两端同时可见；镜像文件消失。
- 金样例成为跨端兼容的回归门禁；P1 的验收是 contract 包测试 + 两端现有测试全绿。
- rule：server 与 client 的测试不得各自维护 fixture 副本。

## 备选与取舍

- **保留两端镜像 DTO**：改动小，但正是要消除的漂移源；拒绝。
- **把 wire 放进 server 包再让 client 依赖 server**：违反「iOS app 不链接 server 包」；拒绝。
- **金样例放 server 测试目录**：client 无法从 package 读到同一份；拒绝。

## 验证

P1：`contract` 的 `swift test` 全绿；server/client 现有测试在改用 `ContractKit` 后全绿；
金样例测试证明旧字节可被新代码读取。
