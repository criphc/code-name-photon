import ClientKit
import ContractKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import ClientModel

// MARK: - Settings

/// Settings seam used by every test: no `UserDefaults`, fully inspectable.
final class InMemorySettingsStore: PhotonSettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: PhotonConnectionSettings?

    init(_ settings: PhotonConnectionSettings? = nil) {
        self.settings = settings
    }

    func load() -> PhotonConnectionSettings? {
        lock.withLock { settings }
    }

    func save(_ settings: PhotonConnectionSettings) {
        lock.withLock { self.settings = settings }
    }

    var current: PhotonConnectionSettings? { load() }
}

extension PhotonConnectionSettings {
    static let test = PhotonConnectionSettings(
        host: "192.168.1.5",
        port: SessionModel.defaultPort,
        token: "secret"
    )
}

// MARK: - Scripted transport

/// A `PhotonClientProtocol` fake: every endpoint is a replaceable async closure, and the calls are
/// recorded. No network, no server, no timeouts.
final class FakePhotonClient: PhotonClientProtocol, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case health
        case listItems
        case prepare(String)
        case preview(String)
        case thumbnail(String)
        case postRecipe(String)
    }

    typealias HealthHandler = @Sendable () async throws -> HealthResponse
    typealias ListHandler = @Sendable () async throws -> [ItemSummary]
    typealias PrepareHandler = @Sendable (String) async throws -> PrepareResponse
    typealias PreviewHandler = @Sendable (String, ((Double) -> Void)?) async throws -> Data
    typealias ThumbnailHandler = @Sendable (String) async throws -> Data
    typealias PostHandler = @Sendable (String, Recipe) async throws -> RecipePostResponse

    var healthHandler: HealthHandler
    var listHandler: ListHandler
    var prepareHandler: PrepareHandler
    var previewHandler: PreviewHandler
    var thumbnailHandler: ThumbnailHandler
    var postHandler: PostHandler

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var recipes: [Recipe] = []

    init(
        health: @escaping HealthHandler = { Fixtures.health() },
        listItems: @escaping ListHandler = { [] },
        prepare: @escaping PrepareHandler = { _ in throw ClientError.notFound },
        preview: @escaping PreviewHandler = { _, _ in throw ClientError.notFound },
        thumbnail: @escaping ThumbnailHandler = { _ in throw ClientError.notFound },
        post: @escaping PostHandler = { _, _ in throw ClientError.notFound }
    ) {
        self.healthHandler = health
        self.listHandler = listItems
        self.prepareHandler = prepare
        self.previewHandler = preview
        self.thumbnailHandler = thumbnail
        self.postHandler = post
    }

    // MARK: PhotonClientProtocol

    func health() async throws -> HealthResponse {
        record(.health)
        return try await healthHandler()
    }

    func listItems() async throws -> [ItemSummary] {
        record(.listItems)
        return try await listHandler()
    }

    func prepare(itemID: String) async throws -> PrepareResponse {
        record(.prepare(itemID))
        return try await prepareHandler(itemID)
    }

    func previewPNG(itemID: String, progress: ((Double) -> Void)?) async throws -> Data {
        record(.preview(itemID))
        return try await previewHandler(itemID, progress)
    }

    func thumbnailHEIC(itemID: String) async throws -> Data {
        record(.thumbnail(itemID))
        return try await thumbnailHandler(itemID)
    }

    func postRecipe(itemID: String, recipe: Recipe) async throws -> RecipePostResponse {
        record(.postRecipe(itemID))
        lock.withLock { recipes.append(recipe) }
        return try await postHandler(itemID, recipe)
    }

    // MARK: Inspection

    func calls() -> [Call] {
        lock.withLock { recorded }
    }

    func callCount(_ call: Call) -> Int {
        calls().filter { $0 == call }.count
    }

    func postedRecipes() -> [Recipe] {
        lock.withLock { recipes }
    }

    private func record(_ call: Call) {
        lock.withLock { recorded.append(call) }
    }
}

// MARK: - Async gate

/// Suspends a scripted transport call until the test has observed the in-flight state.
actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Fixtures

enum Fixtures {
    /// 64-hex ids, as the wire contract requires (`source.sha256`).
    static let idA = String(repeating: "a", count: 64)
    static let idB = String(repeating: "b", count: 64)
    static let idA2 = String(repeating: "c", count: 64)

    static let nameA = "R0003777-P3.tif"
    static let nameB = "R0003778-P3.tif"
    static let pathA = "/batch/\(nameA)"
    static let pathB = "/batch/\(nameB)"

    static let itemA = item(id: idA, name: nameA, path: pathA)
    static let itemB = item(id: idB, name: nameB, path: pathB)

