import SwiftUI

/// 一个可编辑参数：滑条 + 点数值弹滚轮 + 双击滚轮复位。
///
/// `onEditingChanged` 把一次连续编辑括起来（拖动开始/结束、滚轮 popover 开关、双击复位），
/// 撤销历史靠它把「一次拖动 = 一步」合并起来。
struct ParamRow: View {
    let title: String
    /// UI 测试用的稳定标识；滑条是 `identifier`，点开滚轮的数值是 `identifier.value`。
    let identifier: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var isEnabled: Bool = true
    var onEditingChanged: (Bool) -> Void = { _ in }

    private let stepCount = 100

    @State private var isPicking = false
    @State private var pickerIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
                    .onTapGesture(perform: beginPicking)
                    .accessibilityElement()
                    .accessibilityLabel(title)
                    .accessibilityValue(Text(value, format: .number.precision(.fractionLength(2))))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the wheel picker")
                    .accessibilityIdentifier("\(identifier).value")
                    .accessibilityAction { beginPicking() }
                    .popover(isPresented: $isPicking) {
                        // popover 里只放滚轮：多一行按钮会把滚轮顶离中心，
                        // 箭头（锚点行的垂直中心）就和选中行错开了。
                        Picker(title, selection: $pickerIndex) {
                            ForEach(0...stepCount, id: \.self) { index in
                                Text(value(at: index), format: .number.precision(.fractionLength(2)))
                                    .tag(index)
                            }
                        }
                        .pickerStyle(.wheel)
                        .labelsHidden()
                        .frame(width: 110)
                        .onChange(of: pickerIndex) { _, index in value = value(at: index) }
                        // 双击滚轮复位。滑条上的双击收不到（滑块被原生控件吞掉），滚轮是 SwiftUI 自己的。
                        .simultaneousGesture(TapGesture(count: 2).onEnded(applyDefault))
                    }
            }
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .accessibilityLabel(title)
                .accessibilityValue(Text(value, format: .number.precision(.fractionLength(2))))
                .accessibilityIdentifier(identifier)
        }
        .disabled(!isEnabled)
        .onChange(of: isPicking) { _, picking in
            // 打开时已经在 beginPicking 里报过了；这里只收尾。
            if !picking { onEditingChanged(false) }
        }
    }

    private func beginPicking() {
        // 先报开始，再定位滚轮：否则定位那一下会被算进这一步里。
        onEditingChanged(true)
        pickerIndex = index(for: value)
        isPicking = true
    }

    /// 双击滚轮复位：滚轮滚回默认档，值写回默认。popover 不关，滚轮动一下就是反馈。
    private func applyDefault() {
        pickerIndex = index(for: defaultValue)
        value = defaultValue
    }

    private var stepSize: Double {
        (range.upperBound - range.lowerBound) / Double(stepCount)
    }

    private func value(at index: Int) -> Double {
        range.lowerBound + Double(index) * stepSize
    }

    private func index(for value: Double) -> Int {
        Int(((value - range.lowerBound) / stepSize).rounded())
    }
}

#Preview {
    @Previewable @State var value = 0.62
    ParamRow(title: "Start", identifier: "adjustments.start",
             value: $value, range: 0...1, defaultValue: 0.62)
        .padding()
        .frame(width: 320)
}
