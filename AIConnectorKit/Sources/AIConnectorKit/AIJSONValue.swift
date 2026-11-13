// AIJSONValue — the raw JSON value the tool-calling loop speaks.
//
// ── WHY `JSONSchemaObject` COULD NOT BE REUSED ────────────────────────────────
//
// ``JSONSchemaObject`` is a SCHEMA BUILDER, not a JSON value: it can express
// `type` / `properties` / `required` / `additionalProperties` / `enum` / `items`
// and nothing else. The tool schemas this loop has to carry are built by
// PlayerCore's `ToolSchema`, which also emits `minimum`, `maximum` and `maxItems`
// (`ToolSchema.integer(_:minimum:maximum:)`, `ToolSchema.integerArray(_:maxItems:)`).
// Those three keys have no representation in ``JSONSchemaNode``, so routing a
// toolbox schema through it would SILENTLY DROP the bounds a tool documents —
// the model would then be free to ask for `limit: 100000`, and the refusal would
// arrive as a `ToolArgumentError` sentence instead of never being emitted.
//
// A schema is therefore carried as opaque JSON, verbatim, and this type is that
// JSON. It is deliberately the same shape as PlayerCore's `ToolboxJSON` (one
// number case, `Codable`, `.sortedKeys`) so the bridge's conversion is a
// mechanical case-for-case map with nowhere for a value to change meaning.
//
// ── ONE NUMBER CASE, FOR THE SAME REASON `ToolboxJSON` HAS ONE ────────────────
//
// JSON has one number type and `JSONEncoder` writes `Double(100)` as `100`, so a
// separate `.integer` case would not round-trip (`.number(2.0)` in, `.integer(2)`
// out). Integers are recovered at ``intValue`` with an exactness check.
//
// ── DETERMINISM ───────────────────────────────────────────────────────────────
//
// ``makeEncoder()`` sets `.sortedKeys` and `.withoutEscapingSlashes`, matching
// every other encoder in this kit: a recorded-request assertion has to compare
// exact bytes, and key order inside a keyed container is otherwise an
// implementation detail.
import Foundation

/// A JSON value: a tool's argument payload, a tool's JSON-Schema document, and
/// every provider-native conversation item this kit replays.
public enum AIJSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    /// Every JSON number. See the file header for why there is no integer case.
    case number(Double)
    case string(String)
    case array([AIJSONValue])
    case object([String: AIJSONValue])
}

// MARK: - Accessors

public extension AIJSONValue {
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

    /// The wrapped number as an `Int`, or `nil` when it is not a number or does
    /// not survive the conversion exactly. See the file header.
    var intValue: Int? {
        guard case let .number(value) = self, let exact = Int(exactly: value.rounded()) else { return nil }
        return value == value.rounded() ? exact : nil
    }

    /// The wrapped boolean, or `nil` when this is not a `.bool`.
    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    /// The wrapped array, or `nil` when this is not an `.array`.
    var arrayValue: [AIJSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    /// The wrapped object, or `nil` when this is not an `.object`.
    var objectValue: [String: AIJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Whether this is the JSON literal `null`.
    var isNull: Bool {
        self == .null
    }

    /// The value under `key`, or `nil` when this is not an object or the key is
    /// absent. A stored `null` reads as `.null`, NOT as absent — the two are
    /// distinguishable and several provider shapes rely on that.
    subscript(key: String) -> AIJSONValue? {
        objectValue?[key]
    }
}

// MARK: - Coding

extension AIJSONValue: Codable {
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
        } else if let value = try? container.decode([AIJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AIJSONValue].self) {
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

public extension AIJSONValue {
    /// The ONE encoder configuration a kit JSON document may be written with.
    /// See the file header for why `.sortedKeys` is not optional.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// This value as canonical JSON bytes.
    func encodedData() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// This value as canonical JSON text, or `""` when it cannot be encoded
    /// (unreachable for a well-formed value — every case is encodable).
    var jsonText: String {
        guard let data = try? encodedData(), let text = String(bytes: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Reads a value back from JSON bytes, or `nil` when they are not JSON.
    ///
    /// Optional rather than throwing because every caller in this kit treats
    /// unreadable provider bytes as ``ConnectorFailure/malformedResponse`` and
    /// has no use for the decoding detail.
    static func decoded(from data: Data) -> AIJSONValue? {
        try? JSONDecoder().decode(AIJSONValue.self, from: data)
    }

    /// Reads a value back from JSON text, or `nil` when it is not JSON.
    ///
    /// Blank text reads as `nil` rather than as an error: a provider that emits
    /// an argument-less tool call sends `""` on two of the four wire formats.
    static func parsed(_ text: String) -> AIJSONValue? {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        return decoded(from: Data(text.utf8))
    }

    /// A `.number` from any integer, so a wire bound reads as `.int(4096)` rather
    /// than `.number(4096)` at the call site.
    static func int(_ value: some BinaryInteger) -> AIJSONValue {
        .number(Double(value))
    }

    /// An `.object` built from ordered pairs, dropping every `nil` value.
    ///
    /// The wire builders below are almost entirely "these keys, some of which are
    /// conditional", and this is what keeps them from being a pile of
    /// `if let … { dictionary[…] = … }`. Dropping rather than writing `null`
    /// matters: a null `tools` or a null `response_format` is a 400 on more than
    /// one of the four providers.
    static func object(_ pairs: KeyValuePairs<String, AIJSONValue?>) -> AIJSONValue {
        var values: [String: AIJSONValue] = [:]
        for (key, value) in pairs {
            guard let value else { continue }
            values[key] = value
        }
        return .object(values)
    }
}
