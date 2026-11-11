import ContractKit
import Foundation
import XCTest

/// Case A of the P2 integration gate: the real `appctl serve` process contract (ADR-0010).
///
/// Spawns the built binary, reads the single stdout ready line as a `ProcessEvent`, proves the HTTP
/// server answers on the readiness port, then sends SIGTERM and asserts a clean exit with no extra
/// stdout. The only stdout configuration comes from `appctl`; stderr is human log capture.
final class AppctlServeIntegrationTests: XCTestCase {
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

    func testServeWritesOneReadyLineServesHealthAndStopsOnSIGTERM() throws {
        let binary = try IntegrationSupport.appctlBinary()
        let port = try IntegrationSupport.findFreePort()

        let inbox = temporaryDirectory.appendingPathComponent("inbox", isDirectory: true)
        let work = temporaryDirectory.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = binary
        // Fixed port on purpose: P2 does not expose --port 0 (that is P4).
        process.arguments = [
            "serve",
            "--bind", "127.0.0.1",
            "--port", String(port),
            "--batch", inbox.path,
            "--work", work.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PHOTON_APPCTL_TOKEN"] = "test-token"
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let collector = ProcessOutputCollector()
        self.process = process

        try process.run()
        // The parent must let go of the write ends, or `readDataToEndOfFile` never sees EOF.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        collector.drain(stdout: stdoutPipe, stderr: stderrPipe)

        // 1. Exactly one machine-readable ready line on stdout, and nothing else.
        guard let readyLine = collector.waitForFirstStdoutLine(timeout: 20) else {
            XCTFail(
                "appctl serve wrote no stdout ready line within 20 s. stderr:\n" + collector.stderrText
            )
            return
        }
        let event: ProcessEvent
        do {
            event = try JSONDecoder().decode(ProcessEvent.self, from: Data(readyLine.utf8))
        } catch {
            XCTFail(
                "the first stdout line is not a ProcessEvent (\(error)). line='\(readyLine)' "
                    + "stderr:\n" + collector.stderrText
            )
            return
        }
        guard case let .ready(ready) = event else {
            XCTFail("the first stdout event is not 'ready': '\(readyLine)'")
            return
        }
        XCTAssertTrue(ready.isValid, "invalid ready event: '\(readyLine)'")
        XCTAssertEqual(ready.port, Int(port), "ready must report the --port the server bound")
        XCTAssertEqual(
            ready.pid,
            Int(process.processIdentifier),
            "ready.pid is informational but should be appctl's own pid"
        )

        // 2. The readiness port really serves: unauthenticated health probe.
        let healthURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/health"))
        let health = try IntegrationSupport.httpGet(healthURL, timeout: 5)
        XCTAssertEqual(health.statusCode, 200, "health body: \(health.bodyText)")
        let healthResponse = try JSONDecoder().decode(HealthResponse.self, from: health.body)
        XCTAssertTrue(healthResponse.ok, "health must report ok: true")
        XCTAssertTrue(
            healthResponse.authRequired,
            "PHOTON_APPCTL_TOKEN was set, so the server must require a token"
        )
        XCTAssertEqual(healthResponse.itemCount, 0, "the temporary inbox is empty")

        // 3. The token from the environment is the served token: the auth'd list works, the
        //    unauthenticated one is refused.
        let itemsURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/items"))
        let authorized = try IntegrationSupport.httpGet(itemsURL, bearerToken: "test-token", timeout: 5)
        XCTAssertEqual(authorized.statusCode, 200, "items body: \(authorized.bodyText)")
        let list = try JSONDecoder().decode(ItemListResponse.self, from: authorized.body)
        XCTAssertTrue(list.items.isEmpty, "the temporary inbox has no sources")

        let unauthorized = try IntegrationSupport.httpGet(itemsURL, timeout: 5)
        XCTAssertEqual(
            unauthorized.statusCode,
            401,
            "an unauthenticated /api/items must be refused, body: \(unauthorized.bodyText)"
        )

        // 4. SIGTERM (Process.terminate) is the stop request: graceful, exit 0.
        process.terminate()
        let exited = IntegrationSupport.waitForExit(process, timeout: 10)
        XCTAssertTrue(
            exited,
            "appctl serve did not exit within 10 s of SIGTERM. stderr:\n" + collector.stderrText
        )
        if exited {
            XCTAssertEqual(
                process.terminationStatus,
                0,
                "SIGTERM must stop the server with status 0. stderr:\n" + collector.stderrText
            )
        }

        // 5. stdout stayed protocol-only; the human logs went to stderr.
        XCTAssertTrue(collector.waitForStdoutEOF(timeout: 5), "the stdout pipe never reached EOF")
        let stdout = collector.stdoutText
        let stdoutLines = stdout.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(
            stdoutLines.count,
            1,
            "serve must write exactly one stdout line; got \(stdoutLines.count):\n\(stdout)"
        )
        XCTAssertTrue(
            stdout.hasSuffix("\n"),
            "the ready line must be newline-delimited, got: \(stdout.debugDescription)"
        )
        XCTAssertTrue(
            collector.waitForStderrEOF(timeout: 5),
            "the stderr pipe never reached EOF"
        )
        XCTAssertFalse(
            collector.stderrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "serve's human log lines (batch/work/listen/token) must go to stderr"
        )
    }
}
