import Foundation
import XCTest
@testable import EngineKit

/// The v2 delivery report is the **gate** (docs/reference/deliver.md, report schema 1), so its
/// contract is tested like one: the verdict is derived from the per-profile checks and cannot be
/// hand-written, the check names and order are fixed, and a report re-read from disk re-derives the
/// verdict instead of trusting the file.
final class DeliveryReportTests: XCTestCase {
    private static let profileName = "8-full-rgb"

    // MARK: - Fixtures

    private func makeRecipe() -> Recipe {
        Recipe.defaults(
            sourcePath: "samples/sources/R0003777-P3.tif",
            sourceSHA256: String(repeating: "a", count: 64),
            width: 6000,
            height: 4000,
            encoderVersion: "5dba4e2",
            created: "2026-11-03T11:45:38+08:00"
        )
    }

    private func makeChecks(failing: String? = nil) -> [DeliveryReport.Check] {
        DeliveryReport.checkOrder.map { name in
            DeliveryReport.Check(
                name: name,
                pass: name != failing,
                detail: "\(name) detail",
                measured: ["value": .number(1.5), "count": .integer(2), "note": .text("ok"), "flag": .boolean(true)]
            )
        }
    }

    private func makeProfile(
        failing: String? = nil,
        checks: [DeliveryReport.Check]? = nil
    ) throws -> DeliveryReport.ProfileReport {
        try DeliveryReport.ProfileReport(
            profile: DeliveryReport.ProfileReference(
                options: try HEICEncodeOptions(bitDepth: .eight, quality: 0.85, mapResolution: .full, mapKind: .isoRGB)
            ),
            render: DeliveryReport.Render(
                width: 6000,
                height: 4000,
                headroomCap: 2.5,
                authoredPeak: 2.5,
                fractionAboveOne: 0.1094,
                fractionAtCap: 0.00431,
                previewLongEdge: 2560
            ),
            artifacts: DeliveryReport.Artifacts(
                hdrHEIC: DeliveryReport.FileArtifact(
                    file: "R0003777-P3-hdr-8-full-rgb.heic", bytes: 3_853_079,
                    sha256: String(repeating: "c", count: 64)
                ),
                sdrHEIC: DeliveryReport.FileArtifact(
                    file: "R0003777-P3-sdr.heic", bytes: 2_034_332,
                    sha256: String(repeating: "d", count: 64)
                ),
                recipeJSON: DeliveryReport.FileArtifact(
                    file: "R0003777-P3.recipe.json", bytes: 615,
                    sha256: String(repeating: "e", count: 64)
                )
            ),
            checks: checks ?? makeChecks(failing: failing),
            timings: DeliveryReport.Timings(
                decodeSeconds: 0.31,
                renderSeconds: 0.24,
                previewSeconds: 0.35,
                encodeSeconds: 0.67,
                verifySeconds: 1.2,
                totalSeconds: 3.0
            )
        )
    }

    private func makeReport(
        failing: String? = nil,
        checks: [DeliveryReport.Check]? = nil
    ) throws -> DeliveryReport {
        try DeliveryReport(
            provenance: DeliveryReport.Provenance(
                appVersion: "0.5.0-test",
                encoderVersion: "coreimage-1",
                generatedAt: "2026-11-03T13:00:00+08:00",
                hostOS: "macOS test"
            ),
            source: DeliveryReport.SourceIdentity(
                path: "samples/sources/R0003777-P3.tif",
                sha256: String(repeating: "a", count: 64),
                width: 6000,
                height: 4000,
                profileName: "Display P3",
                bitsPerComponent: 16
            ),
            recipe: DeliveryReport.RecipeReference(recipe: makeRecipe(), renderKey: String(repeating: "b", count: 64)),
            profiles: [try makeProfile(failing: failing, checks: checks)]
        )
    }

    // MARK: - Check list

