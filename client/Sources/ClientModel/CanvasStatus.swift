import Foundation
import ContractKit

/// 状态条要显示的事实。纯数据，视图只负责排版。
public struct CanvasStatus: Equatable, Sendable {
    /// 预览尺寸，例如 `2560×1700（预览）`；没有图像时是 `No image` / `Loading…`。
    public var size: String?
    /// 预览色域，例如 `Display P3`。
    public var gamut: String?
    /// 预览位深，例如 `16-bit`。
    public var depth: String?
    /// 显示器当前 headroom 的 stops，保留一位小数向下取整，用来和调整栏的 cap 对照。
    /// 没有图像时是 nil：那时画布上没有 EDR 内容，屏幕报 1.0，读不出有意义的当前值。
    public var headroomStops: Double?

    public init(
        size: String? = nil,
        gamut: String? = nil,
        depth: String? = nil,
        headroomStops: Double? = nil
    ) {
        self.size = size
        self.gamut = gamut
        self.depth = depth
        self.headroomStops = headroomStops
    }

    /// 从 wire 的预览元数据 + 显示器 headroom 造一条状态。
    /// 没有图像时左边说清楚是「没有」还是「正在来」，右边留占位。
    public static func make(
        meta: PreviewMetadata?,
        displayHeadroom: Float,
        isLoading: Bool
    ) -> CanvasStatus {
        var status = CanvasStatus()
        guard let base = meta?.base else {
            status.size = isLoading ? "Loading…" : "No image"
            return status
        }
        // 保留一位小数向下取整：宁可少报，也不要让 cap 看起来比显示器现在能给的更多。
        // 用 Double 算：Float 里 14.0/10 落到 1.3999999，读出来就不是 1.4 了。
        let headroom = Double(max(1, displayHeadroom))
        status.headroomStops = floor(log2(headroom) * 10) / 10
        status.size = "\(base.width)×\(base.height)（预览）"
        status.gamut = base.profileName
        // `format` 是 `png-16-p3` 这类标签；位深从标签里取，不写死。
        let parts = base.format.split(separator: "-")
        if parts.count > 1, let bits = Int(parts[1]) {
            status.depth = "\(bits)-bit"
        }
        return status
    }
}