    static func item(
        id: String,
        name: String,
        path: String,
        state: ItemState = .previewReady,
        hasRecipe: Bool = false,
        width: Int = 4,
        height: Int = 4
    ) -> ItemSummary {
        ItemSummary(
            id: id,
            name: name,
            path: path,
            state: state,
            previewReady: true,
            hasRecipe: hasRecipe,
            width: width,
            height: height
        )
    }

    static func health(itemCount: Int = 0) -> HealthResponse {
        HealthResponse(version: "test", itemCount: itemCount, authRequired: true)
    }

    static func makePNGData(width: Int, height: Int) throws -> Data {
        var samples = [UInt16](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let index = (y * width + x) * 4
                samples[index] = UInt16((x * 65535) / max(1, width - 1))
                samples[index + 1] = UInt16((y * 65535) / max(1, height - 1))
                samples[index + 2] = 32768
                samples[index + 3] = UInt16.max
            }
        }
        let image: CGImage = try samples.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 16,
                bytesPerRow: width * 8,
                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder16Little.rawValue
            ), let image = context.makeImage() else {
                throw FixtureError.cannotCreateImage
            }
            return image
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw FixtureError.cannotCreateImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.cannotCreateImage
        }
        return data as Data
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func metadata(for item: ItemSummary, png: Data) -> PreviewMetadata {
        let width = item.width ?? 1
        let height = item.height ?? 1
        return PreviewMetadata(
            source: .init(
                path: item.path,
                sha256: item.id,
                width: width,
                height: height,
                profileName: "Display P3",
                bitsPerComponent: 16
            ),
            base: .init(
                file: "preview-base.png",
                bytes: png.count,
                sha256: sha256Hex(png),
                width: width,
                height: height,
                format: BasePNG.expectedFormat,
                workingSpace: BasePNG.expectedWorkingSpace,
                profileName: "Display P3",
                longEdge: max(width, height)
            ),
            recipeDefaults: Recipe.defaults(
                sourcePath: item.path,
                sourceSHA256: item.id,
                width: width,
                height: height,
                encoderVersion: "test"
            ),
            appVersion: "test",
            createdAt: "2026-11-05T00:00:00+08:00"
        )
    }

    static func prepareResponse(for item: ItemSummary, png: Data) -> PrepareResponse {
        PrepareResponse(item: item, meta: metadata(for: item, png: png), cached: false)
    }

    static func postResponse(
        for item: ItemSummary,
        recipe: Recipe,
        renderKey: String? = nil
    ) -> RecipePostResponse {
        RecipePostResponse(
            item: item,
            recipe: recipe,
            renderKey: renderKey ?? "render-key-\(item.id.prefix(12))"
        )
    }

    /// A client that serves the given items with a valid 16-bit P3 base for each.
    static func client(items: [ItemSummary], png: Data) -> FakePhotonClient {
        FakePhotonClient(
            health: { Fixtures.health(itemCount: items.count) },
            listItems: { items },
            prepare: { id in
                guard let item = items.first(where: { $0.id == id }) else {
                    throw ClientError.notFound
                }
                return Fixtures.prepareResponse(for: item, png: png)
            },
            preview: { id, progress in
                guard items.contains(where: { $0.id == id }) else {
                    throw ClientError.notFound
                }
                progress?(0)
                progress?(1)
                return png
            },
            post: { id, recipe in
                guard let item = items.first(where: { $0.id == id }) else {
                    throw ClientError.notFound
                }
                return Fixtures.postResponse(for: item, recipe: recipe)
            }
        )
    }
}

enum FixtureError: Error {
    case cannotCreateImage
}

// MARK: - Harness

/// A connected `SessionModel` + `JudgeModel` pair with a scripted transport and in-memory settings.
@MainActor
final class Harness {
    let store: InMemorySettingsStore
    let client: FakePhotonClient
    let session: SessionModel
    let judge: JudgeModel
    let png: Data
    let items: [ItemSummary]

    init(
        items: [ItemSummary]? = nil,
        client: FakePhotonClient? = nil,
        settings: PhotonConnectionSettings = .test,
        store: InMemorySettingsStore? = nil
    ) throws {
        let png = try Fixtures.makePNGData(width: 4, height: 4)
        let items = items ?? [Fixtures.itemA, Fixtures.itemB]
        let store = store ?? InMemorySettingsStore(settings)
        let client = client ?? Fixtures.client(items: items, png: png)

        self.png = png
        self.items = items
        self.store = store
        self.client = client
        self.session = SessionModel(settingsStore: store, makeClient: { _ in client })
        self.judge = JudgeModel(session: session)
    }

    @discardableResult
    func connect() async -> Bool {
        await session.connect()
        return session.isConnected
    }
}

// MARK: - Waiting

/// Polls a main-actor condition for work the model starts in a background `Task` (the 404 refresh
/// and the 409 re-judge), so the tests never race the scheduler.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    condition: @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting for \(description)")
}
