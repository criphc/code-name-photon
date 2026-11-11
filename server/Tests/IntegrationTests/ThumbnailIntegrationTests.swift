import ContractKit
import CoreGraphics
import Foundation
import ImageIO
import XCTest

/// The filmstrip thumbnail over the real `appctl serve` process (ADR-0013).
///
/// Two server runs: one proves the endpoint's bytes and that it never prepares the preview base;
/// one proves the start-up warm-up is on by default and does not block `/api/health`.
final class ThumbnailIntegrationTests: XCTestCase {
    private static let token = "test-token"

    private var temporaryDirectory: URL!
    private var process: Process?

    override func setUpWithError() throws {
        temporaryDirectory = try IntegrationSupport.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let process {
            IntegrationSupport.stop(process)
        }
        process = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // MARK: - The endpoint

    /// A 64×600 source: taller than the 512 target, so ImageIO must produce exactly 512 px high
    /// (a source shorter than 512 would be left at its own height — ImageIO never upscales).
    func testThumbnailEndpointServesA512HighDisplayP3HEICWithoutPreparing() throws {
        let inbox = try makeDirectory("inbox")
        let work = try makeDirectory("work")
        let source = inbox.appendingPathComponent("portrait.tif")
        try IntegrationSupport.writeGradientP3TIFF(width: 64, height: 600, to: source)
        let sha = try IntegrationSupport.sha256Hex(ofFileAt: source)

        let server = try startServe(inbox: inbox, work: work)

        let listed = try fetchItems(port: server.port)
        XCTAssertEqual(listed.map(\.id), [sha], "the batch must contain the generated source")
        XCTAssertEqual(listed.first?.state, .pending, "a fresh source starts pending")

        let response = try httpGetWithHeaders(
            try url(port: server.port, path: "/api/items/\(sha)/thumbnail")
        )
        XCTAssertEqual(response.statusCode, 200, "thumbnail body: \(response.bodyText)")
        XCTAssertEqual(response.headers["content-type"], "image/heic")

        // ImageIO can open the body: 512 px high and Display P3 — the filmstrip's contract.
        let imageSource = try XCTUnwrap(
            CGImageSourceCreateWithData(response.body as CFData, nil),
            "the thumbnail body is not an image ImageIO can open"
        )
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            "no image properties on the thumbnail"
        )
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 512)
        XCTAssertEqual(properties[kCGImagePropertyProfileName] as? String, "Display P3")
        let image = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
            "ImageIO cannot decode the thumbnail"
        )
        XCTAssertEqual(
            image.colorSpace?.name as String?,
            CGColorSpace(name: CGColorSpace.displayP3)?.name as String?
        )

        // A thumbnail is its own artifact: it must never render the preview base, and it does not
        // change the item's state (the item stays `pending` — ADR-0013 §7).
        let itemDirectory = work.appendingPathComponent(sha, isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: itemDirectory.appendingPathComponent("thumbnail-512-v1.heic").path
            ),
            "the thumbnail must be cached at work/<sha>/thumbnail-512-v1.heic"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: itemDirectory.appendingPathComponent("preview-base.png").path
            ),
            "a thumbnail request must not prepare the preview base"
        )
        XCTAssertEqual(
            try fetchItems(port: server.port).first?.state,
            .pending,
            "only having a thumbnail must leave the item pending"
        )
    }

    // MARK: - Start-up warm-up

    /// No flag is passed: `serve` must render every item's thumbnail in the background, and
    /// `/api/health` must answer while that runs (it uses its own lock, never the store's).
    func testServeWarmsThumbnailsByDefaultAndStaysHealthy() throws {
        let inbox = try makeDirectory("inbox")
        let work = try makeDirectory("work")
        var shas: [String] = []
        // Distinct widths give distinct bytes, hence distinct item ids; all are 600 px tall so
        // every thumbnail is 512 high.
        for width in 64 ..< 72 {
            let source = inbox.appendingPathComponent("warm-\(width).tif")
            try IntegrationSupport.writeGradientP3TIFF(width: width, height: 600, to: source)
            shas.append(try IntegrationSupport.sha256Hex(ofFileAt: source))
        }

        let server = try startServe(inbox: inbox, work: work)

        // Immediately after the ready line, while the warm-up queue is running.
        let health: IntegrationSupport.HTTPResult
        do {
            health = try IntegrationSupport.httpGet(
                try url(port: server.port, path: "/api/health"),
                timeout: 2
            )
        } catch {
            XCTFail(
                "/api/health did not answer while the warm-up ran: \(error)"
                    + "\nstderr:\n" + server.collector.stderrText
            )
            return
        }
        XCTAssertEqual(health.statusCode, 200, "health body: \(health.bodyText)")

        // Poll instead of sleeping: the warm-up must produce all eight thumbnails by itself.
        let deadline = Date().addingTimeInterval(30)
        var missing = shas
        while !missing.isEmpty, Date() < deadline {
            missing = shas.filter {
                !FileManager.default.fileExists(
                    atPath: work.appendingPathComponent($0, isDirectory: true)
                        .appendingPathComponent("thumbnail-512-v1.heic").path
                )
            }
            if !missing.isEmpty {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        XCTAssertTrue(
            missing.isEmpty,
            "the default warm-up did not render every thumbnail; missing: \(missing)"
                + "\nstderr:\n" + server.collector.stderrText
        )
        XCTAssertTrue(
            server.collector.stderrText.contains("warm-up"),
            "the warm-up progress must go to stderr, not stdout:\n" + server.collector.stderrText
        )
    }

    // MARK: - Harness

    private struct RunningServer {
        let port: UInt16
        let collector: ProcessOutputCollector
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func url(port: UInt16, path: String) throws -> URL {
        try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
    }

    private func startServe(inbox: URL, work: URL) throws -> RunningServer {
        let binary = try IntegrationSupport.appctlBinary()
        let port = try IntegrationSupport.findFreePort()

        let process = Process()
        process.executableURL = binary
        // No warm-up flag: it is on by default and has no off switch (ADR-0013 §6).
        process.arguments = [
            "serve",
            "--bind", "127.0.0.1",
            "--port", String(port),
            "--batch", inbox.path,
            "--work", work.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PHOTON_APPCTL_TOKEN"] = Self.token
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let collector = ProcessOutputCollector()
        self.process = process

        try process.run()
        // The parent must let go of the write ends, or the collector never sees EOF.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        collector.drain(stdout: stdoutPipe, stderr: stderrPipe)

        guard let readyLine = collector.waitForFirstStdoutLine(timeout: 20) else {
            throw IntegrationSupport.Failure(description: """
            appctl serve wrote no stdout ready line within 20 s. stderr:
            \(collector.stderrText)
            """)
        }
        let event: ProcessEvent
        do {
            event = try JSONDecoder().decode(ProcessEvent.self, from: Data(readyLine.utf8))
        } catch {
            throw IntegrationSupport.Failure(description: """
            the first stdout line is not a ProcessEvent (\(error)). line='\(readyLine)'
            """)
        }
        guard case let .ready(ready) = event else {
            throw IntegrationSupport.Failure(description: "the first stdout event is not 'ready': '\(readyLine)'")
        }
        guard ready.isValid, ready.port == Int(port) else {
            throw IntegrationSupport.Failure(description: "invalid ready event: '\(readyLine)'")
        }
        return RunningServer(port: port, collector: collector)
    }

    private func fetchItems(port: UInt16) throws -> [ItemSummary] {
        let response = try IntegrationSupport.httpGet(
            try url(port: port, path: "/api/items"),
            bearerToken: Self.token,
            timeout: 5
        )
        guard response.statusCode == 200 else {
            throw IntegrationSupport.Failure(
                description: "GET /api/items returned \(response.statusCode): \(response.bodyText)"
            )
        }
        return try JSONDecoder().decode(ItemListResponse.self, from: response.body).items
    }

    private struct HTTPResponseWithHeaders {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

        var bodyText: String { String(decoding: body, as: UTF8.self) }
    }

    /// `IntegrationSupport.httpGet` drops the response headers; the thumbnail's `Content-Type` is
    /// part of the contract, so this variant keeps them (names lower-cased).
    private func httpGetWithHeaders(_ url: URL, timeout: TimeInterval = 5) throws -> HTTPResponseWithHeaders {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(Self.token)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        final class Box {
            var result: Result<HTTPResponseWithHeaders, Error>?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.result = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                box.result = .failure(
                    IntegrationSupport.Failure(description: "no HTTP response for \(url.absoluteString)")
                )
                return
            }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                guard let name = name as? String, let value = value as? String else { continue }
                headers[name.lowercased()] = value
            }
            box.result = .success(
                HTTPResponseWithHeaders(statusCode: http.statusCode, headers: headers, body: data)
            )
        }.resume()

        guard semaphore.wait(timeout: .now() + timeout + 5) == .success else {
            throw IntegrationSupport.Failure(
                description: "GET \(url.absoluteString) did not answer within \(timeout) s"
            )
        }
        guard let result = box.result else {
            throw IntegrationSupport.Failure(
                description: "GET \(url.absoluteString) finished without a result"
            )
        }
        return try result.get()
    }
}
