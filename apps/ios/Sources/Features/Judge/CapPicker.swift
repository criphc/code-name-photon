import Foundation
import SwiftUI

/// HDR cap 控制：只显示 stops 数值，点击数字弹出滚轮；没有滑条。
///
/// - 配方里的 `hdr.headroom_cap` 是线性倍数（schema 1…8）；UI 只在 stops 域里编辑，
///   写回时再转成线性（docs/reference/client.md, control model）。
/// - 只提供 0.5/1/1.5/2/2.5/3 六档；3 st = 8× 是当前编码器验证过的交付上限。
/// - 默认 cap 是 `Recipe.HDR.defaultHeadroomCap`（2 st，在六档内）；服务端给非标准默认时打开
///   滚轮预选最近档，只有真的滚动了才写回，避免点开就悄悄改配方。
struct CapPicker: View {
    @Binding var value: Double
    var isEnabled: Bool = true
    /// 滚轮 popover 从打开到关闭算一次连续编辑，撤销历史靠它合并成一步。
    var onEditingChanged: (Bool) -> Void = { _ in }

    /// The stops the picker offers. 3.0 st = 8×, the encoder's verified delivery ceiling.
    static let allowedStops: [Double] = [0.5, 1, 1.5, 2, 2.5, 3]

    @State private var isPicking = false
    @State private var pickerStops: Double = 1.5

    var body: some View {
        HStack {
            Text("Cap")
            Spacer()
            valueButton
        }
        .disabled(!isEnabled)
        .onChange(of: isPicking) { _, picking in onEditingChanged(picking) }
    }

    private var valueButton: some View {
        valueText
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .contentShape(.rect)
            .onTapGesture(perform: beginPicking)
            .popover(isPresented: $isPicking) { wheel }
            .accessibilityElement()
            .accessibilityLabel("Cap")
            .accessibilityValue(valueText)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the stops picker")
            .accessibilityIdentifier("adjustments.cap")
            .accessibilityAction { beginPicking() }
    }

    private var wheel: some View {
        CapStopsWheel(stops: $pickerStops)
            .frame(width: 150)
            .onChange(of: pickerStops) { _, stops in value = exp2(stops) }
    }

    private var valueText: Text {
        Text("\(currentStops, format: .number.precision(.fractionLength(2))) stops")
    }

    /// The schema value shown in stops; `cap` is always >= 1 after validation.
    private var currentStops: Double { log2(max(value, 1)) }

    private func beginPicking() {
        pickerStops = Self.nearestStops(to: value)
        isPicking = true
    }

    /// The wheel only offers six values; a non-standard server default opens on the nearest one
    /// (the template default, `Recipe.HDR.defaultHeadroomCap` = 2 st, is itself one of the six).
    private static func nearestStops(to linearCap: Double) -> Double {
        let stops = log2(max(linearCap, 1))
        return allowedStops.min(by: { abs($0 - stops) < abs($1 - stops) }) ?? 1.5
    }
}

/// The wheel on its own, so `#Preview` can show it without opening a popover.
struct CapStopsWheel: View {
    @Binding var stops: Double

    var body: some View {
        Picker("Cap", selection: $stops) {
            ForEach(CapPicker.allowedStops, id: \.self) { value in
                Text("\(value, format: .number.precision(.fractionLength(1))) stops")
                    .tag(value)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
    }
}

#Preview("Cap picker") {
    @Previewable @State var cap = exp2(1.5)
    CapPicker(value: $cap)
        .padding()
        .frame(width: 320)
}

#Preview("Cap picker — disabled") {
    @Previewable @State var cap = exp2(1.5)
    CapPicker(value: $cap, isEnabled: false)
        .padding()
        .frame(width: 320)
}

#Preview("Cap wheel") {
    @Previewable @State var stops = 1.5
    CapStopsWheel(stops: $stops)
        .frame(width: 150)
        .padding()
}
