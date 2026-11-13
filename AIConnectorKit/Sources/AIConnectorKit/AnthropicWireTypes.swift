// AnthropicWireTypes.swift — the `Encodable`/`Decodable` mirrors of Anthropic's
// request and response JSON, split out of `AnthropicConnector.swift`.
//
// Split for one mechanical reason: `.swiftlint.yml` does not override
// `file_length`, so SwiftLint's 400-line ceiling applies and CI runs `--strict`.
// The repo has done exactly this before (`AppSettings+DesignTokens.swift`). These
// types own no behaviour, which makes them the block that moves.
//
// FLAT, not nested inside the request: each needs its own `CodingKeys`, and
// SwiftLint's `nesting` rule caps types at one level deep. They are `internal`
// rather than `private` only because they now live across a file boundary — the
// `Anthropic` prefix keeps them from colliding with a sibling connector's mirrors.
//
// The wire contract they encode is documented in `AnthropicConnector.swift`'s
// header, including the three fields Anthropic answers a 400 for omitting.
import Foundation

/// One turn. `system` framing is NOT a message — see the file header.
struct AnthropicMessage: Encodable {
    let role: String
    let content: String
}

/// Builds the top-level `system` field, in the two shapes Anthropic accepts.
///
/// ── WHY A PREFIX IS A BLOCK AND NOT A STRING (MEASURED 2026-09-06) ───────────
///
/// Anthropic takes `system` either as a plain string or as an array of text
/// blocks, and for a console API key the two are interchangeable. On the OAuth
/// (Pro/Max subscription) edge they are NOT: that edge attributes a request to
/// Claude Code by matching a DISCRETE FIRST BLOCK whose text is the identity
/// line verbatim, and a concatenated string does not satisfy it at any length.
///
/// Measured live, same token, same model, same body but for this one field —
/// three alternating probes:
///
///   `"You are Claude Code…\n\nBe useful."`      → HTTP 429 `rate_limit_error`
///   `[{"type":"text","text":"You are Claude Code…"},{"type":"text",…}]`
///                                               → HTTP 200
///   `"You are Claude Code…\n\nBe useful."`      → HTTP 429 `rate_limit_error`
///
/// The refusal is DISGUISED: it arrives as a 429 whose body is
/// `{"type":"error","error":{"type":"rate_limit_error","message":"Error"}}`,
/// carries `x-should-retry: true`, and — the tell — omits every
/// `anthropic-ratelimit-unified-*` header the 200 carries. The accepted probe
/// reported `unified-status: allowed` at 28 % five-hour utilisation fourteen
/// seconds after the first refusal, so no quota was ever spent or exhausted.
/// `GET /v1/models` sends no `system` at all, which is why listing a catalog
/// kept working while every chat turn failed.
enum AnthropicSystemPrompt {
    static let typeKey = "type"
    static let textKey = "text"
    static let textBlockType = "text"

    /// - Parameters:
    ///   - prefix: An identity line that must occupy its OWN leading block.
    ///     `nil` — the API-key route — keeps the plain-string shape unchanged.
    ///   - instructions: The caller's framing. Blank yields no field at all when
    ///     there is no prefix, and the prefix block alone when there is one.
    static func value(prefix: String?, instructions: String) -> AIJSONValue? {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix, prefix.isEmpty == false else {
            return trimmed.isEmpty ? nil : .string(trimmed)
        }
        let remainder = trimmed.hasPrefix(prefix)
            ? String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
        let texts = remainder.isEmpty ? [prefix] : [prefix, remainder]
        return .array(texts.map(block(_:)))
    }

    private static func block(_ text: String) -> AIJSONValue {
        .object([typeKey: .string(textBlockType), textKey: .string(text)])
    }
}

/// A tool definition. `input_schema` carries the caller's schema verbatim — the
/// only route Anthropic offers to schema-constrained output.
struct AnthropicTool: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONSchemaObject

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }
}

/// `name` is REQUIRED once `type` is `tool`; omitting it is a 400.
struct AnthropicToolChoice: Encodable {
    static let forcedType = "tool"

    let type: String
    let name: String
}

/// The `/v1/messages` request body. Optional fields are omitted when nil by the
/// synthesized encoder, which keeps a plain `completion` body free of `tools`.
struct AnthropicMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    /// Either a plain string or an array of text blocks — see ``AnthropicSystemPrompt``.
    let system: AIJSONValue?
    let messages: [AnthropicMessage]
    let tools: [AnthropicTool]?
    let toolChoice: AnthropicToolChoice?

    enum CodingKeys: String, CodingKey {
        case model
        case system
        case messages
        case tools
        case maxTokens = "max_tokens"
        case toolChoice = "tool_choice"
    }
}

/// One entry of the `/v1/models` list.
struct AnthropicModelEntry: Decodable {
    let id: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    /// Every model the Messages API lists accepts `tools`, and this connector's
    /// structured path IS forced tool use — so the capability set is knowledge
    /// about the endpoint, not a guess about the model.
    var modelInfo: ModelInfo {
        ModelInfo(id: id, displayName: displayName, capabilities: [.chat, .toolUse, .structuredOutput])
    }
}

/// The `/v1/models` response.
struct AnthropicModelsPayload: Decodable {
    let data: [AnthropicModelEntry]
}
