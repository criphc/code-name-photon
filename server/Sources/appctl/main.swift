import Foundation
import ContractKit
import EngineKit
import ServerKit

// Temporary CLI, before any UI exists (docs/archive/stage-1/04-stage-1-plan.md M1/M2).
//
//   appctl prep    <source.tif> [--out DIR] [--recipe FILE] [--encoder PATH] [--preview-edge N]
//   appctl deliver <id | --source PATH> [--recipe FILE] [--out DIR] [--batch DIR] [--work DIR]
//                  [--encoder PATH] [--preview-edge N]
//   appctl serve   [--batch DIR] [--work DIR] [--port N] [--bind HOST] [--token T]
//
// stdout is the machine-readable process protocol for `serve` (exactly one ready line,
// ADR-0010); every human-facing line goes to stderr. `prep`/`deliver` keep printing their human
// output to stdout.
//
// Exit codes: 0 success, 1 failure (message on stderr), 2 usage error.

let exitCode = AppctlCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(exitCode)

enum AppctlCLI {
    static let usage = """
    appctl — HDR highlight finisher · Stage 1

    USAGE
      appctl prep    <source.tif> [options]    render one source (M1)
      appctl deliver <id | --source PATH>      full-resolution delivery: render, encode, verify (M4)
      appctl deliver --batch <dir>             deliver every item in the batch that has a stored recipe
      appctl serve   [options]                 serve the LAN HTTP API for the iPad (M2)

    PREP OPTIONS
      --out <dir>            output directory (default: work/<source sha256>/)
      --recipe <file.json>   use a saved recipe instead of documented defaults
      --encoder <path>       external toGainMapHDR oracle (default: the in-process Core Image writer)
      --preview-edge <px>    preview long edge (default: 2560)

    DELIVER OPTIONS
      <id>                   64-hex source sha256 within --batch (the id /api/items reports)
      --source <path>        use this source file instead of an item id
      --recipe <file.json>   recipe to apply (default: <work>/<source sha256>/recipe.json,
                             the recipe the iPad stored in M3)
      --out <dir>            flat delivery folder (default: out)
      --batch <dir>          folder of .tif/.tiff sources: the <id> lookup root, or — with no
                             <id> and no --source — the items to deliver (default: inbox)
      --work <dir>           per-item state root; also receives rejected/ diagnostics (default: work)
      --encoder <path>       external toGainMapHDR oracle (default: the in-process Core Image writer)
      --preview-edge <px>    preview long edge for the preview-delivery comparison (default: 2560)
      --profile <p>          output profile, repeatable (e.g. 10/half/rgb, 8/full/mono); every
                             item of a batch gets the same list

    DELIVER OUTPUT
      <out>/{stem}-hdr-{profile}.heic  gain-map HEIC per requested profile (e.g. 10-half-rgb)
      <out>/{stem}-sdr.heic            the same base with the gain map stripped by ImageIO (SDR fallback)
      <out>/{stem}.recipe.json         the exact recipe used, created preserved
      <out>/{stem}.report.json         delivery report schema 1 (profiles: [...] — every check of
                                       every profile with PASS/FAIL and measured values)
      Nothing is installed unless every check of every profile passes.

    BATCH MODE
      --batch <dir> with no <id> and no --source delivers every item that has a stored recipe at
      <work>/<sha256>/recipe.json. Items run one at a time; a failure does not stop the batch.
      Items without a stored recipe are skipped. Exit 1 if any item failed or none was deliverable.

    SERVE OPTIONS
      --batch <dir>          folder of .tif/.tiff sources (default: inbox)
      --work <dir>           per-item artifacts + state (default: work)
      --port <port>          TCP port (default: 8787)
      --bind <host>          interface (default: 0.0.0.0, LAN; 127.0.0.1 is loopback-only)
      --token <token>        bearer token (default: $PHOTON_APPCTL_TOKEN, $PHOTON_TOKEN or a
                             generated one, printed on stderr)
      --preview-edge <px>    preview base long edge (default: 2560)
      Thumbnails for the whole batch are warmed in the background (4 at a time) once the ready
      line is written; there is no flag to turn that off.

    ENDPOINTS (M2; every route except /api/health needs Authorization: Bearer <token>)
      GET  /api/health                    GET  /api/items
      GET  /api/items/{id}                GET  /api/items/{id}/status
      POST /api/items/{id}/prepare        GET  /api/items/{id}/preview
      GET  /api/items/{id}/meta           GET|POST /api/items/{id}/recipe
      GET  /api/items/{id}/thumbnail      512-high Display P3 HEIC (filmstrip; never prepares)

    COMMON
      -h, --help             this help
    """

