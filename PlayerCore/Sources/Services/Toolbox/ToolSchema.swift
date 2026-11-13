// ToolSchema — the minimal JSON-Schema builder every tool publishes its arguments
// with.
//
// Only the subset all three downstream adapters agree on is emitted: `type`,
// `description`, `properties`, `required`, `additionalProperties`, `enum`,
// `items`, `minimum`, `maximum`, `maxItems`. Anything richer would have to be
// translated (or dropped) by at least one adapter, and a schema that means
// different things to different providers is worse than a narrow one.
//
// `additionalProperties: false` and an explicit `required` list are always
// emitted, because that is the strictest reading — a document valid under
// OpenAI strict mode is valid for FoundationModels and MCP too, and relaxing
// later is additive.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// Builders for the JSON-Schema documents in ``LibraryTool/parametersSchema``.
public enum ToolSchema {
    /// One named property of an object schema.
    ///
    /// A named type rather than a tuple: SwiftLint's `large_tuple` budget is two
    /// members, and a labelled struct survives a third field being added later.
    public struct Property: Sendable, Equatable {
        public let name: String
        public let schema: ToolboxJSON

        public init(_ name: String, _ schema: ToolboxJSON) {
            self.name = name
            self.schema = schema
        }
    }

    /// An object schema over `properties`, requiring exactly `required`.
    public static func object(_ properties: [Property], required: [String] = []) -> ToolboxJSON {
        var declared: [String: ToolboxJSON] = [:]
        declared.reserveCapacity(properties.count)
        for property in properties {
            declared[property.name] = property.schema
        }
        return .object([
            "type": .string("object"),
            "properties": .object(declared),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }

    /// A string property, optionally restricted to a closed vocabulary.
    public static func string(_ description: String, allowed: [String]? = nil) -> ToolboxJSON {
        var node: [String: ToolboxJSON] = [
            "type": .string("string"),
            "description": .string(description),
        ]
        if let allowed {
            node["enum"] = .array(allowed.map { .string($0) })
        }
        return .object(node)
    }

    /// An integer property with optional inclusive bounds.
    public static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> ToolboxJSON {
        var node: [String: ToolboxJSON] = [
            "type": .string("integer"),
            "description": .string(description),
        ]
        if let minimum {
            node["minimum"] = .int(minimum)
        }
        if let maximum {
            node["maximum"] = .int(maximum)
        }
        return .object(node)
    }

    /// A fractional-number property with optional inclusive bounds.
    public static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> ToolboxJSON {
        var node: [String: ToolboxJSON] = [
            "type": .string("number"),
            "description": .string(description),
        ]
        if let minimum {
            node["minimum"] = .number(minimum)
        }
        if let maximum {
            node["maximum"] = .number(maximum)
        }
        return .object(node)
    }

    /// An array-of-integers property with a hard `maxItems` ceiling.
    ///
    /// Every id list a tool accepts is bounded in the SCHEMA as well as at the
    /// accessor, so a well-behaved model never sends a batch the tool must reject.
    public static func integerArray(_ description: String, maxItems: Int) -> ToolboxJSON {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("integer")]),
            "maxItems": .int(maxItems),
        ])
    }

    /// An array-of-OBJECTS property with a hard `maxItems` ceiling.
    ///
    /// The item shape is expressed in the schema itself rather than described in
    /// prose: a batch of `{title, artist}` pairs is only usable if the model knows
    /// the key names, and a two-parameter `objectArray(description:maxItems:)` form
    /// could not carry them. The item object is built by ``object(_:required:)``, so
    /// it inherits the same strictness (`additionalProperties: false`, an explicit
    /// `required` list) every top-level schema publishes.
    public static func objectArray(
        _ description: String,
        properties: [Property],
        required: [String],
        maxItems: Int
    ) -> ToolboxJSON {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": object(properties, required: required),
            "maxItems": .int(maxItems),
        ])
    }

    /// The schema for a tool that takes no arguments.
    public static var noArguments: ToolboxJSON {
        object([])
    }
}
