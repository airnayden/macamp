// AnthropicConnector+ToolLoop — the Messages API's tool-calling round.
//
// Split from `AnthropicConnector.swift` for one mechanical reason: `.swiftlint.yml`
// does not override `file_length`, so the 400-line ceiling applies and CI runs
// `--strict`. Same precedent as `AnthropicWireTypes.swift`. The stored properties
// and the request/failure helpers this file uses were widened from `private` to
// `internal` for exactly this split — see the notes at their declarations.
//
// ── THE WIRE, AND THE THREE THINGS THAT ARE A 400 (recon 2026-08-28) ─────────
//
//   REQUEST   `tools: [{name, description, input_schema, strict}]` at the TOP
//             level of the body — not wrapped in a `function` envelope, which is
//             the OpenAI dialect. `tool_choice: {"type": "auto"}` lets the model
//             decide; the one-shot `structuredCompletion` path uses
//             `{"type": "tool", "name": …}` instead and is untouched by this file.
//
//   RESPONSE  `stop_reason: "tool_use"` with `tool_use` blocks
//             `{type, id, name, input}` interleaved among `text` blocks.
//
//   REPLY     Append the assistant's `content` array VERBATIM as an assistant
//             message, then exactly ONE user message whose content STARTS with
//             `tool_result` blocks `{type, tool_use_id, content, is_error}`.
//
// Three ways to get that reply wrong, each a 400 or a silent quality loss:
//
//   1. TEXT BEFORE A `tool_result` IN THAT MESSAGE IS A 400. The message this
//      file builds carries `tool_result` blocks and NOTHING else, which satisfies
//      the rule by construction rather than by ordering care.
//   2. PARALLEL CALLS SHARE ONE REPLY. A round may emit several `tool_use`
//      blocks; all of their results go in the SAME user message. One message per
//      result is a 400 (the second message has no preceding assistant turn to
//      answer).
//   3. REPLAYING A RECONSTRUCTED ASSISTANT TURN DEGRADES IT. The content array is
//      carried through untouched — re-serialising only the blocks this parser
//      understands would drop any block type Anthropic adds later.
//
// `is_error` is deliberately never set. A tool in this kit cannot fail: refusals
// arrive as sentences (``AITool/execute`` returns text and does not throw, and
// PlayerCore's `LibraryToolbox.run` renders every refusal as prose), so there is
// no outcome this connector could honestly mark as an error.
import Foundation

public extension AnthropicConnector {
    /// `max_tokens` for a conversational round.
    ///
    /// Twice ``maxTokensForCompletion`` because this path generates an ANSWER for
    /// a person rather than a query object for a parser, and the field is
    /// required with no default — omitting it is a 400.
    ///
    /// Raised from 4096 after a "list 43 songs" ask came back cut off: Anthropic
    /// reports that as `stop_reason: "max_tokens"` on a perfectly ordinary HTTP
    /// 200, so nothing in the failure path noticed and the partial list rendered
    /// as the whole answer. ``AnthropicConnector+Truncation`` now names it.
    static let maxTokensForToolLoop = 8192

    /// `tool_choice` for a round where the model decides whether to call anything.
    static let autoToolChoiceType = "auto"
}

// MARK: - ToolCallingConnector

extension AnthropicConnector: ToolCallingConnector {
    public func chatTurn(_ request: ToolTurnRequest) async throws -> ToolTurnResponse {
        let carried = request.transcript.items + Self.toolResultMessages(request.outcomes)
        let body = Self.requestBody(request, carried: carried, systemPrefix: systemPrefix)
        let encoded = try ToolWireEncoding.body(body)
        let httpRequest = try await makeRequest(path: Self.messagesPath, method: "POST", body: encoded)
        let response = try await transport.send(httpRequest)
        try Self.throwIfFailed(response)
        return try Self.turnResponse(response.body, carried: carried)
    }
}

// MARK: - Request