    // MARK: - Entry point

    static func run(arguments: [String]) -> Int32 {
        do {
            switch try parse(arguments) {
            case .help:
                print(usage)
                return 0
            case let .prep(options):
                return try execute(options)
            case let .deliver(options):
                return try executeDeliver(options)
            case let .serve(options):
                return try executeServe(options)
            }
        } catch let usageError as UsageError {
            writeError(usageError.message)
            writeError("")
            writeError(usage)
            return 2
        } catch {
            writeError("appctl: \(describe(error))")
            return 1
        }
    }

    // MARK: - Parsing

    private struct ParsedOptions {
        var sourcePath: String
        var outputDirectory: String?
        var recipePath: String?
        var encoderPath: String?
        var previewLongEdge = 2560
    }

    private enum ParseOutcome {
        case help
        case prep(ParsedOptions)
        case deliver(DeliverOptions)
        case serve(ServeOptions)
    }

    private struct DeliverOptions {
        var itemID: String?
        var sourcePath: String?
        var recipePath: String?
        var outputDirectory = "out"
        /// `nil` = `--batch` was not given. It is optional, not defaulted to "inbox", because an
        /// explicit `--batch` is what turns a bare `deliver` into a batch delivery.
        var batchDirectory: String?
        var workDirectory = "work"
        var encoderPath: String?
        var profileStrings: [String] = []
        var previewLongEdge = 2560

        /// No single input, and `--batch` was given explicitly: deliver the whole folder.
        var isBatch: Bool {
            itemID == nil && sourcePath == nil && batchDirectory != nil
        }

        /// The id lookup root; `inbox` is the documented default when `--batch` is omitted.
        var batchLookupDirectory: String {
            batchDirectory ?? "inbox"
        }
    }

    private struct ServeOptions {
        var batchDirectory = "inbox"
        var workDirectory = "work"
        var port: UInt16 = 8787
        var bindHost = "0.0.0.0"
        var token: String?
        var previewLongEdge = 2560
    }

    private struct UsageError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private static func parse(_ arguments: [String]) throws -> ParseOutcome {
        guard let command = arguments.first else {
            throw UsageError("missing command (expected 'prep')")
        }
        if command == "-h" || command == "--help" {
            return .help
        }
        if command == "serve" {
            if arguments.dropFirst().contains(where: { $0 == "-h" || $0 == "--help" }) {
                return .help
            }
            return .serve(try parseServe(Array(arguments.dropFirst())))
        }
        if command == "deliver" {
            if arguments.dropFirst().contains(where: { $0 == "-h" || $0 == "--help" }) {
                return .help
            }
            return .deliver(try parseDeliver(Array(arguments.dropFirst())))
        }
        guard command == "prep" else {
            throw UsageError("unknown command '\(command)' (expected 'prep', 'deliver' or 'serve')")
        }

