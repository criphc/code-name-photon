---
type: reference
owner: docs/ui
updated: 2026-11-10
---

# 接 `SessionModel` / `JudgeModel`

## 模型在 App 层创建

```swift
@main
struct PhotonClientApp: App {
    @State private var session: SessionModel
    @State private var judge: JudgeModel

    init() {
        let session = SessionModel()
        _session = State(initialValue: session)
        _judge = State(initialValue: JudgeModel(session: session))
    }
}
```

- 两个模型都是 `@MainActor @Observable`；在 `App.init()` 里建好再注入，不要在各个视图里各建一份。
- `WindowGroup` 里用 `.task { await session.start() }` 做启动自动重连（有保存过的 host/token 才会连）。
- 需要双向绑定的视图用 `@Bindable var session: SessionModel`，才能写 `$session.host`。

## 传模型还是传值

- **屏幕级视图**（`DevelopView`、`ConnectionSetupView`）直接持有模型，在 `body` 里读属性——这样 `@Observable` 才能建立依赖、自动刷新。
- **叶子视图**（胶片条、直方图、参数行）只收纯数据和回调（`items`、`selectedID`、`onSelect`）。好处是预览可以注入假数据，不必造模型。
- 读模型属性的位置要在 `body` 里（或 body 调用的计算属性里），否则不会触发刷新。

## 选中与编辑

- `judge.selectedItemID` 是**唯一真值**：`select()` 一开始就设置它，review 还没加载完也有值。不要再在视图里维护一份 `selectedID`，会不同步。
- `judge.review` 在加载完成前是 `nil`；`judge.draft` 因此也是 `nil`。占位/禁用态都按 `nil` 判断，不要自己造「loading」状态。
- 参数编辑只走 `judge.setStart(_:)` / `setLiftStops(_:)` / `setTransition(_:)` / `setHeadroomCap(_:)`；范围与默认值来自 `RecipeDraft.*Range`，不要另写一份常量。
- `draft.headroomCap` 是 schema 的线性值（1…8）；cap picker 只在 stops 域里编辑（0.5–3 六档，转换在 `CapPicker` 里做），没有 slider。

## 反馈

- `judge.activeNotice` 是 judge 自己的 notice 加上 session 的（刷新失败等）。用 `.onChange(of:)` 收进本地 alert 状态，`OK` 时 `judge.dismissNotice()`。
- 多个 `.alert` 挂在同一个视图上会互相覆盖：用一个带 `Identifiable` 的本地枚举统一（notice / posted）。
- `postedMessage` 只在「提交成功且草稿没再改」时非空；`editedMessage` 是草稿改过之后的中性提示。
- 提交按钮的可用条件是 `judge.canPost`，`judge.phase == .posting` 时显示 spinner。

## view-local state 的边界

可以放视图里的：栏宽、胶片条高度、inspector 显隐、alert 当前项、预览用的临时输入。

不能放视图里的：选中项、草稿参数、提交状态、连接设置——这些已经是模型状态，复制一份必然不同步。

撤销历史（`EditHistory`）住在 `ClientModel` 里，不在视图里——它没有一行 UI 框架依赖，放包里才能在 Mac 上跑测试。它存的是草稿**快照**，不是第二份草稿；应用一步时通过 `judge.setStart` 等写回模型。它是一条全局时间线，编辑和切换图片都算一步，所以撤销能跨图片回退——切换必须在 `DevelopView.select` 这一个入口记录，模型内部的自动切换（409 重判、reset）不记。第一次选中（`from == nil`）不记：撤销它等于要求「取消选中」，模型没有这个动作。

## 显示器 headroom 只能轮询

`displayHeadroom` 没有变更通知。`DevelopView` 用 1 秒的 `.task` 循环读 `UIWindowScene.screen.currentEDRHeadroom`，写回 `judge.updateHeadroom(current:)`；`UIScreen.main` 已废弃，从 `UIApplication.shared.connectedScenes` 里取窗口场景。它同时是画布 uniform 和状态条的输入。两个 headroom 属性的区别见 [canvas.md](canvas.md)。

## 缩略图缓存

- 由视图驱动：`DevelopView` 的 `.task(id: session.items)` 调 `prefetch`，批次变了自动取消重来；会话本身不主动下载。
- 源、两级缓存与内容寻址 key 的设计归 [client.md](../../reference/client.md)（缩略图是显示数据，不走 `BasePNG` 的线性化路径）。

## 常见错误

- 在 `onChange` 里调 `connect()` / `select()` 但忘了 `Task { await ... }`：模型方法是 `async`，静默不执行。
- 把 `LinearImage`、`Review` 这类大对象拷进 `@State`：只为渲染而持有像素时，让它留在模型里，视图只取需要的那一份。
- 用一个布尔值模拟「正在连接」：`session.phase` / `judge.phase` 已经表达了这个状态机。
