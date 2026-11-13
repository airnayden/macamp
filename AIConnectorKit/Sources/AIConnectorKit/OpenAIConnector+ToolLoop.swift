// OpenAIConnector+ToolLoop — Chat Completions' tool-calling round.
//
// Split from `OpenAIConnector.swift` for one mechanical reason: `.swiftlint.yml`
// does not override `file_length`, so the 400-line ceiling applies and CI runs
// `--strict`. The stored properties and request helpers this file uses were
// widened from `private` to `internal` for exactly this split.
//
// ── STAYING ON `/v1/chat/completions` IS A DECISION ──────────────────────────
//
// The Responses API is the newer surface, but this connector's one-shot methods
// already speak Chat Completions and its `response_format` dialect. Moving the
// tool loop alone would give one connector two base paths, two auth-identical but
// shape-incompatible request builders, and two failure-mapping tables — for a
// feature both surfaces support. The ChatGPT SUBSCRIPTION connector speaks
// Responses because its backend accepts nothing else; that is a different
// constraint, not a different preference.
//
// ── THE WIRE (recon 2026-08-28) ─────────────────────────────────────────────
//
//   REQUEST   `tools: [{type: "function", function: {name, description,
//             parameters, strict}}]` — the NESTED envelope. `tool_choice: "auto"`
//             is a bare string here, not the object Anthropic wants.
//
//   RESPONSE  `choices[0].message.tool_calls: [{id, type: "function",
//             function: {name, arguments}}]`, where `arguments` is a JSON
//             ***STRING***, not an object. Ollama is the odd one out on that and
//             hands back a decoded object; ``ToolWireEncoding/argumentsText(_:)``
//             normalises both to text.
//
//   REPLY     One `{role: "tool", tool_call_id, content}` message per call,
//             after the assistant message that emitted them.
//
// ── THE ASSISTANT TURN IS REBUILT, NOT ECHOED ────────────────────────────────
//
// Anthropic's reply rule is "replay the content array verbatim", so its adapter
// does. This one rebuilds `{role, content, tool_calls}` from the response instead
// of echoing the whole message object, because a Chat Completions assistant
// message also carries provider-internal fields (`refusal: null`, `annotations`,
// `audio`) that are OUTPUT-only. `tool_calls` and `content` are still carried
// through as the exact JSON values that arrived — only the envelope is rebuilt.
//
// ── A REFUSAL IS AN ANSWER HERE, AND A FAILURE IN `structuredCompletion` ─────
//
// The one-shot structured path treats `message.refusal` as
// ``ConnectorFailure/malformedResponse``: it asked for a schema-shaped object and
// did not get one, so there is nothing to return. A CONVERSATION that gets a
// refusal got a perfectly good turn — the model said why it would not help — and
// reporting "malformed response" would replace the model's own sentence with a
// diagnostic. So the refusal becomes the turn's text and still reaches the
// ``OpenAIConnector/init(apiKey:transport:onRefusal:)`` sink. Deliberate
// divergence; the one-shot methods are untouched.
import Foundation

extension OpenAIConnector: ToolCallingConnector {
    public func chatTurn(_ request: ToolTurnRequest) async throws -> ToolTurnResponse {
        let carried = request.transcript.items + Self.toolResultMessages(request.outcomes)
        let body = Self.toolLoopBody(request, carried: carried)
        let httpRequest = try await postRequest(Self.chatCompletionsPath, body: body)
        let response = try await transport.send(httpRequest)
        try Self.validate(response)
        return try turnResponse(response.body, carried: carried)
    }
}

// MARK: - Request

extension OpenAIConnector {
    /// The completion path, spelled once and shared with the one-shot `chat`
    /// round-trip's literal.
    static let chatCompletionsPath = "/chat/completions"

    enum ToolLoopKey {
        static let model = "model"
        static let messages = "messages"
        static let tools = "tools"
        static let toolChoice = "tool_choice"
        static let auto = "auto"
        static let role = "role"
        static let content = "content"
        static let refusal = "refusal"
        static let system = "system"
        static let assistant = "assistant"
        static let tool = "tool"
        static let toolCalls = "tool_calls"
        static let toolCallID = "tool_call_id"
        static let id = "id"
        static let function = "function"
        static let name = "name"
        static let arguments = "arguments"
        static let choices = "choices"
        static let message = "message"
    }

