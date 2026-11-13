// ChatGPTConnector+ToolLoop — the Responses API's tool-calling round, over the
// subscription backend.
//
// Split from `ChatGPTConnector.swift` for one mechanical reason: `.swiftlint.yml`
// does not override `file_length`, so the 400-line ceiling applies and CI runs
// `--strict`. Same precedent as `ChatGPTWireTypes.swift` and
// `ChatGPTResponseMapping.swift`. The stored properties and request helper this
// file uses were widened from `private` to `internal` for exactly this split.
//
// ── ARBITRARY CLIENT TOOLS ARE ACCEPTED HERE (recon 2026-08-28) ──────────────
//
// `chatgpt.com/backend-api/codex/responses` is WIRE-IDENTICAL to the public
// Responses API — only the host and the credential differ. Evidence, not
// inference: `openai/codex`'s Rust client builds ONE `ResponsesApiRequest` and
// posts it to either path (`codex-rs`, `tools/src/responses_api.rs`), and its
// tool list is client-defined rather than a fixed server-side menu. So a
// third-party function tool is a supported request shape on this backend, not a
// hopeful one.
//
// ── THE WIRE ────────────────────────────────────────────────────────────────
//
//   REQUEST   `tools: [{type: "function", name, description, parameters,
//             strict}]` — FLAT, with no `function` envelope. That is the third
//             of three spellings this kit sends; see ``ToolWireEncoding``.
//
//   RESPONSE  `output` is an ITEM LIST, not a message. Function calls arrive as
//             `{id, call_id, type: "function_call", name, arguments}`, where
//             `arguments` is a JSON string. `call_id` — NOT `id` — is what a
//             result is addressed to.
//
//   REPLY     Append `response.output` back into `input` and add
//             `{type: "function_call_output", call_id, output}` items.
//
// ── STATELESS, AND WHY REASONING ITEMS ARE REPLAYED ─────────────────────────
//
// `previous_response_id` is deliberately not used: the full `input` array is
// re-sent every round. That keeps the conversation entirely client-side — nothing
// is retained server-side to be resumed or leaked — and it composes with
// `store: false`, which the one-shot path already sends.
//
// The price of stateless mode is that anything the model produced and needs back
// must be replayed BY THE CLIENT. Reasoning items are exactly that: when the
// output carries a `reasoning` item and the next request does not, the model
// starts the round having forgotten why it called the tool, and answer quality
// degrades in a way that looks like a bad model rather than a lost item. So the
// output is carried through VERBATIM AND ENTIRELY — every item type, including
// ones this parser does not interpret — which also makes the adapter immune to
// item types the backend adds later.
//
// ── THE CAVEAT WAS TRUE, AND IT IS NOW CLOSED (MEASURED 2026-09-06) ──────────
//
// This section used to record an unreproduced third-party report that the
// backend rejects non-streaming requests. It was reproduced, against a live
// signed-in session: `stream: false` is HTTP 400 `{"detail":"Stream must be set
// to true"}`. The fix landed exactly where that note predicted it would — the
// request now asks for a stream, and the answer arrives as `text/event-stream`.
//
// It cost this file two lines. `ToolLoopKey.stream` is `true`, and the body goes
// through ``ChatGPTConnector/completedResponse(in:)`` before ``turnResponse``
// reads it — the SSE terminal event carries the COMPLETE `output` item list, so
// no delta assembly exists and none is wanted. The fixtures below that are plain
// JSON still pass, because the unwrapper returns a JSON object untouched.
import AIConnectorKit
import Foundation

extension ChatGPTConnector: ToolCallingConnector {
    public func chatTurn(_ request: ToolTurnRequest) async throws -> ToolTurnResponse {
        let carried = request.transcript.items + Self.functionCallOutputs(request.outcomes)
        let body = Self.toolLoopBody(request, carried: carried)
        let httpRequest = try await authorizedRequest(
            Self.responsesPath,
            method: "POST",
            accept: Self.streamAccept,
            body: body
        )
        let response = try await transport.send(httpRequest)
        try Self.validate(response)
        return try Self.turnResponse(Self.completedResponse(in: response.body), carried: carried)
    }
}

// MARK: - Request

extension ChatGPTConnector {
    /// The completion path, shared with the one-shot `respond` round-trip.
    static let responsesPath = "/responses"

