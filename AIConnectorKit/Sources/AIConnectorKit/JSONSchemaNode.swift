// JSONSchemaNode — one node of an encodable JSON Schema document.
//
// Built COMPLETE up front rather than grown per connector, because the three
// providers want mutually incompatible slices of the same document and a
// half-built schema type would be reopened by each of them in turn:
//
//   Ollama      `format: <schema>` — plain object schema.
//   Anthropic   a forced tool whose `input_schema` is the schema.
//   OpenAI      `response_format.json_schema` with `strict: true`, which REQUIRES
//               every object to carry `additionalProperties: false` and to list
//               ALL properties in `required` — so optional fields cannot be
//               modelled by omission and must be nullable type unions
//               (`"type": ["integer", "null"]`). A naive mirror of Swift optionals
//               is a 400 from that endpoint.
//
// Encoding is `Encodable` only; nothing decodes a schema. For a byte-stable
// request body (recorded-request assertions rely on it) encode with
// `JSONEncoder` configured `.sortedKeys` — key order inside a keyed container is
// otherwise an implementation detail. Array order (`enum`, `required`) is always
// declaration order.
import Foundation

/// The keys a JSON Schema node may emit. Shared by ``JSONSchemaNode`` and
/// ``JSONSchemaObject`` so both halves of an object node write into one container.
enum JSONSchemaCodingKey: String, CodingKey {
    case type
    case description
    case `enum`
    case items
    case properties
    case required
    case additionalProperties
}

/// A dynamic key, used to write property names into the `properties` container.
struct JSONSchemaPropertyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

/// One node in a JSON Schema document: a scalar, an array, or a nested object.
public struct JSONSchemaNode: Sendable, Equatable {
    /// What this node accepts.
    ///
    /// `indirect` because a node may hold an object whose properties are nodes —
    /// the boxing is what makes that cycle representable in a value type.
    public indirect enum Kind: Sendable, Equatable {
        /// A string, optionally constrained to a closed vocabulary.
        /// An empty `allowedValues` means unconstrained; a non-empty one emits
        /// `enum`.
        case string(allowedValues: [String])
        case integer
        case number
        case boolean
        case array(items: JSONSchemaNode)
        case object(JSONSchemaObject)
    }

    public var kind: Kind

    /// Whether `null` is an accepted value.
    ///
    /// Encodes as a type UNION (`"type": ["integer", "null"]`) rather than by
    /// omitting the property from `required`, because OpenAI strict mode forbids
    /// the omission route. When the node is also `enum`-constrained, `null` is
    /// appended to the `enum` array — strict mode requires the nullable value to
    /// appear there too, and it is plain-JSON-Schema-correct everywhere else.
    public var isNullable: Bool

    /// A hint for the model. Prose, but NOT user-facing: it is sent to the
    /// provider, never rendered in the app, so it stays out of String Catalogs.
    public var description: String?

    public init(kind: Kind, isNullable: Bool = false, description: String? = nil) {
        self.kind = kind
        self.isNullable = isNullable
        self.description = description
    }
}

// MARK: - Construction

public extension JSONSchemaNode {
    /// A string, optionally constrained to a closed vocabulary.
    static func string(
        allowedValues: [String] = [],
        isNullable: Bool = false,
        description: String? = nil
    ) -> JSONSchemaNode {
        JSONSchemaNode(kind: .string(allowedValues: allowedValues), isNullable: isNullable, description: description)
    }

    static func integer(isNullable: Bool = false, description: String? = nil) -> JSONSchemaNode {
        JSONSchemaNode(kind: .integer, isNullable: isNullable, description: description)
    }

    static func number(isNullable: Bool = false, description: String? = nil) -> JSONSchemaNode {
        JSONSchemaNode(kind: .number, isNullable: isNullable, description: description)
    }

    static func boolean(isNullable: Bool = false, description: String? = nil) -> JSONSchemaNode {
        JSONSchemaNode(kind: .boolean, isNullable: isNullable, description: description)
    }

    static func array(
        of items: JSONSchemaNode,
        isNullable: Bool = false,
        description: String? = nil
    ) -> JSONSchemaNode {
        JSONSchemaNode(kind: .array(items: items), isNullable: isNullable, description: description)
    }

    static func object(
        _ object: JSONSchemaObject,
        isNullable: Bool = false,
        description: String? = nil
    ) -> JSONSchemaNode {
        JSONSchemaNode(kind: .object(object), isNullable: isNullable, description: description)
    }
}

// MARK: - Encoding

extension JSONSchemaNode.Kind {
    /// The JSON Schema `type` name for this kind.
    var typeName: String {
        switch self {
        case .string: "string"
        case .integer: "integer"
        case .number: "number"
        case .boolean: "boolean"
        case .array: "array"
        case .object: "object"
        }
    }
}

extension JSONSchemaNode: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JSONSchemaCodingKey.self)
        try encodeType(into: &container)
        if let description {
            try container.encode(description, forKey: .description)
        }
        switch kind {
        case let .string(allowedValues):
            try encodeEnum(allowedValues, into: &container)
        case let .array(items):
            try container.encode(items, forKey: .items)
        case let .object(object):
            try object.encodeObjectBody(into: &container)
        case .integer, .number, .boolean:
            break
        }
    }

    private func encodeType(into container: inout KeyedEncodingContainer<JSONSchemaCodingKey>) throws {
        if isNullable {
            try container.encode([kind.typeName, "null"], forKey: .type)
        } else {
            try container.encode(kind.typeName, forKey: .type)
        }
    }

    /// Writes `enum` when the vocabulary is non-empty, appending `null` for a
    /// nullable node so the union and the vocabulary agree.
    private func encodeEnum(
        _ allowedValues: [String],
        into container: inout KeyedEncodingContainer<JSONSchemaCodingKey>
    ) throws {
        guard !allowedValues.isEmpty else { return }
        var values = container.nestedUnkeyedContainer(forKey: .enum)
        for value in allowedValues {
            try values.encode(value)
        }
        if isNullable {
            try values.encodeNil()
        }
    }
}
