// ToolWireEncoding — the four ways a tool list is spelled, in one file.
//
// ── THE SHAPES, AND WHERE EACH WAS VERIFIED (recon 2026-08-28) ───────────────
//
//   Anthropic `/v1/messages`
//     {"name", "description", "input_schema", "strict"}                 top level
//   OpenAI `/v1/chat/completions`
//     {"type": "function", "function": {"name", "description",
//                                       "parameters", "strict"}}            nested
//   Ollama `/api/chat`
//     the SAME nested shape, minus `strict` — Ollama documents the OpenAI
//     envelope for `tools` and does not document the flag, and sending an
//     undocumented key to a server that constrains decoding itself buys nothing.
//   ChatGPT `chatgpt.com/backend-api/codex/responses`
//     {"type": "function", "name", "description", "parameters", "strict"}     FLAT
//
// Three envelopes for one concept is exactly the kind of difference that gets
// copied wrong once and then debugged as a 400 with no body, so all four live
// here beside each other where the differences are visible.
//
// ── WHY THIS IS `public` ─────────────────────────────────────────────────────
//
// ``ChatGPTConnector`` lives in `AIConnectorKitOAuth`, a SEPARATE target (the
// package split exists so an embedder can leave the consumer-login surface
// unlinked — see `Package.swift`). A shared encoder therefore cannot be
// `internal`. It is public API in the mechanical sense only: nothing outside this
// kit's own connectors has a reason to call it.
import Foundation

/// Encoders for the tool-declaration half of a provider request.
public enum ToolWireEncoding {
    /// Wire keys, spelled once. A typo in one of these is a 400 with an unhelpful
    /// body; a typo in a constant is a compile error.
    enum Key {
        static let type = "type"
        static let function = "function"
        static let name = "name"
        static let description = "description"
        static let parameters = "parameters"
        static let inputSchema = "input_schema"
        static let strict = "strict"
        static let arrayType = "array"
    }

    /// Schema keywords Anthropic's validator refuses on an `array`-typed node.
    ///
    /// MEASURED 2026-09-09 against the live `/v1/messages` edge: a tool whose
    /// array property carried `maxItems` was refused with HTTP 400
    /// `invalid_request_error` — `tools.N.custom: For 'array' type, property
    /// 'maxItems' is not supported` — which took the whole assistant surface down
    /// (every turn carries the tool list). `minItems` joins it because the error
    /// names the TYPE's supported-property set, not one key, and dropping a bound
    /// can never invalidate a schema. Numeric `minimum`/`maximum`, `enum`,
    /// `additionalProperties` and `strict` all passed the same measurement
    /// (validation reached tools.2 and named only the array bound).
    static let anthropicUnsupportedArrayBounds: Set<String> = ["maxItems", "minItems"]

    /// The `type` discriminator every non-Anthropic shape carries.
    public static let functionType = "function"

    /// Anthropic's top-level tool objects.
    public static func anthropicTools(_ tools: [AITool]) -> AIJSONValue {
        .array(tools.map { tool in
            .object([
                Key.name: .string(tool.name),
                Key.description: .string(tool.description),
                Key.inputSchema: anthropicSchema(tool.parametersSchema),
                Key.strict: .bool(AIToolStrictness.isEligible(tool.parametersSchema)),
            ])
        })
    }

    /// `schema` with ``anthropicUnsupportedArrayBounds`` removed from every
    /// `array`-typed node, recursively.
    ///
    /// Gated on the node's own `type` so a PROPERTY that happens to be named
    /// `maxItems` (a `properties` map key, not a schema keyword) is never
    /// touched — an MCP server owns its schemas and this kit must not reshape
    /// them beyond what the provider provably refuses.
    public static func anthropicSchema(_ schema: AIJSONValue) -> AIJSONValue {
        switch schema {
        case let .object(fields):
            let isArrayNode = fields[Key.type]?.stringValue == Key.arrayType
            var cleaned: [String: AIJSONValue] = [:]
            for (key, value) in fields {
                if isArrayNode, anthropicUnsupportedArrayBounds.contains(key) { continue }
                cleaned[key] = anthropicSchema(value)
            }
            return .object(cleaned)
        case let .array(elements):
            return .array(elements.map(anthropicSchema))
        case .null, .bool, .number, .string:
            return schema
        }
    }

    /// The OpenAI-style nested envelope, used by OpenAI and by Ollama.
    ///
    /// - Parameter includesStrict: `false` for Ollama, which does not document
    ///   the flag. See the file header.
    public static func nestedFunctionTools(_ tools: [AITool], includesStrict: Bool = true) -> AIJSONValue {
        .array(tools.map { tool in
            .object([
                Key.type: .string(functionType),
                Key.function: .object([
                    Key.name: .string(tool.name),
                    Key.description: .string(tool.description),
                    Key.parameters: tool.parametersSchema,
                    Key.strict: includesStrict
                        ? .bool(AIToolStrictness.isEligible(tool.parametersSchema))
                        : nil,
                ]),
            ])
        })
    }

    /// The Responses-API flat envelope.
    public static func flatFunctionTools(_ tools: [AITool]) -> AIJSONValue {
        .array(tools.map { tool in
            .object([
                Key.type: .string(functionType),
                Key.name: .string(tool.name),
                Key.description: .string(tool.description),
                Key.parameters: tool.parametersSchema,
                Key.strict: .bool(AIToolStrictness.isEligible(tool.parametersSchema)),
            ])
        })
    }

    /// Canonical JSON text for an argument payload a provider handed back as a
    /// PARSED object rather than as a string.
    ///
    /// Only Ollama does this — its `message.tool_calls[].function.arguments` is a
    /// decoded object, not the JSON string every other provider sends. Normalising
    /// here keeps ``ToolCall/argumentsJSON`` one type across four wire formats,
    /// which is what lets ``AITool/execute`` take a string and one shell render
    /// ``ChatEvent/toolCall(name:argumentsJSON:)`` one way.
    public static func argumentsText(_ value: AIJSONValue?) -> String {
        guard let value, value.isNull == false else { return "{}" }
        if let text = value.stringValue { return text }
        return value.jsonText
    }

    /// A request body, or ``ConnectorFailure/malformedResponse``.
    ///
    /// Unreachable in practice — an ``AIJSONValue`` built from finite numbers and
    /// strings always encodes — and mapped rather than trapped so a future wire
    /// change degrades instead of crashing. The taxonomy is deliberately total
    /// and has no request-side case, which is why this lands on the response-side
    /// one; the alternative is widening a closed enum for an impossible path.
    public static func body(_ value: AIJSONValue) throws -> Data {
        do {
            return try value.encodedData()
        } catch {
            throw ConnectorFailure.malformedResponse
        }
    }
}
