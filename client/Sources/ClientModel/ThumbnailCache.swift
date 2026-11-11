import Foundation
import CoreGraphics
import ImageIO
import Observation
import UniformTypeIdentifiers
import ClientKit
import ContractKit

/// 胶片条缩略图：从服务端缩略图端点取 512 高的 HEIC，内存 + 磁盘两级缓存。
///
/// 源是内容寻址的（`ItemSummary.id` 就是源文件的 SHA-256），所以磁盘缓存不需要失效逻辑；
/// 文件名里带上渲染高度，改尺寸时自然读到新图。缩略图只是胶片条的显示数据，不参与判图，
/// 所以走 ImageIO 的缩略图路径，不碰 `BasePNG` 的线性化。
@MainActor
@Observable
public final class ThumbnailCache {
    /// 缩略图位图的高度上限（像素）。胶片条最高 240pt，2x 就是 480px。
    public nonisolated static let maxPixelHeight = 512

    /// 磁盘缓存的内容版本段。
    ///
    /// v1 的文件是从 preview base（2560 长边 16-bit PNG）缩出来的；现在的内容来自服务端
    /// `/thumbnail`（从源 TIFF 直接降采样）。key 一样但像素不同，所以文件名带上版本段，
    /// 让旧文件自然失效——否则升级后胶片条会继续显示旧缩略图。
    nonisolated static let cacheVersion = "v2"

    /// 已就绪的缩略图，按 item id。
    public private(set) var images: [String: CGImage] = [:]

    @ObservationIgnored
    private let directory: URL?

    @ObservationIgnored
    private let fileManager = FileManager.default

    /// - Parameter directory: 磁盘缓存目录；测试注入临时目录，app 用默认的 Caches。
    public init(directory: URL? = ThumbnailCache.defaultDirectory()) {
        self.directory = directory
    }

    public nonisolated static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appending(path: "thumbnails")
    }

    /// 按批次顺序串行补齐缩略图。取消由调用方的 `.task(id:)` 负责，这里只检查 `isCancelled`。
    public func prefetch(items: [ItemSummary], client: (any PhotonClientProtocol)?) async {
        for item in items {
            guard !Task.isCancelled else { return }
            // 失败项没有 preview 可下；等它恢复后 id 仍是 nil，会自然重试。
            guard images[item.id] == nil, item.state != .failed else { continue }
            if let cached = readFromDisk(item.id) {
                images[item.id] = cached
                continue
            }
            guard let client else { continue }
            // 一个 item 失败只是不显示缩略图（胶片条回落到文件名），不影响同批其他 item。
            guard let data = try? await client.thumbnailHEIC(itemID: item.id) else { continue }
            guard !Task.isCancelled else { return }
            guard let image = await Self.makeThumbnail(from: data) else { continue }
            images[item.id] = image
            writeToDisk(image, item.id)
        }
    }

    /// 清掉内存和磁盘缓存（调试用）。
    public func clear() {
        images = [:]
        guard let directory else { return }
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - 缩图

    /// 把服务端缩略图解码到显示尺寸。服务端已经缩到 512 高，所以这里通常只是解码；
    /// `maxPixelSize` 是兜底：输入比目标大时（或将来端点变大）ImageIO 在解码时降采样，
    /// 不会先解出全尺寸位图。输入格式不假定是 PNG——现在是 HEIC。
    nonisolated static func makeThumbnail(from data: Data) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0
            else { return nil }

            // maxPixelSize 卡的是长边：横图要按比例放大长边，高度才落在 512 上。
            let aspect = CGFloat(width) / CGFloat(height)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: ceil(CGFloat(maxPixelHeight) * max(1, aspect)),
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    // MARK: - 磁盘

    private func fileURL(_ id: String) -> URL? {
        directory?.appending(path: "\(id)-\(Self.maxPixelHeight)-\(Self.cacheVersion).png")
    }

    private func readFromDisk(_ id: String) -> CGImage? {
        guard let url = fileURL(id),
              fileManager.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func writeToDisk(_ image: CGImage, _ id: String) {
        guard let directory, let url = fileURL(id) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
