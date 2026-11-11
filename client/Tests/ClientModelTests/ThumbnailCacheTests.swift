import CoreGraphics
import Foundation
import ClientKit
import Testing
@testable import ClientModel

@MainActor
@Suite("Thumbnail cache")
struct ThumbnailCacheTests {
    /// 每个用例一个临时目录，不碰真的 Caches。
    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "photonthumbs-\(UUID().uuidString)")
    }

    /// 端点返回的字节：`makeThumbnail` 走 ImageIO，格式无关，所以用 PNG 当替身。
    private func thumbnailBytes(width: Int, height: Int) throws -> Data {
        try Fixtures.makePNGData(width: width, height: height)
    }

    @Test("prefetch fills every item from the thumbnail endpoint, never the preview base")
    func prefetchFills() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try thumbnailBytes(width: 8, height: 6)
        let client = FakePhotonClient(thumbnail: { _ in bytes })
        let cache = ThumbnailCache(directory: directory)

        await cache.prefetch(items: [Fixtures.itemA, Fixtures.itemB], client: client)

        #expect(cache.images.count == 2)
        #expect(client.callCount(.thumbnail(Fixtures.idA)) == 1)
        #expect(client.callCount(.thumbnail(Fixtures.idB)) == 1)
        // 胶片条不再拉 preview base（ADR-0013）：浏览不触发 prepare。
        #expect(client.callCount(.preview(Fixtures.idA)) == 0)
        #expect(client.callCount(.preview(Fixtures.idB)) == 0)
        let image = try #require(cache.images[Fixtures.idA])
        #expect(image.width == 8)
        #expect(image.height == 6)
    }

    @Test("an oversized source is still capped at the bitmap height limit")
    func capsHeight() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try thumbnailBytes(width: 400, height: 600)
        let client = FakePhotonClient(thumbnail: { _ in bytes })
        let cache = ThumbnailCache(directory: directory)

        await cache.prefetch(items: [Fixtures.itemA], client: client)

        let image = try #require(cache.images[Fixtures.idA])
        #expect(image.height == ThumbnailCache.maxPixelHeight)
        // 比例保持：400/600 → 341/512
        #expect(image.width == 341)
    }

    @Test("a failed thumbnail leaves that item empty and does not affect the others")
    func failedItemIsIsolated() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try thumbnailBytes(width: 8, height: 6)
        let client = FakePhotonClient(thumbnail: { id in
            if id == Fixtures.idA { throw ClientError.sourceUnreadable }
            return bytes
        })
        let cache = ThumbnailCache(directory: directory)

        await cache.prefetch(items: [Fixtures.itemA, Fixtures.itemB], client: client)

        #expect(cache.images[Fixtures.idA] == nil)
        #expect(cache.images[Fixtures.idB] != nil)
        #expect(client.callCount(.thumbnail(Fixtures.idB)) == 1)
    }

    @Test("a second cache reads the disk copy without requesting anything")
    func diskCache() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try thumbnailBytes(width: 8, height: 6)
        let first = ThumbnailCache(directory: directory)
        await first.prefetch(items: [Fixtures.itemA], client: FakePhotonClient(thumbnail: { _ in bytes }))
        #expect(first.images.count == 1)

        let offline = FakePhotonClient(thumbnail: { _ in throw ClientError.notFound })
        let second = ThumbnailCache(directory: directory)
        await second.prefetch(items: [Fixtures.itemA], client: offline)

        #expect(second.images.count == 1)
        #expect(offline.calls().isEmpty)
    }

    @Test("a pre-bump cache file is ignored")
    func ignoresOldNamespace() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // v1 的文件名没有版本段，内容是从 preview base 缩出来的。
        let stale = directory.appending(path: "\(Fixtures.idA)-\(ThumbnailCache.maxPixelHeight).png")
        try thumbnailBytes(width: 4, height: 4).write(to: stale)

        let bytes = try thumbnailBytes(width: 8, height: 6)
        let client = FakePhotonClient(thumbnail: { _ in bytes })
        let cache = ThumbnailCache(directory: directory)

        await cache.prefetch(items: [Fixtures.itemA], client: client)

        #expect(client.callCount(.thumbnail(Fixtures.idA)) == 1)
        let image = try #require(cache.images[Fixtures.idA])
        #expect(image.width == 8, "the stale 4×4 file must not be shown")
    }

    @Test("clear drops the memory and the disk copies")
    func clearDropsBoth() async throws {
        let directory = makeDirectory()
        let bytes = try thumbnailBytes(width: 8, height: 6)
        let cache = ThumbnailCache(directory: directory)
        await cache.prefetch(items: [Fixtures.itemA], client: FakePhotonClient(thumbnail: { _ in bytes }))
        #expect(FileManager.default.fileExists(atPath: directory.path))

        cache.clear()

        #expect(cache.images.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("a failed item is not requested")
    func skipsFailed() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try thumbnailBytes(width: 8, height: 6)
        let client = FakePhotonClient(thumbnail: { _ in bytes })
        let cache = ThumbnailCache(directory: directory)
        let failed = Fixtures.item(id: Fixtures.idA2, name: "x.tif", path: "/b/x.tif", state: .failed)

        await cache.prefetch(items: [failed], client: client)

        #expect(cache.images.isEmpty)
        #expect(client.callCount(.thumbnail(Fixtures.idA2)) == 0)
    }
}