    func testCheckOrderMatchesTheDocumentedReport() {
        XCTAssertEqual(
            DeliveryReport.checkOrder,
            ["container", "identity", "alpha", "headroom", "clipping", "baseDeltaE", "fallback", "previewAgreement"],
            "docs/reference/deliver.md names the checks in report order; the order is part of the contract"
        )
    }

    func testUnknownCheckNameIsRejected() throws {
        var checks = makeChecks()
        checks.append(DeliveryReport.Check(name: "looksNice", pass: true, detail: "not a documented check"))
        XCTAssertThrowsError(try makeReport(checks: checks)) { error in
            guard case let PhotonError.invalidImage(reason)? = error as? PhotonError else {
                return XCTFail("expected invalidImage, got \(error)")
            }
            XCTAssertTrue(reason.contains("looksNice"), "the reason must name the unknown check: \(reason)")
        }
    }

    func testDuplicateCheckNameIsRejected() throws {
        var checks = makeChecks()
        checks.append(DeliveryReport.Check(name: "container", pass: true, detail: "again"))
        XCTAssertThrowsError(try makeReport(checks: checks)) { error in
            guard case let PhotonError.invalidImage(reason)? = error as? PhotonError else {
                return XCTFail("expected invalidImage, got \(error)")
            }
            XCTAssertTrue(reason.contains("duplicate"), "the reason must name the duplicate: \(reason)")
        }
    }

    func testDuplicateProfileNameIsRejected() throws {
        let profile = try makeProfile()
        XCTAssertThrowsError(
            try DeliveryReport(
                provenance: DeliveryReport.Provenance(encoderVersion: "coreimage-1"),
                source: DeliveryReport.SourceIdentity(
                    path: "x", sha256: String(repeating: "a", count: 64),
                    width: 1, height: 1, profileName: nil, bitsPerComponent: 16
                ),
                recipe: DeliveryReport.RecipeReference(recipe: makeRecipe(), renderKey: "key"),
                profiles: [profile, profile]
            )
        ) { error in
            guard case let PhotonError.invalidImage(reason)? = error as? PhotonError else {
                return XCTFail("expected invalidImage, got \(error)")
            }
            XCTAssertTrue(reason.contains("duplicate profile"), reason)
        }
    }

    // MARK: - Verdict derivation

    func testPassIsDerivedFromTheChecksAndSortedInCanonicalOrder() throws {
        let scrambled = makeChecks(failing: "baseDeltaE").reversed()
        let report = try makeReport(checks: Array(scrambled))
        let profile = try XCTUnwrap(report.profiles.first)

        XCTAssertEqual(profile.checks.map(\.name), DeliveryReport.checkOrder)
        XCTAssertFalse(report.pass)
        XCTAssertEqual(profile.failures, ["baseDeltaE"])
        XCTAssertEqual(report.failures, ["8-full-rgb: baseDeltaE"])
        XCTAssertEqual(profile.checks.filter { !$0.passed }.map(\.name), ["baseDeltaE"])
    }

