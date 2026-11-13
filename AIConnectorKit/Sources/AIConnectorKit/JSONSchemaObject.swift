// JSONSchemaObject — the object schema handed to `structuredCompletion`.
//
// The DEFAULTS are OpenAI strict mode (`requiredPolicy: .allProperties`,
// `allowsAdditionalProperties: false`) because that is the strictest of the three
// providers and a document valid there is valid for Ollama and Anthropic too.
// Relaxing is opt-in; a caller who relaxes has said so out loud.
import Foundation

/// An object schema: an ordered property list plus the two constraints every
/// provider disagrees about.
public struct JSONSchemaObject: Sendable, Equatable {
    /// One named property.
    ///
    /// Declaration ORDER is meaningful: it is the order `required` is emitted in,
    /// which keeps recorded-request assertions stable across runs.
    public struct Property: Sendable, Equatable {
        public var name: String
        public var schema: JSONSchemaNode

        public init(name: String, schema: JSONSchemaNode) {
            self.name = name
            self.schema = schema
        }
    }

    /// Which properties the provider must fill in.
    public enum RequiredPolicy: Sendable, Equatable {
        /// Every property, in declaration order. What OpenAI strict mode demands —
        /// optionality is then expressed by ``JSONSchemaNode/isNullable``, never by
        /// leaving a property out of `required`.
        case allProperties
        /// Exactly these names, in exactly this order.
        case explicit([String])
    }

    public var properties: [Property]
    public var requiredPolicy: RequiredPolicy

    /// Whether the provider may add properties the schema did not name.
    ///
    /// Defaults to `false`: JSON Schema's own default is `true`, and OpenAI strict
    /// mode rejects a document that leaves it that way, so the safe value is the
    /// one that has to be typed to be lost.
    public var allowsAdditionalProperties: Bool

    /// A hint for the model. Sent to the provider, never rendered in the app.
    public var description: String?

    public init(
        properties: [Property],
        requiredPolicy: RequiredPolicy = .allProperties,
        allowsAdditionalProperties: Bool = false,
        description: String? = nil
    ) {
        self.properties = properties
        self.requiredPolicy = requiredPolicy
        self.allowsAdditionalProperties = allowsAdditionalProperties
        self.description = description
    }

    /// The resolved `required` list, in the order it will be encoded.
    public var requiredPropertyNames: [String] {
        switch requiredPolicy {
        case .allProperties: properties.map(\.name)
        case let .explicit(names): names
        }
    }

    /// The schema for one named property, or `nil` when it is not declared.
    public func property(named name: String) -> JSONSchemaNode? {
        properties.first { $0.name == name }?.schema
    }
}

// MARK: - Encoding

extension JSONSchemaObject: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: JSONSchemaCodingKey.self)
        try container.encode("object", forKey: .type)
        if let description {
            try container.encode(description, forKey: .description)
        }
        try encodeObjectBody(into: &container)
    }

    /// Writes `properties` / `required` / `additionalProperties` into a container a
    /// caller already opened.
    ///
    /// Exists so a nullable object NODE — whose `type` is the union
    /// `["object", "null"]` rather than the plain `"object"` written above — can
    /// still emit an identical body. `JSONSchemaNode.encode(to:)` is the only other
    /// caller.
    func encodeObjectBody(into container: inout KeyedEncodingContainer<JSONSchemaCodingKey>) throws {
        var propertyContainer = container.nestedContainer(
            keyedBy: JSONSchemaPropertyKey.self,
            forKey: .properties
        )
        for property in properties {
            try propertyContainer.encode(property.schema, forKey: JSONSchemaPropertyKey(property.name))
        }
        try container.encode(requiredPropertyNames, forKey: .required)
        try container.encode(allowsAdditionalProperties, forKey: .additionalProperties)
    }
}
