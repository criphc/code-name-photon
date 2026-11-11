import Foundation

/// `meta.json`: everything M2 needs to list a batch item and M4 needs to re-render.
///
/// Field names are part of M2's HTTP contract from here on: change them only with a schema bump.
public struct PrepMetadata: Codable, Equatable, Sendable {
    public static let currentSchema = 0

    public struct SourceInfo: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public let width: Int
        public let height: Int
        public let profileName: String?
        public let bitsPerComponent: Int

        public init(path: String, sha256: String, width: Int, height: Int, profileName: String?, bitsPerComponent: Int) {
            self.path = path
            self.sha256 = sha256
            self.width = width
            self.height = height
            self.profileName = profileName
            self.bitsPerComponent = bitsPerComponent
        }
    }

    public struct OutputFile: Codable, Equatable, Sendable {
        public let path: String
        public let bytes: Int
        public let sha256: String

        public init(path: String, bytes: Int, sha256: String) {
            self.path = path
            self.bytes = bytes
            self.sha256 = sha256
        }
    }

    public struct Outputs: Codable, Equatable, Sendable {
        public let sdrTIFF: OutputFile
        public let hdrTIFF: OutputFile
        public let previewHEIC: OutputFile

        public init(sdrTIFF: OutputFile, hdrTIFF: OutputFile, previewHEIC: OutputFile) {
            self.sdrTIFF = sdrTIFF
            self.hdrTIFF = hdrTIFF
            self.previewHEIC = previewHEIC
        }

        private enum CodingKeys: String, CodingKey {
            case sdrTIFF = "sdr_tif"
            case hdrTIFF = "hdr_tif"
            case previewHEIC = "preview_heic"
        }
    }

    public struct RenderInfo: Codable, Equatable, Sendable {
        public let workingSpace: String
        public let toneMap: String
        public let start: Double
        public let liftStops: Double
        public let transition: Double
        public let headroomCapLinear: Double
        public let authoredPeakLinear: Double
        public let authoredPeakStops: Double
        public let fractionAboveOne: Double
        public let fractionAtCap: Double

        public init(
            workingSpace: String = "linear-extended-DisplayP3-float32",
            toneMap: String,
            start: Double,
            liftStops: Double,
            transition: Double,
            headroomCapLinear: Double,
            authoredPeakLinear: Double,
            authoredPeakStops: Double,
            fractionAboveOne: Double,
            fractionAtCap: Double
        ) {
            self.workingSpace = workingSpace
            self.toneMap = toneMap
            self.start = start
            self.liftStops = liftStops
            self.transition = transition
            self.headroomCapLinear = headroomCapLinear
            self.authoredPeakLinear = authoredPeakLinear
            self.authoredPeakStops = authoredPeakStops
            self.fractionAboveOne = fractionAboveOne
            self.fractionAtCap = fractionAtCap
        }

        private enum CodingKeys: String, CodingKey {
            case workingSpace = "working_space"
            case toneMap = "tone_map"
            case start
            case liftStops = "lift_stops"
            case transition
            case headroomCapLinear = "headroom_cap_linear"
            case authoredPeakLinear = "authored_peak_linear"
            case authoredPeakStops = "authored_peak_stops"
            case fractionAboveOne = "fraction_above_one"
            case fractionAtCap = "fraction_at_cap"
        }
    }

    public struct EncoderInfo: Codable, Equatable, Sendable {
        public let tool: String
        public let executable: String
        public let version: String
        public let quality: Double
        public let depth: Int
        public let headroomCapArg: Double
        public let elapsedSeconds: Double

        public init(
            tool: String,
            executable: String,
            version: String,
            quality: Double,
            depth: Int,
            headroomCapArg: Double,
            elapsedSeconds: Double
        ) {
            self.tool = tool
            self.executable = executable
            self.version = version
            self.quality = quality
            self.depth = depth
            self.headroomCapArg = headroomCapArg
            self.elapsedSeconds = elapsedSeconds
        }

        private enum CodingKeys: String, CodingKey {
            case tool, executable, version, quality, depth
            case headroomCapArg = "headroom_cap_arg"
            case elapsedSeconds = "elapsed_seconds"
        }
    }

    public struct Timings: Codable, Equatable, Sendable {
        public var decodeSeconds: Double
        public var sdrBaseSeconds: Double
        public var hdrSeconds: Double
        public var previewSeconds: Double
        public var encodeSeconds: Double
        public var metadataSeconds: Double
        public var totalSeconds: Double

        public init(
            decodeSeconds: Double = 0,
            sdrBaseSeconds: Double = 0,
            hdrSeconds: Double = 0,
            previewSeconds: Double = 0,
            encodeSeconds: Double = 0,
            metadataSeconds: Double = 0,
            totalSeconds: Double = 0
        ) {
            self.decodeSeconds = decodeSeconds
            self.sdrBaseSeconds = sdrBaseSeconds
            self.hdrSeconds = hdrSeconds
            self.previewSeconds = previewSeconds
            self.encodeSeconds = encodeSeconds
            self.metadataSeconds = metadataSeconds
            self.totalSeconds = totalSeconds
        }

        private enum CodingKeys: String, CodingKey {
            case decodeSeconds = "decode_seconds"
            case sdrBaseSeconds = "sdr_base_seconds"
            case hdrSeconds = "hdr_seconds"
            case previewSeconds = "preview_seconds"
            case encodeSeconds = "encode_seconds"
            case metadataSeconds = "metadata_seconds"
            case totalSeconds = "total_seconds"
        }
    }

    public let schema: Int
    public let source: SourceInfo
    public let recipe: Recipe
    public let outputs: Outputs
    public let render: RenderInfo
    public let encoder: EncoderInfo
    public let timings: Timings

    public init(
        source: SourceInfo,
        recipe: Recipe,
        outputs: Outputs,
        render: RenderInfo,
        encoder: EncoderInfo,
        timings: Timings,
        schema: Int = PrepMetadata.currentSchema
    ) {
        self.schema = schema
        self.source = source
        self.recipe = recipe
        self.outputs = outputs
        self.render = render
        self.encoder = encoder
        self.timings = timings
    }
}
