import ContractKit
import Foundation
import XCTest

/// Batch delivery (`appctl deliver --batch <dir>`) at the CLI level: the flat batch is enumerated
/// from the folder, only items with a stored recipe are delivered, a failure does not stop the
/// batch, and the exit code is the summary. The single-item path is `AppctlDeliverSmokeTests`.
///
/// Every case runs the real binary on small sources generated at run time, so a case costs one
/// delivery of a 64x64 image at most.
final class AppctlDeliverBatchTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = try IntegrationSupport.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    // MARK: - Cases

    /// A has a stored recipe, B does not: A installs, B is skipped (not failed), exit 0.
    func testBatchDeliversItemsWithAStoredRecipeAndSkipsTheRest() throws {
        let inbox = try makeInbox()
        let a = try writeSource(named: "a.tif", size: (width: 64, height: 64), in: inbox)
        let b = try writeSource(named: "b.tif", size: (width: 64, height: 32), in: inbox)
        let work = temporaryDirectory.appendingPathComponent("work", isDirectory: true)
        let out = temporaryDirectory.appendingPathComponent("out", isDirectory: true)
        try storeRecipe(for: a, in: work)

        let result = try runAppctl([
            "deliver", "--batch", inbox.path, "--work", work.path, "--out", out.path,
        ])

        XCTAssertEqual(result.status, 0, "a batch where the only deliverable item passes must exit 0.\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
        for name in deliverables(stem: "a") {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path),
                "missing deliverable '\(name)' in \(out.path)\nstdout:\n\(result.stdout)"
            )
        }
        for name in deliverables(stem: "b") {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path),
                "the skipped item must not install '\(name)'\nstdout:\n\(result.stdout)"
            )
        }
        let bLine = try XCTUnwrap(
            line(containing: b.url.lastPathComponent, in: result.stdout),
            "stdout has no line for \(b.url.lastPathComponent)\nstdout:\n\(result.stdout)"
        )
        XCTAssertTrue(bLine.contains("skip"), "B has no stored recipe and must be skipped, got '\(bLine)'")
        XCTAssertTrue(
            result.stdout.contains("1 passed, 0 failed, 1 skipped"),
            "the summary must count the skip separately from a failure\nstdout:\n\(result.stdout)"
        )
    }

    /// A passes, B's stored recipe names different source bytes: B fails, A still installs, exit 1.
    func testBatchKeepsGoingAfterAFailedItem() throws {
        let inbox = try makeInbox()
        let a = try writeSource(named: "a.tif", size: (width: 64, height: 64), in: inbox)
        let b = try writeSource(named: "b.tif", size: (width: 64, height: 32), in: inbox)
        let work = temporaryDirectory.appendingPathComponent("work", isDirectory: true)
        let out = temporaryDirectory.appendingPathComponent("out", isDirectory: true)
        try storeRecipe(for: a, in: work)
        // A re-exported source: the recipe is there, but it describes different bytes.
        try storeRecipe(for: b, in: work, declaredSHA256: String(repeating: "0", count: 64))

        let result = try runAppctl([
            "deliver", "--batch", inbox.path, "--work", work.path, "--out", out.path,
        ])

        XCTAssertEqual(result.status, 1, "a batch with a failed item must exit 1.\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
        for name in deliverables(stem: "a") {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path),
                "the failure of B must not stop A from installing '\(name)'\nstdout:\n\(result.stdout)"
            )
        }
        let bLine = try XCTUnwrap(
            line(containing: b.url.lastPathComponent, in: result.stdout),
            "stdout has no line for \(b.url.lastPathComponent)\nstdout:\n\(result.stdout)"
        )
        XCTAssertTrue(bLine.contains("FAIL"), "B must be reported as FAIL, got '\(bLine)'")
        XCTAssertTrue(
            result.stdout.contains("1 passed, 1 failed, 0 skipped"),
            "the summary must count the failure\nstdout:\n\(result.stdout)"
        )
    }

    /// No item has a stored recipe: nothing is delivered, nothing is installed, exit 1.
    func testBatchWithNoStoredRecipeFailsAndInstallsNothing() throws {
        let inbox = try makeInbox()
        let a = try writeSource(named: "a.tif", size: (width: 64, height: 64), in: inbox)
        let b = try writeSource(named: "b.tif", size: (width: 64, height: 32), in: inbox)
        let work = temporaryDirectory.appendingPathComponent("work", isDirectory: true)
        let out = temporaryDirectory.appendingPathComponent("out", isDirectory: true)

        let result = try runAppctl([
            "deliver", "--batch", inbox.path, "--work", work.path, "--out", out.path,
        ])

        XCTAssertEqual(result.status, 1, "a batch with zero deliverable items must exit 1.\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
        let installed = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        XCTAssertEqual(installed, [], "nothing may be installed when no item has a stored recipe")
        XCTAssertTrue(
            result.stdout.contains("0 passed, 0 failed, 2 skipped"),
            "both items must be counted as skipped\nstdout:\n\(result.stdout)"
        )
        XCTAssertFalse(
            result.stderr.isEmpty,
            "the zero-deliverable batch must explain itself on stderr"
        )
        XCTAssertTrue(
            result.stdout.contains(a.url.lastPathComponent) && result.stdout.contains(b.url.lastPathComponent),
            "the summary must still list every item\nstdout:\n\(result.stdout)"
        )
    }

    /// `--recipe` is a single-delivery option; batch mode uses each item's stored recipe.
    func testBatchRejectsTheRecipeOption() throws {
        let inbox = try makeInbox()
        _ = try writeSource(named: "a.tif", size: (width: 64, height: 64), in: inbox)
        let recipe = temporaryDirectory.appendingPathComponent("recipe.json")

        let result = try runAppctl([
            "deliver", "--batch", inbox.path, "--recipe", recipe.path,
        ])

        XCTAssertEqual(result.status, 2, "`--recipe` with `--batch` is a usage error (exit 2).\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
    }

    // MARK: - Fixtures

    private func makeInbox() throws -> URL {
        let inbox = temporaryDirectory.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// Two sources in one batch must differ in bytes: `BatchLookup` collapses duplicate content to
    /// the first name, so identical gradients would be one item, not two.
    private func writeSource(
        named name: String,
        size: (width: Int, height: Int),
        in inbox: URL
    ) throws -> (url: URL, sha256: String, width: Int, height: Int) {
        let url = inbox.appendingPathComponent(name)
        try IntegrationSupport.writeGradientP3TIFF(width: size.width, height: size.height, to: url)
        return (url, try IntegrationSupport.sha256Hex(ofFileAt: url), size.width, size.height)
    }

    /// Stores the recipe in the M3 layout (`work/<source sha256>/recipe.json`), which is what the
    /// CLI's default lookup reads. `declaredSHA256` overrides the recipe's `source.sha256` so a case
    /// can simulate a re-exported source.
    private func storeRecipe(
        for source: (url: URL, sha256: String, width: Int, height: Int),
        in work: URL,
        declaredSHA256: String? = nil
    ) throws {
        let directory = work.appendingPathComponent(source.sha256, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let recipe = Recipe(
            source: Recipe.Source(
                path: source.url.lastPathComponent,
                sha256: declaredSHA256 ?? source.sha256,
                width: source.width,
                height: source.height
            ),
            hdr: Recipe.HDR(start: 0.4, liftStops: 1.4, transition: 0.3, headroomCap: 2.5),
            encoder: Recipe.EncoderParams(
                tool: Recipe.EncoderParams.coreImageToolName,
                quality: 0.85,
                depth: 10,
                subsample: true,
                map: Recipe.EncoderParams.isoRGBMap
            ),
            versions: Recipe.Versions(encoder: "coreimage-1"),
            created: "2026-11-05T00:00:00+08:00"
        )
        try recipe.validate()
        try recipe.canonicalJSON().write(to: directory.appendingPathComponent("recipe.json"))
    }

    private func deliverables(stem: String) -> [String] {
        [
            "\(stem)-hdr-10-half-rgb.heic",
            "\(stem)-sdr.heic",
            "\(stem).recipe.json",
            "\(stem).report.json",
        ]
    }

    // MARK: - Running appctl

    private struct RunResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func runAppctl(_ arguments: [String]) throws -> RunResult {
        let binary = try IntegrationSupport.appctlBinary()
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let collector = ProcessOutputCollector()
        defer { IntegrationSupport.stop(process) }

        try process.run()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        collector.drain(stdout: stdoutPipe, stderr: stderrPipe)

        guard IntegrationSupport.waitForExit(process, timeout: 120) else {
            IntegrationSupport.stop(process)
            _ = collector.waitForStdoutEOF(timeout: 5)
            _ = collector.waitForStderrEOF(timeout: 5)
            XCTFail(
                "appctl \(arguments.joined(separator: " ")) did not finish within 120 s.\n"
                    + "stdout:\n\(collector.stdoutText)\nstderr:\n\(collector.stderrText)"
            )
            return RunResult(status: -1, stdout: collector.stdoutText, stderr: collector.stderrText)
        }
        _ = collector.waitForStdoutEOF(timeout: 5)
        _ = collector.waitForStderrEOF(timeout: 5)
        return RunResult(
            status: process.terminationStatus,
            stdout: collector.stdoutText,
            stderr: collector.stderrText
        )
    }

    /// The first stdout line naming `name`; the summary pads names into a table, so matching the
    /// line is more honest than matching a fixed column layout.
    private func line(containing name: String, in stdout: String) -> String? {
        stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.contains(name) }
            .map(String.init)
    }
}