    static func toolLoopBody(_ request: ToolTurnRequest, carried: [AIJSONValue]) -> AIJSONValue {
        var messages: [AIJSONValue] = []
        let framing = request.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if framing.isEmpty == false {
            messages.append(.object([
                ToolLoopKey.role: .string(ToolLoopKey.system),
                ToolLoopKey.content: .string(framing),
            ]))
        }
        messages += request.messages.map { message in
            AIJSONValue.object([
                ToolLoopKey.role: .string(message.role.rawValue),
                ToolLoopKey.content: .string(message.text),
            ])
        }
        messages += carried
        let hasTools = request.tools.isEmpty == false
        return .object([
            ToolLoopKey.model: .string(request.model),
            ToolLoopKey.messages: .array(messages),
            ToolLoopKey.tools: hasTools ? ToolWireEncoding.nestedFunctionTools(request.tools) : nil,
            ToolLoopKey.toolChoice: hasTools ? .string(ToolLoopKey.auto) : nil,
        ])
    }

    /// One `role: "tool"` message per call, in the order the model emitted them.
    static func toolResultMessages(_ outcomes: [ToolCallOutcome]) -> [AIJSONValue] {
        outcomes.map { outcome in
            .object([
                ToolLoopKey.role: .string(ToolLoopKey.tool),
                ToolLoopKey.toolCallID: .string(outcome.call.id),
                ToolLoopKey.content: .string(outcome.text),
            ])
        }
    }
}

// MARK: - Response

extension OpenAIConnector {
    func turnResponse(_ body: Data, carried: [AIJSONValue]) throws -> ToolTurnResponse {
        guard
            let root = AIJSONValue.decoded(from: body),
            let message = root[Self.ToolLoopKey.choices]?.arrayValue?.first?[Self.ToolLoopKey.message]
        else {
            throw ConnectorFailure.malformedResponse
        }
        let rawCalls = message[Self.ToolLoopKey.toolCalls]?.arrayValue ?? []
        let calls = rawCalls.compactMap(Self.toolCall(in:))
        let text = Self.assistantText(in: message, onRefusal: onRefusal)
        guard text.isEmpty == false || calls.isEmpty == false else {
            throw ConnectorFailure.malformedResponse
        }
        return ToolTurnResponse(
            text: text,
            toolCalls: calls,
            transcript: ToolTranscript(items: carried + [Self.assistantMessage(message, rawCalls: rawCalls)])
        )
    }

    /// The model's prose, or its refusal when it declined. See the file header.
    static func assistantText(in message: AIJSONValue, onRefusal: (@Sendable (String) -> Void)?) -> String {
        if let refusal = message[ToolLoopKey.refusal]?.stringValue, refusal.isEmpty == false {
            onRefusal?(refusal)
            return refusal
        }
        return message[ToolLoopKey.content]?.stringValue ?? ""
    }

    /// The assistant turn to replay. Rebuilt, not echoed — see the file header.
    static func assistantMessage(_ message: AIJSONValue, rawCalls: [AIJSONValue]) -> AIJSONValue {
        .object([
            ToolLoopKey.role: .string(ToolLoopKey.assistant),
            ToolLoopKey.content: message[ToolLoopKey.content] ?? .null,
            ToolLoopKey.toolCalls: rawCalls.isEmpty ? nil : .array(rawCalls),
        ])
    }

    private static func toolCall(in entry: AIJSONValue) -> ToolCall? {
        guard
            let function = entry[ToolLoopKey.function],
            let name = function[ToolLoopKey.name]?.stringValue, name.isEmpty == false
        else {
            return nil
        }
        return ToolCall(
            id: entry[ToolLoopKey.id]?.stringValue ?? "",
            name: name,
            argumentsJSON: ToolWireEncoding.argumentsText(function[ToolLoopKey.arguments])
        )
    }
}