        var options = ParsedOptions(sourcePath: "")
        var positional: [String] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                return .help
            case "--out":
                options.outputDirectory = try nextValue(for: argument, arguments: arguments, index: &index)
            case "--recipe":
                options.recipePath = try nextValue(for: argument, arguments: arguments, index: &index)
            case "--encoder":
                options.encoderPath = try nextValue(for: argument, arguments: arguments, index: &index)
            case "--preview-edge":
                let raw = try nextValue(for: argument, arguments: arguments, index: &index)
                guard let value = Int(raw), value > 0 else {
                    throw UsageError("--preview-edge expects a positive integer, got '\(raw)'")
                }
                options.previewLongEdge = value
            default:
                guard !argument.hasPrefix("-") else {
                    throw UsageError("unknown option '\(argument)'")
                }
                positional.append(argument)
            }
            index += 1
        }

        guard !positional.isEmpty else {
            throw UsageError("missing <source.tif>")
        }
        guard positional.count == 1 else {
            throw UsageError("unexpected extra arguments: \(positional.dropFirst().joined(separator: " "))")
        }
        options.sourcePath = positional[0]
        return .prep(options)
    }

    private static func parseServe(_ arguments: [String]) throws -> ServeOptions {
        var options = ServeOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--batch":
                options.batchDirectory = try nextValue(for: argument, arguments: arguments, index: &index)
            case "--work":
                options.workDirectory = try nextValue(for: argument, arguments: arguments, index: &index)
            case "--port":
                let raw = try nextValue(for: argument, arguments: arguments, index: &index)
                guard let value = UInt16(raw), value > 0 else {
                    throw UsageError("--port expects 1...65535, got '\(raw)'")
                }
                options.port = value
            case "--bind":
                options.bindHost = try nextValue(for: argument, arguments: arguments, index: &index)
            case "--token":
                options.token = try nextValue(for: argument, arguments: arguments, index: &index)
            case "--preview-edge":
                let raw = try nextValue(for: argument, arguments: arguments, index: &index)
                guard let value = Int(raw), value > 0 else {
                    throw UsageError("--preview-edge expects a positive integer, got '\(raw)'")
                }
                options.previewLongEdge = value
            default:
                throw UsageError("unknown option '\(argument)' for 'serve'")
            }
            index += 1
        }
        return options
    }

    private static func parseDeliver(_ arguments: [String]) throws -> DeliverOptions {
        var options = DeliverOptions()
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                throw UsageError("help")
            case "--source":
                options.sourcePath = try nextValue(for: argument, arguments: arguments, index: &index)
            case "--recipe":
                options.recipePath = try nextValue(for: argument, arguments: arguments, index: &index)
            case "--out":
                options.outputDirectory = try nextValue(for: argument, arguments: arguments, index: &index)
            case "--batch":
                options.batchDirectory = try nextValue(for: argument, arguments: arguments, index: &index)
            case "--work":
                options.workDirectory = try nextValue(for: argument, arguments: arguments, index: &index)
            case "--encoder":
                options.encoderPath = try nextValue(for: argument, arguments: arguments, index: &index)
            case "--profile":
                options.profileStrings.append(try nextValue(for: argument, arguments: arguments, index: &index))
            case "--preview-edge":
                let raw = try nextValue(for: argument, arguments: arguments, index: &index)
                guard let value = Int(raw), value > 0 else {
                    throw UsageError("--preview-edge expects a positive integer, got '\(raw)'")
                }
                options.previewLongEdge = value
            default:
                guard !argument.hasPrefix("-") else {
                    throw UsageError("unknown option '\(argument)' for 'deliver'")
                }
                positional.append(argument)
            }
            index += 1
        }

        if let itemID = positional.first {
            guard positional.count == 1 else {
                throw UsageError("unexpected extra arguments: \(positional.dropFirst().joined(separator: " "))")
            }
            guard itemID.count == 64, itemID.allSatisfy({ $0.isHexDigit }) else {
                throw UsageError("'\(itemID)' is not an item id (a 64-hex source sha256); pass --source <path> instead")
            }
            options.itemID = itemID
        }
        if options.isBatch {
            // Batch mode uses each item's stored recipe; a single --recipe would silently apply to
            // every item, so reject it instead of guessing.
            guard options.recipePath == nil else {
                throw UsageError("--recipe applies to a single delivery; batch mode uses each item's stored recipe")
            }
            return options
        }
        guard (options.itemID == nil) != (options.sourcePath == nil) else {
            throw UsageError("deliver needs exactly one input: <id> (the source sha256 from /api/items), --source <path>, or --batch <dir> to deliver every item that has a stored recipe")
        }
        return options
    }

    private static func nextValue(for option: String, arguments: [String], index: inout Int) throws -> String {
        guard index + 1 < arguments.count else {
            throw UsageError("missing value for \(option)")
        }
        index += 1
        return arguments[index]
    }

    // MARK: - Execution

    private static func execute(_ options: ParsedOptions) throws -> Int32 {
        let sourceURL = URL(fileURLWithPath: options.sourcePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw PhotonError.sourceUnreadable(path: options.sourcePath, reason: "file does not exist")
        }

        // `--encoder` selects the external tool as the migration oracle; the default is the
        // in-process Core Image writer.
        let encoder: HEICEncoder
        let encoderVersion: String
        if let encoderPath = options.encoderPath {
            let url = try Encoder.resolveExecutable(explicit: URL(fileURLWithPath: encoderPath))
            encoder = ExternalToolEncoder(executableURL: url)
            encoderVersion = resolveEncoderVersion(executable: url)
        } else {
            encoder = CoreImageHEICEncoder()
            encoderVersion = "coreimage-1"
        }

        var recipe: Recipe?
        if let recipePath = options.recipePath {
            recipe = try loadRecipe(from: URL(fileURLWithPath: recipePath))
        }

        let pipeline = try Pipeline(encoderVersion: encoderVersion, encoder: encoder)
        let pipelineOptions = PipelineOptions(
            outputDirectory: options.outputDirectory.map { URL(fileURLWithPath: $0) },
            previewLongEdge: options.previewLongEdge
        )
        let result = try pipeline.prepare(sourceURL: sourceURL, recipe: recipe, options: pipelineOptions)
        let metadata = try loadMetadata(from: result.metadataJSON)

        print("sdr.tif        \(result.sdrTIFF.path)")
        print("hdr.tif        \(result.hdrTIFF.path)")
        print("preview.heic   \(result.previewHEIC.path)")
        print("meta.json      \(result.metadataJSON.path)")
        print(String(format: "authored peak  %.6f linear (%.6f stops)", metadata.render.authoredPeakLinear, metadata.render.authoredPeakStops))
        print(String(format: "total          %.2f s", result.timings.totalSeconds))
        return 0
    }

    private static func loadRecipe(from url: URL) throws -> Recipe {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PhotonError.invalidRecipe(field: "recipe", reason: "cannot read '\(url.path)': \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(Recipe.self, from: data)
        } catch {
            throw PhotonError.invalidRecipe(field: "recipe", reason: "cannot decode '\(url.path)': \(error)")
        }
    }

    private static func loadMetadata(from url: URL) throws -> PrepMetadata {
        do {
            return try JSONDecoder().decode(PrepMetadata.self, from: try Data(contentsOf: url))
        } catch {
            throw PhotonError.sourceUnreadable(path: url.path, reason: "cannot read the metadata just written: \(error)")
        }
    }

    // MARK: - Encoder version

    /// `PHOTON_ENCODER_VERSION` → the encoder clone's git short sha → "unknown".
    ///
    /// The tool is an independent clone (`tools/toGainMapHDR/` is gitignored by this repo), so
    /// only ask git when that clone has a `.git`: otherwise git would walk up and report *this*
    /// repository's commit as if it were the encoder's.
    static func resolveEncoderVersion(executable: URL) -> String {
        if let fromEnvironment = ProcessInfo.processInfo.environment["PHOTON_ENCODER_VERSION"],
           !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        let repository = executable.deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git").path) else {
            return "unknown"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", repository.path, "rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "unknown"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "unknown" }
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return output.isEmpty ? "unknown" : output
    }

    // MARK: - Delivery (M4)

    /// `appctl deliver`: the explicit Mac-side delivery trigger (docs/reference/deliver.md, delivery contract).
    ///
    /// One input (`<id>` or `--source`) is a single delivery with the detailed report on stdout;
    /// `--batch` with neither is a batch delivery of every item that has a stored recipe. Both paths
    /// share `deliverOne`, so a batch item is exactly the delivery a single run would have done.
    private static func executeDeliver(_ options: DeliverOptions) throws -> Int32 {
        if options.isBatch {
            return try executeDeliverBatch(options)
        }

        let sourceURL: URL
        if let sourcePath = options.sourcePath {
            sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        } else if let itemID = options.itemID {
            sourceURL = try BatchLookup.sourceURL(
                forID: itemID,
                in: URL(fileURLWithPath: options.batchLookupDirectory)
            )
        } else {
            throw UsageError("deliver needs <id>, --source <path> or --batch <dir>")
        }

        let run = try makeDeliveryRun(options)
        let outcome = try deliverOne(sourceURL: sourceURL, recipePath: options.recipePath, in: run)
        printDelivery(outcome, sourceURL: sourceURL, outputDirectory: run.outputDirectory)
        return 0
    }

    /// Everything one delivery run shares with the next: where state and output live, the encoder
    /// instance and the requested profiles. Batch mode builds it once and reuses it for every item.
    private struct DeliveryRun {
        var encoder: HEICEncoder
        var encoderVersion: String
        var profiles: [HEICEncodeOptions]
        var workDirectory: URL
        var outputDirectory: URL
        var previewLongEdge: Int
    }

    private static func makeDeliveryRun(_ options: DeliverOptions) throws -> DeliveryRun {
        // `--encoder` selects the external tool as the migration oracle; the default is the
        // in-process Core Image writer.
        let encoder: HEICEncoder
        let encoderVersion: String
        if let encoderPath = options.encoderPath {
            let url = try Encoder.resolveExecutable(explicit: URL(fileURLWithPath: encoderPath))
            encoder = ExternalToolEncoder(executableURL: url)
            encoderVersion = resolveEncoderVersion(executable: url)
        } else {
            encoder = CoreImageHEICEncoder()
            encoderVersion = "coreimage-1"
        }

        let profiles = try options.profileStrings.map { string -> HEICEncodeOptions in
            guard let profile = HEICEncodeOptions(profileString: string) else {
                throw UsageError("invalid --profile '\(string)'; use e.g. 10/half/rgb, 8/full/mono")
            }
            return profile
        }

        return DeliveryRun(
            encoder: encoder,
            encoderVersion: encoderVersion,
            profiles: profiles,
            workDirectory: URL(fileURLWithPath: options.workDirectory).standardizedFileURL,
            outputDirectory: URL(fileURLWithPath: options.outputDirectory).standardizedFileURL,
            previewLongEdge: options.previewLongEdge
        )
    }

    /// One delivery: render at full resolution, encode, verify, install — or install nothing and
    /// throw `PhotonError.deliveryVerificationFailed` with the report left in the work folder.
    private static func deliverOne(
        sourceURL: URL,
        recipePath: String?,
        in run: DeliveryRun
    ) throws -> DeliveryOutcome {
        let configuration = DeliveryConfiguration(
            sourcePath: sourceURL,
            recipePath: recipePath.map { URL(fileURLWithPath: $0) },
            workDirectory: run.workDirectory,
            outputDirectory: run.outputDirectory,
            profiles: run.profiles,
            encoderVersion: run.encoderVersion,
            previewLongEdge: run.previewLongEdge
        )
        return try DeliveryPipeline(encoder: run.encoder).deliver(configuration)
    }

    /// The single-item report: one line per fact, the format callers already parse.
    private static func printDelivery(
        _ outcome: DeliveryOutcome,
        sourceURL: URL,
        outputDirectory: URL
    ) {
        let report = outcome.report

        print("appctl deliver · \(sourceURL.lastPathComponent)")
        print("  source       \(report.source.path)")
        print("               sha256 \(report.source.sha256)  \(report.source.width)x\(report.source.height)  \(report.source.profileName ?? "unknown profile")  \(report.source.bitsPerComponent)-bit")
        print("  recipe       renderKey \(report.recipe.renderKey)")
        print("               start \(formatNumber(report.recipe.start, 4))  lift \(formatNumber(report.recipe.liftStops, 4)) stops  transition \(formatNumber(report.recipe.transition, 4))  cap \(formatNumber(report.recipe.headroomCap, 4))")
        print("  sdr.heic     \(outcome.artifacts.sdrHEIC.path)")
        print("               \(report.profiles.first?.artifacts.sdrHEIC.bytes ?? 0) B  sha256 \(report.profiles.first?.artifacts.sdrHEIC.sha256 ?? "")")
        print("  recipe.json  \(outcome.artifacts.recipeJSON.path)")
        print("  report.json  \(outcome.artifacts.reportJSON.path)")

        for profile in report.profiles {
            let hdrPath = outcome.artifacts.hdrHEICs[profile.profile.name]?.path ?? "?"
            print("  [\(profile.profile.name)] \(hdrPath)")
            print("               \(profile.artifacts.hdrHEIC.bytes) B  sha256 \(profile.artifacts.hdrHEIC.sha256)")
            print("  checks       " + profile.checks.map { "\($0.name)=\($0.status.rawValue)" }.joined(separator: " "))
            if let headroom = profile.checks.first(where: { $0.name == "headroom" }) {
                print("  headroom     authored \(formatNumber(profile.render.authoredPeak, 6)) linear (\(formatNumber(profile.render.authoredPeakStops, 6)) stops), advertised \(formatNumber(number(headroom.measured["contentHeadroom"]), 6)), expected \(formatNumber(number(headroom.measured["expectedHeadroom"]), 6))")
            }
            if let base = profile.checks.first(where: { $0.name == "baseDeltaE" }) {
                print("  base ΔE2000  mean \(formatNumber(number(base.measured["mean"]), 4))  p95 \(formatNumber(number(base.measured["p95"]), 4))  max \(formatNumber(number(base.measured["max"]), 4))")
            }
            if let preview = profile.checks.first(where: { $0.name == "previewAgreement" }) {
                print("  preview ΔE   mean \(formatNumber(number(preview.measured["mean"]), 4))  p95 \(formatNumber(number(preview.measured["p95"]), 4))  (preview long edge \(profile.render.previewLongEdge) px)")
            }
            let warnings = profile.checks.flatMap(\.warnings)
            if !warnings.isEmpty {
                print("  warnings     " + warnings.joined(separator: "; "))
            }
            print(String(
                format: "  timings      decode %.2f s + render %.2f s + preview %.2f s + encode %.2f s + verify %.2f s = %.2f s",
                profile.timings.decodeSeconds,
                profile.timings.renderSeconds,
                profile.timings.previewSeconds,
                profile.timings.encodeSeconds,
                profile.timings.verifySeconds,
                profile.timings.totalSeconds
            ))
        }
        let checkCount = report.profiles.reduce(0) { $0 + $1.checks.count }
        print("  result       PASS (\(report.profiles.count) profile(s), \(checkCount) checks) — installed in \(outputDirectory.path)")
    }

    // MARK: - Delivery (batch)

    /// `appctl deliver --batch <dir>`: deliver every item that has a stored recipe, one at a time.
    ///
    /// Serial by design (docs/plans/v2-plan.md: memory first, no item/profile concurrency). A failed
    /// item does not stop the batch — the evidence stays in `work/<sha>/rejected/<renderKey12>/` and
    /// the summary on stdout says which item it was. An item without a stored recipe is skipped, not
    /// failed: the iPad has not posted one for it yet.
    private static func executeDeliverBatch(_ options: DeliverOptions) throws -> Int32 {
        let batchURL = URL(fileURLWithPath: options.batchLookupDirectory).standardizedFileURL
        let run = try makeDeliveryRun(options)
        let items = try BatchLookup.items(in: batchURL)

        print("appctl deliver --batch · \(items.count) item(s) in \(batchURL.path)")

        // Pad the names so PASS/FAIL/skip line up: a batch summary is read as a table.
        let nameWidth = items.map(\.url.lastPathComponent.count).max() ?? 0
        var passed = 0
        var failed = 0
        var skipped = 0

        for (offset, item) in items.enumerated() {
            let name = item.url.lastPathComponent
            let paddedName = name + String(repeating: " ", count: max(0, nameWidth - name.count))
            let label = "[\(offset + 1)/\(items.count)] \(paddedName)"

            let storedRecipe = run.workDirectory
                .appendingPathComponent(item.sha256, isDirectory: true)
                .appendingPathComponent("recipe.json")
            guard FileManager.default.fileExists(atPath: storedRecipe.path) else {
                print("  \(label)  skip  no stored recipe")
                skipped += 1
                continue
            }

            let start = Date()
            do {
                let outcome = try deliverOne(sourceURL: item.url, recipePath: nil, in: run)
                let seconds = Date().timeIntervalSince(start)
                let profiles = outcome.report.profiles
                    .map { profileLabel($0.profile) }
                    .joined(separator: ", ")
                print("  \(label)  PASS  [\(profiles)]  \(String(format: "%.1f", seconds)) s")
                passed += 1
            } catch {
                print("  \(label)  FAIL  \(describe(error))\(evidenceSuffix(for: error))")
                failed += 1
            }
        }

        guard passed + failed > 0 else {
            print("  result       0 passed, 0 failed, \(skipped) skipped — nothing to deliver")
            writeError("appctl deliver --batch: no item in \(batchURL.path) has a stored recipe at \(run.workDirectory.path)/<sha256>/recipe.json; nothing was delivered")
            return 1
        }

        print("  result       \(passed) passed, \(failed) failed, \(skipped) skipped — installed in \(run.outputDirectory.path)")
        return failed == 0 ? 0 : 1
    }

    /// `10/half/rgb` — the `--profile` spelling, not the artifact suffix (`10-half-rgb`).
    private static func profileLabel(_ reference: DeliveryReport.ProfileReference) -> String {
        let kind = reference.mapKind == HEICEncodeOptions.MapKind.isoRGB.rawValue ? "rgb" : "mono"
        return "\(reference.bitDepth)/\(reference.mapResolution)/\(kind)"
    }

    /// The rejected-evidence folder a failed delivery left behind, when it left one. A failure that
    /// never reached the verifier (unreadable source, bad recipe) has no evidence to point at, so
    /// the suffix is omitted rather than guessed.
    private static func evidenceSuffix(for error: Error) -> String {
        guard let photonError = error as? PhotonError,
              case let .deliveryVerificationFailed(reportPath, _) = photonError else {
            return ""
        }
        let directory = URL(fileURLWithPath: reportPath).deletingLastPathComponent()
        return " (evidence \(directory.path))"
    }

    /// `nil` renders as "n/a" so a report without a value cannot look like a measurement of 0.
    private static func number(_ value: DeliveryReport.Value?) -> Double? {
        value?.numberValue
    }

    private static func formatNumber(_ value: Double?, _ decimals: Int) -> String {
        guard let value, value.isFinite else { return "n/a" }
        return String(format: "%.\(decimals)f", value)
    }

    // MARK: - Serve (M2)

    private static func executeServe(_ options: ServeOptions) throws -> Int32 {
        let batchURL = URL(fileURLWithPath: options.batchDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: batchURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw UsageError("batch directory '\(options.batchDirectory)' does not exist (pass --batch <dir>; M2 does not watch a folder yet)")
        }
        let workURL = URL(fileURLWithPath: options.workDirectory).standardizedFileURL
        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)

        // M2 never encodes: only the version string is needed, for the recipe defaults' provenance.
        let encoderVersion = resolveEncoderVersionFromRepo()

        let token = try resolveServeToken(explicit: options.token)

        let config = try ServerConfig(
            batchDirectory: batchURL,
            workDirectory: workURL,
            token: token,
            bindHost: options.bindHost,
            port: options.port,
            previewLongEdge: options.previewLongEdge,
            encoderVersion: encoderVersion
        )
        let store = try ItemStore(config: config)
        let router = APIRouter(store: store, token: config.token, appVersion: config.appVersion)

        let server = try HTTPServer(bindHost: config.bindHost, port: config.port) { request in
            router.handle(request)
        }
        try server.start()

        // ADR-0010: the supervisor reads exactly one JSON line from stdout and ignores a vanished
        // reader, so SIGPIPE must not kill the process after the handshake.
        signal(SIGPIPE, SIG_IGN)

        // Human-facing output goes to stderr; stdout carries the process protocol only.
        let displayHost = config.bindHost == "0.0.0.0" ? "<mac-lan-ip>" : config.bindHost
        writeError("appctl serve · M2 (Stage 1 prototype)")
        writeError("  batch     \(config.batchDirectory.path)")
        writeError("  work      \(config.workDirectory.path)")
        writeError("  listen    http://\(displayHost):\(server.port)/")
        writeError("  token     \(config.token)")
        writeError("  auth      Authorization: Bearer <token> (or X-Photon-Token: <token>)")
        writeError("  press Ctrl-C or send SIGTERM to stop")

        // Installed before the handshake: a SIGTERM that races the supervisor's first read is
        // queued on the main queue (serviced by dispatchMain below), never the default action.
        installTerminationHandlers(server: server)

        // The ready event is the only thing `serve` ever writes to stdout: one line, flushed.
        // `JSONEncoder` defaults (no sorted/pretty keys) match `ProcessEvent`'s wire shape; the
        // direct `FileHandle` write is unbuffered, so the supervisor sees the line immediately.
        let ready = ReadyEvent(port: Int(server.port), pid: Int(getpid()))
        var line = try JSONEncoder().encode(ready)
        line.append(0x0A)
        FileHandle.standardOutput.write(line)

        // ADR-0013: warm the filmstrip thumbnails in the background, after the handshake so it can
        // never delay the ready line, and before `dispatchMain()` so the process keeps running.
        startThumbnailWarmup(store: store)

        dispatchMain()
    }

    // MARK: - Serve warm-up

    /// Strong reference: `executeServe` parks in `dispatchMain()` rather than returning, but the
    /// queue must be retained for its operations to keep running.
    private static var warmupQueue: OperationQueue?

    /// Renders every item's filmstrip thumbnail in the background, four at a time (ADR-0013 §6).
    ///
    /// Always on — there is no flag to disable it. Progress and failures go to stderr (stdout is
    /// the process protocol), and a failed thumbnail changes nothing: `ItemStore.thumbnail` never
    /// persists a failure, so the item keeps its state and the filmstrip falls back to the file
    /// name. The listing runs on the queue too, so `executeServe` reaches `dispatchMain()` without
    /// hashing the batch first; `/api/health` uses its own lock and answers throughout.
    private static func startThumbnailWarmup(store: ItemStore) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        warmupQueue = queue

        queue.addOperation {
            let items: [ItemSummary]
            do {
                items = try store.listItems()
            } catch {
                writeError("  warm-up   skipped: cannot list the batch: \(describe(error))")
                return
            }
            guard !items.isEmpty else { return }
            writeError("  warm-up   \(items.count) thumbnail(s), 4 at a time")

            let progress = ServeWarmupProgress(total: items.count)
            for item in items {
                queue.addOperation {
                    let outcome: String
                    do {
                        outcome = "\(try store.thumbnail(id: item.id).count) B"
                    } catch {
                        outcome = "failed: \(describe(error))"
                    }
                    writeError("  warm-up   " + progress.record(name: item.name, outcome: outcome))
                }
            }
        }
    }

    // MARK: - Serve token

    /// `--token` > `$PHOTON_APPCTL_TOKEN` > `$PHOTON_TOKEN` > generated (ADR-0010, P2 plan §2.5).
    ///
    /// Empty environment values are unset, matching `ServeToken.resolve`'s `$PHOTON_TOKEN`
    /// semantics. The generated token is only ever written to stderr by `executeServe`.
    private static func resolveServeToken(explicit: String?) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let variable = ["PHOTON_APPCTL_TOKEN", "PHOTON_TOKEN"].first { name in
            guard let value = environment[name] else { return false }
            return !value.isEmpty
        }
        do {
            return try ServeToken.resolve(explicit: explicit, environment: variable.flatMap { environment[$0] })
        } catch ServeTokenError.invalidExplicitToken {
            throw UsageError("--token must not be empty or contain whitespace; omit it to generate a token")
        } catch ServeTokenError.invalidEnvironmentToken {
            throw UsageError("$\(variable ?? "PHOTON_APPCTL_TOKEN") is set but is not a valid token (non-empty, no whitespace); unset it to generate one")
        }
    }

    // MARK: - Serve shutdown

    /// Strong references: a `DispatchSourceSignal` stops delivering events once deallocated, and
    /// `executeServe` parks in `dispatchMain()` rather than returning.
    private static var terminationSources: [DispatchSourceSignal] = []

    /// SIGTERM/SIGINT → `server.stop()` → `exit(0)`. No stdout is written on the way out.
    ///
    /// `HTTPServer.stop()` waits (bounded) for the listener's `.cancelled` state on its own queue,
    /// so calling it from the main queue cannot deadlock.
    private static func installTerminationHandlers(server: HTTPServer) {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for signalNumber in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                server.stop()
                exit(0)
            }
            source.resume()
            terminationSources.append(source)
        }
    }

    // MARK: - Encoder version (serve)

    /// `PHOTON_ENCODER_VERSION` → the encoder clone found by walking up from the CWD → "unknown".
    ///
    /// M2 does not run the encoder, but recipe v0 records its commit for M4 provenance.
    static func resolveEncoderVersionFromRepo() -> String {
        if let fromEnvironment = ProcessInfo.processInfo.environment["PHOTON_ENCODER_VERSION"],
           !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        while true {
            let candidate = directory.appendingPathComponent("tools/toGainMapHDR/bin/toGainMapHDR")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return resolveEncoderVersion(executable: candidate)
            }
            if directory.path == "/" { break }
            directory = directory.deletingLastPathComponent()
        }
        return "unknown"
    }

    // MARK: - Errors

    static func describe(_ error: Error) -> String {
        if let photonError = error as? PhotonError {
            return photonError.description
        }
        return String(describing: error)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Thread-safe `[n/total]` counter for the `serve` warm-up's stderr progress lines.
///
/// The warm-up renders four items at a time on an `OperationQueue`, so the completed count is
/// shared state; the lock makes the printed index monotonic without serialising the renders.
private final class ServeWarmupProgress {
    private let lock = NSLock()
    private let total: Int
    private var completed = 0

    init(total: Int) {
        self.total = total
    }

    /// `[3/20] R0003777-P3.tif  154 KB`
    func record(name: String, outcome: String) -> String {
        lock.lock()
        completed += 1
        let index = completed
        lock.unlock()
        return "[\(index)/\(total)] \(name)  \(outcome)"
    }
}