    func testAllPassingChecksProduceAPass() throws {
        let report = try makeReport()
        XCTAssertTrue(report.pass)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.profiles[0].checks.count, DeliveryReport.checkOrder.count)
    }

    func testAHandEditedPassCannotSurviveADecode() throws {
        let report = try makeReport(failing: "headroom")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try report.jsonData()) as? [String: Any])
        XCTAssertEqual(json["pass"] as? Bool, false)

        json["pass"] = true
        json["failures"] = []
        let tampered = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(DeliveryReport.self, from: tampered)

        XCTAssertFalse(decoded.pass, "the verdict is derived from the checks, not from the file's pass field")
        XCTAssertEqual(decoded.failures, ["8-full-rgb: headroom"])
    }

    func testUnknownSchemaIsRefused() throws {
        let report = try makeReport()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try report.jsonData()) as? [String: Any])
        json["schema"] = DeliveryReport.currentSchema + 1
        let bumped = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])

        XCTAssertThrowsError(try JSONDecoder().decode(DeliveryReport.self, from: bumped)) { error in
            guard let decodingError = error as? DecodingError,
                  case let .dataCorrupted(context) = decodingError else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("schema"), context.debugDescription)
        }
    }

    // MARK: - JSON shape

    func testReportJSONIsPrettySortedAndComplete() throws {
        let report = try makeReport()
        let data = try report.jsonData()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("\n"), "the report is pretty-printed, like the other sidecars")
        XCTAssertTrue(text.contains("\"schema\" : 1"))
        XCTAssertTrue(text.contains("\"profiles\""))
        XCTAssertTrue(text.contains("\"checks\""))
        XCTAssertTrue(text.contains("\"artifacts\""))
        XCTAssertTrue(text.contains("\"renderKey\""))
        XCTAssertTrue(text.contains("\"previewAgreement\""))
        XCTAssertTrue(text.contains("\"profiles\" : ["), "the top-level document is grouped by profile")
        XCTAssertEqual(try JSONDecoder().decode(DeliveryReport.self, from: data), report)
    }

    func testMeasuredValuesKeepTheirTypesAcrossJSON() throws {
        let values: [String: DeliveryReport.Value] = [
            "number": .number(2.5000001),
            "integer": .integer(6000),
            "text": .text("Display P3"),
            "boolean": .boolean(true),
            "ratio": .number(0.1094),
        ]
        let check = DeliveryReport.Check(name: "headroom", pass: true, detail: "typed values", measured: values)
        let report = try makeReport(checks: DeliveryReport.checkOrder.map { name in
            name == "headroom" ? check : DeliveryReport.Check(name: name, pass: true, detail: name)
        })
        let decoded = try JSONDecoder().decode(DeliveryReport.self, from: try report.jsonData())
        let roundTripped = try XCTUnwrap(decoded.check(profile: "8-full-rgb", named: "headroom"))
        XCTAssertEqual(roundTripped.measured, values)
    }

    func testWarningsAreRecordedWithoutChangingTheStatus() throws {
        let check = DeliveryReport.Check(
            name: "previewAgreement",
            pass: true,
            detail: "half-res band",
            warnings: ["half-res gain map: 12.3 % of pixels above ΔE 5"]
        )
        XCTAssertTrue(check.passed)
        XCTAssertEqual(check.warnings.count, 1)
    }

    // MARK: - Render facts

    func testCapEngagedReflectsWhetherTheAuthoredPeakReachedTheCap() throws {
        let engaged = DeliveryReport.Render(
            width: 10, height: 10, headroomCap: 2.5, authoredPeak: 2.5,
            fractionAboveOne: 0.1, fractionAtCap: 0.01, previewLongEdge: 2560
        )
        XCTAssertTrue(engaged.capEngaged)
        XCTAssertEqual(engaged.authoredPeakStops, log2(2.5), accuracy: 1e-12)

        let belowCap = DeliveryReport.Render(
            width: 10, height: 10, headroomCap: 2.5, authoredPeak: 1.8,
            fractionAboveOne: 0.1, fractionAtCap: 0, previewLongEdge: 2560
        )
        XCTAssertFalse(belowCap.capEngaged, "a recipe that never reaches its cap is recorded, not failed")
    }

    func testRecipeReferenceCarriesTheDeliveryFields() {
        let recipe = makeRecipe()
        let reference = DeliveryReport.RecipeReference(recipe: recipe, renderKey: "key")
        XCTAssertEqual(reference.created, recipe.created)
        XCTAssertEqual(reference.start, recipe.hdr.start)
        XCTAssertEqual(reference.liftStops, recipe.hdr.liftStops)
        XCTAssertEqual(reference.transition, recipe.hdr.transition)
        XCTAssertEqual(reference.headroomCap, recipe.hdr.headroomCap)
        XCTAssertEqual(reference.quality, recipe.encoder.quality)
        XCTAssertEqual(reference.depth, recipe.encoder.depth)
        XCTAssertEqual(reference.renderKey, "key")
    }
}
