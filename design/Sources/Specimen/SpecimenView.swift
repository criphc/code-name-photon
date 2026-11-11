import SwiftUI
import Tokens

/// Token 的样张：把 `Tokens` 里的值按类别摊开，用来看和比较。
///
/// 这里**只读** token，不定义任何值，也不放组件 —— 组件等 2–3 屏收敛后再从界面里反向提取。
struct SpecimenView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PhotonSpacing.panel) {
                spacingSection
                radiusSection
                typeSection
                paletteSection
            }
            .padding(PhotonSpacing.panel)
        }
    }

    // MARK: - 间距

    private var spacingSection: some View {
        section("Spacing") {
            row("barHorizontal", PhotonSpacing.barHorizontal)
            row("barVertical", PhotonSpacing.barVertical)
            row("panel", PhotonSpacing.panel)
            row("filmstrip", PhotonSpacing.filmstrip)
            row("thumbnailBadge", PhotonSpacing.thumbnailBadge)
            row("thumbnailPlaceholder", PhotonSpacing.thumbnailPlaceholder)
            row("noticeVertical", PhotonSpacing.noticeVertical)
        }
    }

    private func row(_ name: String, _ value: CGFloat) -> some View {
        HStack(spacing: 12) {
            Text(name)
                .font(.caption.monospaced())
                .frame(width: 160, alignment: .leading)
            Rectangle()
                .fill(.tint)
                .frame(width: value, height: 12)
            Text("\(value, format: .number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 圆角

    private var radiusSection: some View {
        section("Radius") {
            HStack(spacing: PhotonSpacing.panel) {
                radiusSample("panel", PhotonRadius.panel)
                radiusSample("thumbnailMin", PhotonRadius.thumbnailMin)
            }
            HStack(spacing: 12) {
                Text("thumbnailRatio")
                    .font(.caption.monospaced())
                Text("\(PhotonRadius.thumbnailRatio, format: .number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func radiusSample(_ name: String, _ radius: CGFloat) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: radius)
                .fill(PhotonPalette.placeholder)
                .frame(width: 88, height: 56)
            Text("\(name) · \(radius, format: .number)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 字号

    private var typeSection: some View {
        section("Type") {
            Text("chrome — 状态条").font(PhotonType.chrome)
            Text("thumbnailFallback — 缩略图里的文件名").font(PhotonType.thumbnailFallback)
            Text("emptyState — 空批次").font(PhotonType.emptyState)
            Text("footnote — 连接页 footer / notice").font(PhotonType.footnote)
        }
    }

    // MARK: - 颜色与材质

    private var paletteSection: some View {
        section("Palette") {
            HStack(spacing: PhotonSpacing.panel) {
                swatch("canvasExtreme", PhotonPalette.canvasExtreme)
                swatch("canvasSubtle", PhotonPalette.canvasSubtle)
                swatch("canvasNeutral", PhotonPalette.canvasNeutral)
            }
            HStack(spacing: PhotonSpacing.panel) {
                materialSwatch("chrome", PhotonPalette.chrome)
                materialSwatch("placeholder", PhotonPalette.placeholder)
            }
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: PhotonRadius.panel)
                .fill(color)
                .frame(width: 88, height: 56)
                .overlay {
                    RoundedRectangle(cornerRadius: PhotonRadius.panel)
                        .strokeBorder(.separator)
                }
            Text(name)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private func materialSwatch(_ name: String, _ style: AnyShapeStyle) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: PhotonRadius.panel)
                .fill(style)
                .frame(width: 88, height: 56)
                .overlay {
                    RoundedRectangle(cornerRadius: PhotonRadius.panel)
                        .strokeBorder(.separator)
                }
            Text(name)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 版式

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}

#Preview("Specimen · light") {
    SpecimenView()
        .frame(width: 520, height: 900)
}

#Preview("Specimen · dark") {
    SpecimenView()
        .frame(width: 520, height: 900)
        .preferredColorScheme(.dark)
}
