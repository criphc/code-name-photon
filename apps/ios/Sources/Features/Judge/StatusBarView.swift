import SwiftUI
import UIKit
import Tokens
import ClientModel
import ContractKit

/// 画布列底部的状态条：左边是预览的基本信息，右边是显示器当前能给的 headroom（stops）。
struct StatusBarView: View {
    let status: CanvasStatus

    var body: some View {
        HStack(spacing: 12) {
            Text(facts)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("status.facts")
            Spacer(minLength: 0)
            Label(stopsText, systemImage: "display")
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .accessibilityLabel("Display headroom")
                .accessibilityValue(headroomDescription)
                .accessibilityIdentifier("status.headroom")
        }
        .font(PhotonType.chrome)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, PhotonSpacing.barHorizontal)
        .padding(.vertical, PhotonSpacing.barVertical)
        // 和胶片条同材质，两块连成一个 chrome 块；`.safeAreaBar` 自己不画底。
        .background(PhotonPalette.chrome)
    }

    private var facts: String {
        [status.size, status.gamut, status.depth]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// VoiceOver 读的是「显示器能给多少」，不是 `@ 2.0 Stops` 那串符号。
    private var headroomDescription: String {
        guard let stops = status.headroomStops else { return "not available" }
        return String(format: "%.1f stops", stops)
    }

    private var stopsText: String {
        guard let stops = status.headroomStops else { return "@ — Stops" }
        return String(format: "@ %.1f Stops", stops)
    }
}

/// 三种状态并排：有图 / 加载中 / 没有图。右边始终是显示器事实。
private func specimen(_ status: CanvasStatus) -> some View {
    VStack(spacing: 0) {
        Color(uiColor: .systemBackground)
            .safeAreaBar(edge: .bottom) {
                StatusBarView(status: status)
            }
        Color(uiColor: .secondarySystemBackground).frame(height: 40)
    }
}

#Preview("Status bar") {
    VStack(spacing: 0) {
        specimen(CanvasStatus(size: "2560×1700（预览）", gamut: "Display P3",
                              depth: "16-bit", headroomStops: 2))
        specimen(CanvasStatus(size: "Loading…", headroomStops: nil))
        specimen(CanvasStatus(size: "No image", headroomStops: nil))
    }
}
