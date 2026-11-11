import SwiftUI
import Tokens
import ContractKit

/// 胶片条：缩略图 + 选中框 + 提交状态点；顶部 16pt 隐形区域可拖动改高度。
struct FilmstripView: View {
    let items: [ItemSummary]
    let thumbnails: [String: CGImage]
    let selectedID: String?
    let postingID: String?
    @Binding var height: CGFloat
    let onSelect: (String) -> Void

    @State private var dragStart: CGFloat?

    private let minHeight: CGFloat = 96
    private let maxHeight: CGFloat = 240

    var body: some View {
        Group {
            if items.isEmpty {
                Label("No items", systemImage: "photo.on.rectangle")
                    .font(PhotonType.emptyState)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("filmstrip.empty")
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(items) { item in
                            ThumbnailCell(item: item,
                                          state: state(for: item),
                                          thumbnail: thumbnails[item.id],
                                          height: height - 24,
                                          isSelected: item.id == selectedID)
                                .onTapGesture { onSelect(item.id) }
                        }
                    }
                    .padding(.horizontal, PhotonSpacing.filmstrip)
                    .padding(.vertical, PhotonSpacing.filmstrip)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(height: height)
        .background(PhotonPalette.chrome)
        .accessibilityIdentifier("filmstrip")
        .overlay(alignment: .top) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 16)
                .contentShape(.rect)
                .gesture(
                    DragGesture(coordinateSpace: .global)
                        .onChanged { value in
                            let start = dragStart ?? height
                            dragStart = start
                            height = min(max(start - value.translation.height, minHeight), maxHeight)
                                .rounded()
                        }
                        .onEnded { _ in dragStart = nil }
                )
        }
    }

    /// 提交状态来自 wire 的 item，加上当前 POST 的瞬时状态。
    private func state(for item: ItemSummary) -> ThumbnailCell.SubmitState {
        if item.state == .failed { return .failed }
        if item.id == postingID { return .posting }
        return item.hasRecipe ? .posted : .unposted
    }
}

struct ThumbnailCell: View {
    enum SubmitState {
        case posted
        case unposted
        case posting
        case failed
    }

    let item: ItemSummary
    let state: SubmitState
    let thumbnail: CGImage?
    let height: CGFloat
    let isSelected: Bool

    private var radius: CGFloat { max(PhotonRadius.thumbnailMin, height * PhotonRadius.thumbnailRatio) }

    /// 源图比例：缩略图到位后用它自己的，否则用 wire 上的像素尺寸，都没有时按 3:2 占位。
    private var aspect: CGFloat {
        if let thumbnail, thumbnail.height > 0 {
            return CGFloat(thumbnail.width) / CGFloat(thumbnail.height)
        }
        if let width = item.width, let height = item.height, height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        return 3.0 / 2.0
    }

    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(PhotonPalette.placeholder)
            .frame(width: height * aspect, height: height)
            .overlay {
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // 缩略图还没到：先用文件名占位，格子尺寸已经按源图比例留好了。
                    Text(item.name)
                        .font(PhotonType.thumbnailFallback)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(PhotonSpacing.thumbnailPlaceholder)
                }
            }
            .clipShape(.rect(cornerRadius: radius))
            .overlay(alignment: .bottomTrailing) {
                status
                    .padding(PhotonSpacing.thumbnailBadge)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                                  lineWidth: 2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.name)
            .accessibilityValue(stateDescription)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("filmstrip.cell.\(item.id)")
    }

    private var stateDescription: String {
        switch state {
        case .posted: "Recipe sent"
        case .unposted: "Not sent"
        case .posting: "Sending"
        case .failed: "Failed"
        }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .posted:
            Circle().fill(.green).frame(width: 8, height: 8)
        case .unposted:
            Circle().strokeBorder(.secondary, lineWidth: 1.5).frame(width: 8, height: 8)
        case .posting:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Circle().fill(.red).frame(width: 8, height: 8)
        }
    }
}

// MARK: - Preview

private func sampleImage(_ width: Int, _ height: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setFillColor(CGColor(red: 0.20, green: 0.42, blue: 0.78, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.95, green: 0.72, blue: 0.25, alpha: 1))
    context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    return context.makeImage()
}

private func sampleThumbnails() -> [String: CGImage] {
    var result: [String: CGImage] = [:]
    for (id, size) in [("0", (300, 200)), ("1", (200, 300)), ("4", (320, 180))] {
        if let image = sampleImage(size.0, size.1) { result[id] = image }
    }
    return result
}

#Preview("Filmstrip") {
    @Previewable @State var height: CGFloat = 160
    FilmstripView(items: [
        ItemSummary(id: "0", name: "IMG_4821.HEIC", path: "/b/IMG_4821.HEIC", state: .previewReady, previewReady: true, hasRecipe: true),
        ItemSummary(id: "1", name: "IMG_4822.HEIC", path: "/b/IMG_4822.HEIC", state: .previewReady, previewReady: true, hasRecipe: false),
        ItemSummary(id: "2", name: "IMG_4823.HEIC", path: "/b/IMG_4823.HEIC", state: .pending, previewReady: false, hasRecipe: false),
        ItemSummary(id: "3", name: "IMG_4824.HEIC", path: "/b/IMG_4824.HEIC", state: .failed, previewReady: false, hasRecipe: false, error: "prepare failed"),
        ItemSummary(id: "4", name: "IMG_4825.HEIC", path: "/b/IMG_4825.HEIC", state: .recipeReceived, previewReady: true, hasRecipe: true),
    ], thumbnails: sampleThumbnails(), selectedID: "1", postingID: "2", height: $height, onSelect: { _ in })
    .frame(width: 620)
}

#Preview("Filmstrip · empty") {
    @Previewable @State var height: CGFloat = 160
    FilmstripView(items: [], thumbnails: [:], selectedID: nil, postingID: nil,
                  height: $height, onSelect: { _ in })
    .frame(width: 620)
}
