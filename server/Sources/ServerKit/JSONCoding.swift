import Foundation

/// Deterministic JSON for the HTTP API: sorted keys, no escaped slashes.
///
/// Stable bytes matter here: `curl` acceptance diffs responses, and M3 will cache payloads.
public enum JSONCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