extension AnthropicConnector {
    enum ToolLoopKey {
        static let model = "model"
        static let maxTokens = "max_tokens"
        static let system = "system"
        static let messages = "messages"
        static let tools = "tools"
        static let toolChoice = "tool_choice"
        static let role = "role"
        static let content = "content"
        static let type = "type"
        static let text = "text"
        static let name = "name"
        static let id = "id"
        static let input = "input"
        static let toolUse = "tool_use"
        static let toolResult = "tool_result"
        static let toolUseID = "tool_use_id"
        static let assistant = "assistant"
        static let user = "user"
    }

    static func requestBody(
        _ request: ToolTurnRequest,
        carried: [AIJSONValue],
        systemPrefix: String?
    ) -> AIJSONValue {
        let prose = request.messages.map { message in
            AIJSONValue.object([
                ToolLoopKey.role: .string(message.role.rawValue),
                ToolLoopKey.content: .string(message.text),
            ])
        }
        let hasTools = request.tools.isEmpty == false
        return .object([
            ToolLoopKey.model: .string(request.model),
            ToolLoopKey.maxTokens: .int(maxTokensForToolLoop),
            ToolLoopKey.system: AnthropicSystemPrompt.value(
                prefix: systemPrefix,
                instructions: request.instructions
            ),
            ToolLoopKey.messages: .array(prose + carried),
            ToolLoopKey.tools: hasTools ? ToolWireEncoding.anthropicTools(request.tools) : nil,
            ToolLoopKey.toolChoice: hasTools
                ? .object([ToolLoopKey.type: .string(autoToolChoiceType)])
                : nil,
        ])
    }

    /// The single user message answering every call of the previous round, or an
    /// empty array on the first round. See rules 1 and 2 in the file header.
    static func toolResultMessages(_ outcomes: [ToolCallOutcome]) -> [AIJSONValue] {
        guard outcomes.isEmpty == false else { return [] }
        let blocks = outcomes.map { outcome in
            AIJSONValue.object([
                ToolLoopKey.type: .string(ToolLoopKey.toolResult),
                ToolLoopKey.toolUseID: .string(outcome.call.id),
                ToolLoopKey.content: .string(outcome.text),
            ])
        }
        return [.object([
            ToolLoopKey.role: .string(ToolLoopKey.user),
            ToolLoopKey.content: .array(blocks),
        ])]
    }
}

// MARK: - Response

extension AnthropicConnector {
    static func turnResponse(_ body: Data, carried: [AIJSONValue]) throws -> ToolTurnResponse {
        try throwIfTruncated(in: body)
        guard
            let root = AIJSONValue.decoded(from: body),
            let content = root[ToolLoopKey.content]?.arrayValue
        else {
            throw ConnectorFailure.malformedResponse
        }
        let text = content
            .filter { $0[ToolLoopKey.type]?.stringValue == ToolLoopKey.text }
            .compactMap { $0[ToolLoopKey.text]?.stringValue }
            .joined()
        let calls = content.compactMap(toolCall(in:))
        // A 200 that carried neither prose nor a call is a contract violation, not
        // an empty answer — the same reading `completion` gives a content-less body.
        guard text.isEmpty == false || calls.isEmpty == false else {
            throw ConnectorFailure.malformedResponse
        }
        let assistant = AIJSONValue.object([
            ToolLoopKey.role: .string(ToolLoopKey.assistant),
            ToolLoopKey.content: .array(content),
        ])
        return ToolTurnResponse(
            text: text,
            toolCalls: calls,
            transcript: ToolTranscript(items: carried + [assistant])
        )
    }

    private static func toolCall(in block: AIJSONValue) -> ToolCall? {
        guard
            block[ToolLoopKey.type]?.stringValue == ToolLoopKey.toolUse,
            let name = block[ToolLoopKey.name]?.stringValue, name.isEmpty == false
        else {
            return nil
        }
        return ToolCall(
            id: block[ToolLoopKey.id]?.stringValue ?? "",
            name: name,
            argumentsJSON: ToolWireEncoding.argumentsText(block[ToolLoopKey.input])
        )
    }
}
