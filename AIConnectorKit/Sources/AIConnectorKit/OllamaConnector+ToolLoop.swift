// OllamaConnector+ToolLoop — the native `/api/chat` tool-calling round.
//
// Split from `OllamaConnector.swift` for one mechanical reason: `.swiftlint.yml`
// does not override `file_length`, so the 400-line ceiling applies and CI runs
// `--strict`. The stored properties and transport helpers this file uses were
// widened from `private` to `internal` for exactly this split.
//
// ── OLLAMA IS THE ODD ONE OUT, IN TWO WAYS (recon 2026-08-28) ────────────────
//
// 1. `arguments` COMES BACK ALREADY PARSED. Every other provider sends the
//    model's arguments as a JSON **string** that a client has to parse;
//    `message.tool_calls[].function.arguments` here is a decoded JSON **object**.
//    ``ToolWireEncoding/argumentsText(_:)`` re-serialises it canonically so
//    ``ToolCall/argumentsJSON`` means the same thing on all four wires.
//
// 2. THERE IS NO CALL ID AT ALL. A tool call carries a name and arguments and
//    nothing else, and a result goes back as `{role: "tool", content, tool_name}`.
//    So results are matched by NAME and by POSITION, not by identifier, and this
//    adapter sends them back in the exact order the model emitted the calls —
//    which ``ToolLoopEngine`` preserves because it executes them in that order.
//
//    THE AMBIGUITY THAT LEAVES: if one round emits the SAME tool twice — say
//    `search_tracks` for "shoegaze" and again for "dream pop" — both results come
//    back under `tool_name: "search_tracks"`, and nothing on the wire says which
//    is which beyond their order. Ollama's own server pairs them positionally, so
//    emitting in order is the correct and only available behaviour; it is
//    recorded here because it is a real limitation of the format rather than of
//    this adapter, and because a future reader tempted to sort or de-duplicate
//    the results would silently swap two answers.
//
// `stream: false` is mandatory for the same reason the one-shot path sends it:
// Ollama streams by default and answers a streaming request with newline-delimited
// JSON objects, which is not one document and cannot be decoded as one.
//
// `strict` is NOT sent. Ollama documents the OpenAI-shaped `tools` envelope but
// not that flag, and it constrains decoding server-side anyway.
import Foundation

extension OllamaConnector: ToolCallingConnector {
    public func chatTurn(_ request: ToolTurnRequest) async throws -> ToolTurnResponse {
        let carried = request.transcript.items + Self.toolResultMessages(request.outcomes)
        let body = try ToolWireEncoding.body(Self.toolLoopBody(request, carried: carried))
        let httpRequest = await authorized(makeRequest(path: Endpoint.chat, body: body))
        let response = try await perform(httpRequest)
        return try Self.turnResponse(response.body, carried: carried)
    }
}

// MARK: - Request

extension OllamaConnector {
    enum ToolLoopKey {
        static let model = "model"
        static let messages = "messages"
        static let stream = "stream"
        static let tools = "tools"
        static let role = "role"
        static let content = "content"
        static let assistant = "assistant"
        static let tool = "tool"
        static let toolName = "tool_name"
        static let toolCalls = "tool_calls"
        static let function = "function"
        static let name = "name"
        static let arguments = "arguments"
        static let message = "message"
    }

    static func toolLoopBody(_ request: ToolTurnRequest, carried: [AIJSONValue]) -> AIJSONValue {
        var messages: [AIJSONValue] = []
        let framing = request.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if framing.isEmpty == false {
            messages.append(.object([
                ToolLoopKey.role: .string(Role.system),
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
        return .object([
            ToolLoopKey.model: .string(request.model),
            ToolLoopKey.messages: .array(messages),
            ToolLoopKey.stream: .bool(false),
            ToolLoopKey.tools: request.tools.isEmpty
                ? nil
                : ToolWireEncoding.nestedFunctionTools(request.tools, includesStrict: false),
        ])
    }

    /// One `role: "tool"` message per call, keyed by NAME and ordered by
    /// emission. See the file header for what that costs on a same-name pair.
    static func toolResultMessages(_ outcomes: [ToolCallOutcome]) -> [AIJSONValue] {
        outcomes.map { outcome in
            .object([
                ToolLoopKey.role: .string(ToolLoopKey.tool),
                ToolLoopKey.content: .string(outcome.text),
                ToolLoopKey.toolName: .string(outcome.call.name),
            ])
        }
    }
}

// MARK: - Response

extension OllamaConnector {
    static func turnResponse(_ body: Data, carried: [AIJSONValue]) throws -> ToolTurnResponse {
        guard
            let root = AIJSONValue.decoded(from: body),
            let message = root[ToolLoopKey.message]
        else {
            throw ConnectorFailure.malformedResponse
        }
        let rawCalls = message[ToolLoopKey.toolCalls]?.arrayValue ?? []
        let calls = rawCalls.compactMap(toolCall(in:))
        let text = message[ToolLoopKey.content]?.stringValue ?? ""
        // A `done_reason: "load"` warm-up answers 200 with neither prose nor a
        // call. The one-shot path calls that `.malformedResponse`; so does this.
        guard text.isEmpty == false || calls.isEmpty == false else {
            throw ConnectorFailure.malformedResponse
        }
        let assistant = AIJSONValue.object([
            ToolLoopKey.role: .string(ToolLoopKey.assistant),
            ToolLoopKey.content: .string(text),
            ToolLoopKey.toolCalls: rawCalls.isEmpty ? nil : .array(rawCalls),
        ])
        return ToolTurnResponse(
            text: text,
            toolCalls: calls,
            transcript: ToolTranscript(items: carried + [assistant])
        )
    }

    /// `id` is deliberately empty: this wire format has no call identifier at all.
    private static func toolCall(in entry: AIJSONValue) -> ToolCall? {
        guard
            let function = entry[ToolLoopKey.function],
            let name = function[ToolLoopKey.name]?.stringValue, name.isEmpty == false
        else {
            return nil
        }
        return ToolCall(
            id: "",
            name: name,
            argumentsJSON: ToolWireEncoding.argumentsText(function[ToolLoopKey.arguments])
        )
    }
}
