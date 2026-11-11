import SwiftUI

/// Photon 的视觉 token：值只写在这里，视图里不再出现裸数字。
///
/// 这一版只收**已经重复出现**的值，不发明尺度 —— 没有 4/8/12/16 这样的级数，只有按角色
/// 命名的常量。改成级数、以及底部两条 chrome 的留白要不要统一，都是设计决策，未拍板。
public enum PhotonSpacing {
    /// 底部 chrome 条（判图状态条、连接页状态条）的左右留白。
    public static let barHorizontal: CGFloat = 16
    /// 底部 chrome 条的上下留白。
    public static let barVertical: CGFloat = 6
    /// 面板容器（直方图底板、调整栏）的四周留白。
    public static let panel: CGFloat = 16
    /// 胶片条的四周留白。
    public static let filmstrip: CGFloat = 12
    /// 缩略图右下角提交状态点的外边距。
    public static let thumbnailBadge: CGFloat = 5
    /// 缩略图里文件名占位的文字内边距。
    public static let thumbnailPlaceholder: CGFloat = 4
    /// 连接页 notice 块的上下留白。
    public static let noticeVertical: CGFloat = 8
}

public enum PhotonRadius {
    /// 面板容器（直方图底板）。
    public static let panel: CGFloat = 12
    /// 缩略图圆角按高度取比例，但不小于这个值。
    public static let thumbnailMin: CGFloat = 4
    public static let thumbnailRatio: CGFloat = 0.06
}

public enum PhotonType {
    /// 底部 chrome 条。
    public static let chrome = Font.caption
    /// 缩略图里没有缩略图时的文件名。
    public static let thumbnailFallback = Font.caption2
    /// 空态文案。
    public static let emptyState = Font.callout
    /// 说明性小字：连接页 footer、notice、连接页状态条。
    public static let footnote = Font.footnote
}

public enum PhotonPalette {
    /// 底部 chrome 条的材质（状态条、胶片条、连接页状态条）。
    public static let chrome = AnyShapeStyle(.bar)
    /// 占位面：还没到图的缩略图格子、直方图底板。
    public static let placeholder = AnyShapeStyle(.quaternary)
    /// 画布背景第一档：跟系统深浅色走（黑/白）。
    public static let canvasExtreme = Color(uiColor: .systemBackground)
    /// 画布背景第二档：跟系统深浅色走（深灰/浅灰）。
    public static let canvasSubtle = Color(uiColor: .secondarySystemBackground)
    /// 画布背景第三档：18% 反射灰的 sRGB 值，固定不跟深浅色。
    public static let canvasNeutral = Color(white: 0.461)
}