    /// `max_output_tokens` is DELIBERATELY ABSENT from every `/responses` body.
    ///
    /// It shipped LIVE-UNVERIFIED behind a human check (F3) with the recorded
    /// prediction "if the live backend answers 400 naming the field, remove the
    /// field and keep the detection". MEASURED 2026-09-09: the backend answers
    /// HTTP 400 `{"detail":"Unsupported parameter: max_output_tokens"}` on every
    /// model, so the field is gone and the backend's own ceiling applies. The
    /// detection stays — ``ChatGPTConnector/truncationFailure(in:)`` still names
    /// a terminal `response.incomplete` for what it is.
    enum ToolLoopKey {
        static let model = "model"
        static let instructions = "instructions"
        static let input = "input"
        static let tools = "tools"
        static let toolChoice = "tool_choice"
        static let auto = "auto"
        static let store = "store"
        static let stream = "stream"
        static let type = "type"
        static let role = "role"
        static let content = "content"
        static let text = "text"
        static let message = "message"
        static let inputText = "input_text"
        static let outputText = "output_text"
        static let output = "output"
        static let functionCall = "function_call"
        static let functionCallOutput = "function_call_output"
        static let callID = "call_id"
        static let name = "name"
        static let arguments = "arguments"
    }

    static func toolLoopBody(_ request: ToolTurnRequest, carried: [AIJSONValue]) -> AIJSONValue {
        let prose = request.messages.map(inputMessage(_:))
        let framing = request.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return .object([
            ToolLoopKey.model: .string(request.model),
            ToolLoopKey.instructions: framing.isEmpty ? nil : .string(framing),
            ToolLoopKey.input: .array(prose + carried),
            ToolLoopKey.tools: request.tools.isEmpty
                ? nil
                : ToolWireEncoding.flatFunctionTools(request.tools),
            ToolLoopKey.toolChoice: request.tools.isEmpty ? nil : .string(ToolLoopKey.auto),
            ToolLoopKey.store: .bool(false),
            ToolLoopKey.stream: .bool(true),
        ])
    }

    /// A prose turn as a Responses input item.
    ///
    /// The content type differs by role — `input_text` for what the listener
    /// said, `output_text` for what the assistant said — because the API models
    /// an assistant turn as replayed OUTPUT even when it arrives as input.
    static func inputMessage(_ message: ChatMessage) -> AIJSONValue {
        let contentType = message.role == .assistant ? ToolLoopKey.outputText : ToolLoopKey.inputText
        return .object([
            ToolLoopKey.type: .string(ToolLoopKey.message),
            ToolLoopKey.role: .string(message.role.rawValue),
            ToolLoopKey.content: .array([.object([
                ToolLoopKey.type: .string(contentType),
                ToolLoopKey.text: .string(message.text),
            ])]),
        ])
    }

    /// One `function_call_output` item per call, addressed by `call_id`.
    static func functionCallOutputs(_ outcomes: [ToolCallOutcome]) -> [AIJSONValue] {
        outcomes.map { outcome in
            .object([
                ToolLoopKey.type: .string(ToolLoopKey.functionCallOutput),
                ToolLoopKey.callID: .string(outcome.call.id),
                ToolLoopKey.output: .string(outcome.text),
            ])
        }
    }
}

// MARK: - Response

extension ChatGPTConnector {
    static func turnResponse(_ body: Data, carried: [AIJSONValue]) throws -> ToolTurnResponse {
        guard
            let root = AIJSONValue.decoded(from: body),
            let output = root[ToolLoopKey.output]?.arrayValue
        else {
            throw ConnectorFailure.malformedResponse
        }
        let calls = output.compactMap(toolCall(in:))
        let text = messageText(in: output)
        guard text.isEmpty == false || calls.isEmpty == false else {
            throw ConnectorFailure.malformedResponse
        }
        // VERBATIM AND ENTIRE — reasoning items included. See the file header.
        return ToolTurnResponse(
            text: text,
            toolCalls: calls,
            transcript: ToolTranscript(items: carried + output)
        )
    }

    static func messageText(in output: [AIJSONValue]) -> String {
        output
            .filter { $0[ToolLoopKey.type]?.stringValue == ToolLoopKey.message }
            .flatMap { $0[ToolLoopKey.content]?.arrayValue ?? [] }
            .compactMap { $0[ToolLoopKey.text]?.stringValue }
            .joined()
    }

    /// `call_id`, not `id`: a `function_call_output` is addressed to the former,
    /// and the two are different strings on this API.
    private static func toolCall(in item: AIJSONValue) -> ToolCall? {
        guard
            item[ToolLoopKey.type]?.stringValue == ToolLoopKey.functionCall,
            let name = item[ToolLoopKey.name]?.stringValue, name.isEmpty == false
        else {
            return nil
        }
        return ToolCall(
            id: item[ToolLoopKey.callID]?.stringValue ?? "",
            name: name,
            argumentsJSON: ToolWireEncoding.argumentsText(item[ToolLoopKey.arguments])
        )
    }
}
