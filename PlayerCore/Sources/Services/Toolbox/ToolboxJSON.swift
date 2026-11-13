// ToolboxJSON — the self-contained JSON value the tool layer speaks.
//
// ── WHY A LOCAL TYPE RATHER THAN `JSONSchemaObject` ────────────────────────────
//
// `AIConnectorKit` already ships a schema builder, and reusing it would be the
// obvious move — but the dependency runs kit → PlayerCore, never the reverse
// (see the root README's AIConnectorKit section). `LibraryToolbox` lives in
// `Services`, below that boundary, and is consumed by THREE adapters that do not
// share a schema vocabulary: FoundationModels `Tool` conformers, AIConnectorKit's
// provider-agnostic loop, and an in-process MCP server. A local, dependency-free
// JSON value is the only shape all three can be projected from.
//
// ── ONE NUMBER CASE, DELIBERATELY ─────────────────────────────────────────────
//
// There is no `.integer` case. JSON itself has one number type, and Foundation's
// `JSONEncoder` writes `Double(100)` as `100`, which a reader would then decode as
// an integer — so a two-case design is NOT round-trip stable (`.number(2.0)` in,
// `.integer(2)` out). ``ToolArguments`` recovers integers with an exactness check
// at the accessor, which is where the caller can be told what went wrong.
//
// ── DETERMINISM ───────────────────────────────────────────────────────────────
//
// ``encodedData()`` sets `.sortedKeys` for the same reason ``ListeningDigest``
// does: the bytes must be a function of the values, not of Swift's dictionary
// emission order, so a recorded-schema assertion is stable across runs.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// A JSON value: the argument payload a tool receives and the JSON-Schema document
/// a tool publishes.
public enum ToolboxJSON: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    /// Every JSON number. See the file header for why there is no integer case.
    case number(Double)
    case string(String)
    case array([ToolboxJSON])
    case object([String: ToolboxJSON])
}

// MARK: - Accessors

public extension ToolboxJSON {
    /// The wrapped string, or `nil` when this is not a `.string`.
    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// The wrapped number, or `nil` when this is not a `.number`.
    var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    /// The wrapped boolean, or `nil` when this is not a `.bool`.
    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// The wrapped array, or `nil` when this is not an `.array`.
    var arrayValue: [ToolboxJSON]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// The wrapped object, or `nil` when this is not an `.object`.
    var objectValue: [String: ToolboxJSON]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Whether this is the JSON literal `null`.
    var isNull: Bool {
        self == .null
    }
}

// MARK: - Coding

extension ToolboxJSON: Codable {
    /// Decodes in the order that makes each attempt unambiguous: `null`, then
    /// `Bool` (a JSON `true` is never a number, and a JSON `1` never decodes as
    /// `Bool` through Foundation), then `Double`, `String`, array, object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ToolboxJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ToolboxJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not representable as JSON."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }
}

public extension ToolboxJSON {
    /// The ONE encoder configuration a toolbox document may be written with.
    /// See the file header for why `.sortedKeys` is not optional.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// This value as canonical JSON bytes.
    func encodedData() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// This value as a canonical JSON string, or `""` when it cannot be encoded
    /// (unreachable for a well-formed value — every case is encodable).
    var jsonText: String {
        guard let data = try? encodedData(), let text = String(bytes: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Reads a value back from ``encodedData()``.
    static func decoded(from data: Data) throws -> ToolboxJSON {
        try JSONDecoder().decode(ToolboxJSON.self, from: data)
    }
}

// MARK: - Literal conveniences

public extension ToolboxJSON {
    /// A `.number` from any integer, so a schema bound reads as `.int(10)` rather
    /// than `.number(10)` at the call site.
    static func int(_ value: some BinaryInteger) -> ToolboxJSON {
        .number(Double(value))
    }
}
