---
type: reference
owner: docs/ui
updated: 2026-11-08
---

# 按钮的按下、长按与双击判定

## 工具栏里不能用 `DragGesture` 测「按下」

工具栏 item 里的 `DragGesture(minimumDistance: 0)` 只有手指**移动**时才识别：按住不动没有 `onChanged`，松手时才补一次 down/up。实测（iOS 27.2 模拟器，iPad Pro 13"，window 级 `UITouch.timestamp` 做硬件基准）：

| 写法 | 按下回调延迟 |
|---|---|
| `Button` + `simultaneousGesture(DragGesture)` | 约 0.8s |
| `Button` + `highPriorityGesture(DragGesture)` | 约 0.75s |
| 普通 `Image` + `gesture(DragGesture)`（没有 Button） | 约 0.75s |
| `.onLongPressGesture(onPressingChanged:)` | 约 0.01s |
| `ButtonStyle.isPressed` | 约 0.01s |

不是 `Button` 的问题。两个后果都要治：按下预览慢；`held` 从晚到的起点算，长按会掉进短按分支。

## 现在的做法：按下用长按，释放用拖拽

```swift
Button {} label: { Image(systemName: icon) }
    .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity,
                        perform: {}) { pressing in
        if pressing { beginPress() }              // 只有「按下」用这里
    }
    .simultaneousGesture(
        DragGesture(minimumDistance: 0)
            .onEnded { endPress(at: $0.location) }, // 松手准时，且带释放点
        isEnabled: isEnabled
    )
```

- 按下只取 `onPressingChanged(true)`。
- 它的 `false` 不能当释放用：手指一移动 pressing 就结束（`maximumDistance: .infinity` 也挡不住）。
- 释放用同时挂的 `DragGesture.onEnded`：松手时准时，`location` 在按钮本地坐标，配 `.onGeometryChange` 取尺寸判断「拖出」。
- 手势被系统取消时可能永远收不到释放；`pressing` 卡住时在下一次按下先撤回预览再重新开始。
- 保留 `Button` 的系统外观 / 按压高亮 / disabled；action 留空，补 `.accessibilityAction(.default)` 走单点。`ButtonStyle.isPressed` 虽然也准时，但会换掉按钮样式，不用。

## 轻点 / 长按 / 双击共用一个按钮

- 不要用 `TapGesture` + `LongPressGesture` 组合做仲裁；判定放进一个显式状态机：按下时刻、释放时刻、这一串点击的起点（第一下之前的状态），释放时按「按住时长 + 距上次短按释放的间隔」一次决定。
- 双击目标按「第一下之前的状态」查表，不按第二下时的状态。乐观提交（松手立刻切），双击过程中的两次跳变可以接受。
- 用模式状态（A/B/C 这种）而不是几个布尔：预览 = 松手会落到的状态，松手不跳变；某个状态要压过其它规则时（假色里任何操作都回原样），把它的判断排在最前面。
- 状态从模型派生，只把按下状态和按下前的快照放 view-local（`@State`），不复制模型状态。

## 原生控件会吞掉外层手势

`Slider` 的滑块在 iOS 上由 `UISlider` 自己的手势识别器管，挂在 SwiftUI 层的 `simultaneousGesture` / `highPriorityGesture` **都收不到按在滑块上的触摸**（点在滑道上能收到）。所以「双击滑条复位」在滑块上永远不生效，`highPriorityGesture` 也救不回来，只会让单击跳值多等一个双击判定窗口。

- 参数复位改成双击**滚轮 popover**：wheel `Picker` 是 SwiftUI 自己的，`simultaneousGesture` 能收到。
- 遇到「手势在某个子区域不响应」，先怀疑那块是原生控件（`Slider`、`Picker`、`DatePicker`、`TextField`…），不要把时间花在换 gesture 修饰符上。

## 怎么量触摸时序

- `CACurrentMediaTime()` 和 `UITouch.timestamp` 是同一个时钟，可以直接相减。
- 在 window 上挂 `UILongPressGestureRecognizer`（`minimumPressDuration = 0`、`cancelsTouchesInView = false`）的子类，在 `touchesBegan` 里记 `UITouch.timestamp` 作为基准；SwiftUI 回调里记 `CACurrentMediaTime()`。
- 这类实验不要动正式 app：临时 demo app 把几种写法并排放进工具栏，模拟器 + 合成触摸（`t x y <hold>`）测完就删；启动模拟器需要用户同意（默认规则见 [AGENTS.md](../AGENTS.md)）。
- `#Preview` 只能验布局，验不了触摸时序（见 [previews.md](previews.md)）。
