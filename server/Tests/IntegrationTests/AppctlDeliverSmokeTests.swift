import ContractKit
import Foundation
import XCTest

/// Case B of the P2 integration gate: one real `appctl deliver` CLI run.
///
/// The source is a 16-bit Display P3 TIFF generated at run time with Core Image (never `samples/`
/// or `work/`), and the recipe is stored in the M3 client's layout so the CLI's default recipe
/// lookup is what is exercised. The encoder is the in-process Core Image writer; no external tool.
final class AppctlDeliverSmokeTests: XCTestCase {
    private var temporaryDirectory: URL!

    /// The report is an EngineKit document; the integration target depends only on ContractKit,
    /// so this probe reads just the one field the smoke test checks.
    private struct ReportProbe: Decodable {
        let pass: Bool
    }

    override func setUpWithError() throws {
        temporaryDirectory = try IntegrationSupport.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testDeliverCLIInstallsTheFourDeliverablesWithAPassingReport() throws {
        let binary = try IntegrationSupport.appctlBinary()

        let size = 64
        let sourceURL = temporaryDirectory.appendingPathComponent("smoke.tif")
        try IntegrationSupport.writeGradientP3TIFF(width: size, height: size, to: sourceURL)
        let sha256 = try IntegrationSupport.sha256Hex(ofFileAt: sourceURL)

        // The M3 layout: work/<source sha256>/recipe.json is the recipe `deliver` applies when
        // --recipe is omitted.
        let work = temporaryDirectory.appendingPathComponent("work", isDirectory: true)
        let storedRecipeDirectory = work.appendingPathComponent(sha256, isDirectory: true)
        try FileManager.default.createDirectory(at: storedRecipeDirectory, withIntermediateDirectories: true)
        let recipe = Recipe(
            source: Recipe.Source(
                path: sourceURL.lastPathComponent,
                sha256: sha256,
                width: size,
                height: size
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
        try recipe.canonicalJSON().write(
            to: storedRecipeDirectory.appendingPathComponent("recipe.json")
        )

        let output = temporaryDirectory.appendingPathComponent("out", isDirectory: true)
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "deliver",
            "--source", sourceURL.path,
            "--out", output.path,
            "--work", work.path,
        ]
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

        let exited = IntegrationSupport.waitForExit(process, timeout: 120)
        guard exited else {
            IntegrationSupport.stop(process)
            _ = collector.waitForStdoutEOF(timeout: 5)
            _ = collector.waitForStderrEOF(timeout: 5)
            XCTFail(
                "appctl deliver did not finish within 120 s.\nstdout:\n\(collector.stdoutText)"
                    + "\nstderr:\n\(collector.stderrText)"
            )
            return
        }
        _ = collector.waitForStdoutEOF(timeout: 5)
        _ = collector.waitForStderrEOF(timeout: 5)

        XCTAssertEqual(
            process.terminationStatus,
            0,
            "appctl deliver failed.\nstdout:\n\(collector.stdoutText)"
                + "\nstderr:\n\(collector.stderrText)"
        )
        guard process.terminationStatus == 0 else { return }

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let deliverables = [
            "\(stem)-hdr-10-half-rgb.heic",
            "\(stem)-sdr.heic",
            "\(stem).recipe.json",
            "\(stem).report.json",
        ]
        for name in deliverables {
            let url = output.appendingPathComponent(name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "missing deliverable '\(name)' in \(output.path)"
            )
        }

        let reportURL = output.appendingPathComponent("\(stem).report.json")
        let reportData: Data
        do {
            reportData = try Data(contentsOf: reportURL)
        } catch {
            XCTFail("cannot read the delivery report at \(reportURL.path): \(error)")
            return
        }
        do {
            let report = try JSONDecoder().decode(ReportProbe.self, from: reportData)
            XCTAssertTrue(
                report.pass,
                "the delivery report must say pass=true:\n"
                    + String(decoding: reportData, as: UTF8.self)
            )
        } catch {
            XCTFail(
                "the delivery report does not decode (\(error)):\n"
                    + String(decoding: reportData, as: UTF8.self)
            )
        }
    }
}
