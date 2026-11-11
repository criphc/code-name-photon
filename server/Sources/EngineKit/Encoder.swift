import Foundation

/// Shell-out configuration for the external `tools/toGainMapHDR`.
///
/// v2 the production writer is `CoreImageHEICEncoder`; this shell-out is the migration **oracle**
/// (selected by `appctl deliver --encoder`), kept only for differential comparison until the new
/// engine has been exercised on real deliveries.
public struct EncoderConfiguration: Equatable, Sendable {
    public let executableURL: URL
    public let quality: Double
    public let depth: Int

    /// - Parameters:
    ///   - quality: `-q`, 0…1.
    ///   - depth: `-d`, 8 (stage 1 delivers 8) or 10.
    /// - Throws: `PhotonError.invalidRecipe` — these are recipe fields (`encoder.quality`,
    ///   `encoder.depth` in docs/reference/recipe.md), so the recipe error case is the closest fit and gives M2
    ///   the same user-presentable message as a bad recipe file.
    public init(executableURL: URL, quality: Double = 0.85, depth: Int = 8) throws {
        guard quality.isFinite, (0...1).contains(quality) else {
            throw PhotonError.invalidRecipe(
                field: "encoder.quality",
                reason: "must be in 0...1, got \(quality)"
            )
        }
        guard depth == 8 || depth == 10 else {
            throw PhotonError.invalidRecipe(field: "encoder.depth", reason: "must be 8 or 10, got \(depth)")
        }
        self.executableURL = executableURL
        self.quality = quality
        self.depth = depth
    }
}

/// Drives the external encoder (oracle only): `toGainMapHDR <hdr> <outdir> -b <base> -R <cap> -d 8 -q 0.85 -c p3`.
///
/// Hard constraints from M0 (docs/reference/encoder.md — do not re-derive):
/// - always pass `-b`; never pass `-H`;
/// - `-R` is inert in the `-b` path, so the cap must already be authored into the HDR pixels;
/// - the HDR input must be a 4-channel `RGBAf` float TIFF (`TIFFWriter.writeHDR`).
public struct Encoder {
    public let configuration: EncoderConfiguration

    /// The repo-relative location, used both for the search and for the error message.
    public static let defaultRelativePath = "tools/toGainMapHDR/bin/toGainMapHDR"

    /// `-c p3`: the delivered base is Display P3 (docs/reference/colour.md).
    public static let colorSpaceArgument = "p3"

    public init(configuration: EncoderConfiguration) {
        self.configuration = configuration
    }

    /// Finds the encoder executable: explicit path → `PHOTON_ENCODER` env → repo-relative
    /// `tools/toGainMapHDR/bin/toGainMapHDR` found in the current directory or one of its parents.
    ///
    /// The parent walk means the same code works from `server/` (the tests) and from the repo root
    /// (the CLI/docs examples) without a flag.
    ///
    /// - Throws: `PhotonError.encoderMissing` with the path that was asked for / searched.
    public static func resolveExecutable(
        explicit: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let explicit {
            // An explicitly requested path is a user instruction: fail loudly, do not fall through.
            guard isExecutable(explicit) else {
                throw PhotonError.encoderMissing(path: explicit.path)
            }
            return explicit.standardizedFileURL
        }

        if let fromEnvironment = environment["PHOTON_ENCODER"], !fromEnvironment.isEmpty {
            let candidate = URL(fileURLWithPath: fromEnvironment)
            guard isExecutable(candidate) else {
                throw PhotonError.encoderMissing(path: candidate.path)
            }
            return candidate.standardizedFileURL
        }

        let fileManager = FileManager.default
        var directory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        while true {
            let candidate = directory.appendingPathComponent(Self.defaultRelativePath)
            if isExecutable(candidate) {
                return candidate.standardizedFileURL
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent.path == directory.path { break }
            directory = parent
        }

        throw PhotonError.encoderMissing(path: Self.defaultRelativePath)
    }

    /// True when `url` exists and is an executable regular file.
    public static func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Encodes `hdrTIFF` with `baseTIFF` as the preserved SDR base.
    ///
    /// - Parameter headroomCap: the recipe cap (linear). Passed as `-R` for command fidelity;
    ///   M0 measured `-R` is inert with `-b`, so the cap must already be authored into the pixels.
    /// - Returns: the written HEIC URL (the tool names it after the HDR TIFF's stem).
    /// - Throws: `PhotonError.encoderFailed` (with captured stderr) on non-zero exit,
    ///   `PhotonError.encoderOutputMissing` if exit 0 but no HEIC appeared.
    public func encode(hdrTIFF: URL, baseTIFF: URL, outputDirectory: URL, headroomCap: Double) throws -> URL {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            throw PhotonError.writeFailed(path: outputDirectory.path, reason: "cannot create output directory: \(error)")
        }

        // The tool names its output after the HDR input's stem. Delete any stale file so a
        // leftover from an earlier run can never masquerade as this run's output.
        let expectedHEIC = outputDirectory
            .appendingPathComponent(hdrTIFF.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("heic")
        try? fileManager.removeItem(at: expectedHEIC)

        let arguments = Self.arguments(
            hdrTIFF: hdrTIFF,
            baseTIFF: baseTIFF,
            outputDirectory: outputDirectory,
            headroomCap: headroomCap,
            configuration: configuration
        )

        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let captured: String
        do {
            try process.run()
        } catch {
            throw PhotonError.encoderFailed(exitCode: -1, stderr: "failed to launch encoder: \(error)")
        }
        // Drain before waiting: the tool writes progress to stdout and a full pipe buffer would
        // deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        captured = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw PhotonError.encoderFailed(
                exitCode: process.terminationStatus,
                stderr: captured.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        if fileManager.fileExists(atPath: expectedHEIC.path) {
            return expectedHEIC
        }
        // Defensive fallback (the tool is not ours to pin): accept the first HEIC that appeared.
        if let entries = try? fileManager.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil),
           let firstHEIC = entries
               .filter({ $0.pathExtension.lowercased() == "heic" })
               .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
               .first,
           fileManager.fileExists(atPath: firstHEIC.path) {
            return firstHEIC
        }
        throw PhotonError.encoderOutputMissing(path: expectedHEIC.path)
    }

    /// The exact documented argument vector (docs/reference/encoder.md). Never contains `-H`.
    public static func arguments(
        hdrTIFF: URL,
        baseTIFF: URL,
        outputDirectory: URL,
        headroomCap: Double,
        configuration: EncoderConfiguration
    ) -> [String] {
        [
            hdrTIFF.path,
            outputDirectory.path,
            "-b", baseTIFF.path,
            "-R", number(headroomCap),
            "-d", String(configuration.depth),
            "-q", number(configuration.quality),
            "-c", colorSpaceArgument,
        ]
    }

    /// Shortest round-trip decimal for a JSON-ish number: `0.85`, `2.5`, `8`.
    /// Keeps the command line stable regardless of `Double` → `String` formatting choices.
    static func number(_ value: Double) -> String {
        value.description
    }
}
