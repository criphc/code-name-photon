import Foundation

/// Everything the client needs to author HDR itself: the source identity, the 16-bit PNG SDR base
/// it downloads, and the documented recipe defaults its controls start from.
///
/// The wire carries no HDR rendition and no gain map: the client computes
/// `hdr = base · 2^(lift·mask(luma))` in its shader, and only the recipe travels back.
public struct PreviewMetadata: Codable, Equatable, Sendable {
    public static let currentSchema = 0

    public struct SourceInfo: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
        public let width: Int
        public let height: Int
        /// Informational; `nil` when the source carried no recognisable ICC name.
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

    public struct BaseInfo: Codable, Equatable, Sendable {
        /// File name relative to the item directory (`preview-base.png`).
        public let file: String
        public let bytes: Int
        public let sha256: String
        public let width: Int
        public let height: Int
        /// `png-16-p3` — 16-bit RGB, no alpha, Display P3 ICC.
        public let format: String
        /// The space the renderer must linearise the PNG into before applying the mask.
        public let workingSpace: String
        public let profileName: String?
        public let longEdge: Int

        public init(
            file: String, bytes: Int, sha256: String, width: Int, height: Int,
            format: String, workingSpace: String, profileName: String?, longEdge: Int
        ) {
            self.file = file
            self.bytes = bytes
            self.sha256 = sha256
            self.width = width
            self.height = height
            self.format = format
            self.workingSpace = workingSpace
            self.profileName = profileName
            self.longEdge = longEdge
        }
    }

    public let schema: Int
    public let source: SourceInfo
    public let base: BaseInfo
    /// Slider starting values and render provenance; the client posts an edited copy back.
    public let recipeDefaults: Recipe
    public let appVersion: String
    public let createdAt: String

    public init(
        source: SourceInfo,
        base: BaseInfo,
        recipeDefaults: Recipe,
        appVersion: String,
        createdAt: String,
        schema: Int = PreviewMetadata.currentSchema
    ) {
        self.schema = schema
        self.source = source
        self.base = base
        self.recipeDefaults = recipeDefaults
        self.appVersion = appVersion
        self.createdAt = createdAt
    }
}
