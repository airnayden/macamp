// ChatGPTBackendContract.swift — the two things `chatgpt.com/backend-api/codex`
// REQUIRES on the wire, measured against the live backend on 2026-09-06 with a
// real subscription credential, plus the reader that makes the second one cost
// nothing above it.
//
// Its own file rather than more of `ChatGPTConnector.swift` for the usual
// mechanical reason — `.swiftlint.yml` does not override `file_length`, the
// ceiling is 400 and CI runs `--strict` — and for one editorial one: these are
// PROVIDER FACTS with expiry dates, not connector policy, and keeping them
// together is what lets the next breakage be re-measured in one place.
//
// ── 1. `GET /models` REQUIRES `client_version`, AND IT GATES THE CATALOG ──────
//
//   omitted   → HTTP 400 `{"error":{"message":"[{'type': 'missing', 'loc':
//               ('query', 'client_version'), 'msg': 'Field required', …}]"}}`
//   `0.45.0`  → HTTP 200 and `{"models":[]}` — accepted, and EMPTY
//   `1.0.0`   → HTTP 200 and the full catalog
//
// The middle row is the dangerous one: an old-but-valid value is not an error,
// it is an empty model picker, which in the shell is indistinguishable from an
// account that owns no models. So the value is pinned and asserted, not guessed.
//
// ── 2. `POST /responses` REJECTS NON-STREAMING REQUESTS ──────────────────────
//
//   `stream: false` → HTTP 400 `{"detail":"Stream must be set to true"}`
//
// Note the second error dialect: this backend answers in `{"detail": …}` here
// and `{"error":{"message": …}}` above. ``ChatGPTConnector/diagnosticBody(_:)``
// retains raw text, so both survive without a parser for either.
//
// ── WHY "STREAMING" CHANGES NOTHING ABOVE THIS FILE ──────────────────────────
//
// ``HTTPTransport`` is request/response and ``URLSessionTransport`` buffers the
// entire body before returning, so the connector stays SINGLE-SHOT and stays
// bounded by the same `withDeadline` it always was. Only the WIRE FORMAT moved.
// ``completedResponse(in:)`` reduces the buffered SSE body to the bytes of the
// terminal `response.completed` event's `response` object — which is the same
// object the endpoint used to return whole — so ``ChatGPTResponsesReply`` and the
// tool-loop item parser both run unchanged on it.
//
// A body that is plain JSON is returned untouched. That is not defensive
// programming for its own sake: `stream: false` was a supported shape until this
// week, this backend has now flipped that answer twice, and a reader that only
// understands SSE would break on the flip back.
import AIConnectorKit
import Foundation

// MARK: - Catalog

public extension ChatGPTConnector {
    /// The `client_version` every `/models` request must carry.
    ///
    /// A PINNED CONSTANT, deliberately NOT MacAMP's own bundle or marketing
    /// version. The parameter names a codex-client CAPABILITY LEVEL the backend
    /// recognises, not the version of whoever is asking — feeding it a MacAMP
    /// release number would make a routine `1.2.3 → 1.3.0` bump silently change,
    /// or empty, the catalog a listener can reach. See this file's header for
    /// the measurement.
    static let catalogClientVersion = "1.0.0"
}

extension ChatGPTConnector {
    /// The catalog path, with the parameter the backend requires.
    static let modelsPath = "/models?client_version=\(ChatGPTConnector.catalogClientVersion)"

    /// What a `/responses` request accepts now that the answer is a stream.
    static let streamAccept = "text/event-stream"

    /// What every other request accepts, unchanged.
    static let jsonAccept = "application/json"
}

// MARK: - Stream envelope

extension ChatGPTConnector {
    enum StreamKey {
        static let dataField = "data:"
        static let doneSentinel = "[DONE]"
        static let type = "type"
        static let completed = "response.completed"
        static let incomplete = "response.incomplete"
        static let response = "response"
        static let status = "status"
        static let incompleteStatus = "incomplete"
        static let incompleteDetails = "incomplete_details"
        static let reason = "reason"
        static let maxOutputTokens = "max_output_tokens"
        static let error = "error"
        static let code = "code"
        static let usageLimitReached = "usage_limit_reached"
        static let resetsInSeconds = "resets_in_seconds"
        static let outputItemDone = "response.output_item.done"
        static let item = "item"
        static let output = "output"
    }

    /// The bytes of a `/responses` answer's FINAL response object.
    ///
    /// - Returns: `body` unchanged when it is already a JSON object, else the
    ///   terminal `response.completed` event's `response` object re-encoded.
    /// - Throws: ``ConnectorFailure/rateLimited(retryAfter:)`` for a mid-stream
    ///   quota failure, ``ConnectorFailure/truncated`` for a turn the model cut
    ///   short at its output ceiling, and ``ConnectorFailure/malformedResponse``
    ///   for any other in-stream failure or for a stream that never terminates.
    static func completedResponse(in body: Data) throws -> Data {
        if let value = AIJSONValue.decoded(from: body), value.objectValue != nil {
            try throwIfTruncated(value)
            return body
        }
        guard let text = String(bytes: body, encoding: .utf8) else {
            throw ConnectorFailure.malformedResponse
        }
        var terminal: AIJSONValue?
        var doneItems: [AIJSONValue] = []
        for payload in streamEvents(in: text) {
            if let failure = streamFailure(in: payload) {
                throw failure
            }
            if payload[StreamKey.type]?.stringValue == StreamKey.outputItemDone,
               let item = payload[StreamKey.item], item.objectValue != nil
            {
                doneItems.append(item)
            }
            guard payload[StreamKey.type]?.stringValue == StreamKey.completed,
                  let response = payload[StreamKey.response], response.objectValue != nil
            else {
                continue
            }
            terminal = withAssembledOutput(response, items: doneItems)
        }
        guard let terminal, let data = try? terminal.encodedData() else {
            throw ConnectorFailure.malformedResponse
        }
        return data
    }

    /// `response` unchanged when its own `output` already carries items, else
    /// with `output` replaced by the `response.output_item.done` items the
    /// stream delivered, in arrival order.
    ///
    /// MEASURED 2026-09-09: the backend's terminal `response.completed` now
    /// arrives with `"output": []` — the finished items appear ONLY as
    /// `response.output_item.done` events. A reader that trusted the terminal
    /// object alone handed every decoder an empty turn, which surfaced as
    /// "couldn't answer that" on a perfectly good answer. The terminal object
    /// still wins whenever it is populated, so a flip back costs nothing.
    static func withAssembledOutput(_ response: AIJSONValue, items: [AIJSONValue]) -> AIJSONValue {
        guard var fields = response.objectValue,
              response[StreamKey.output]?.arrayValue?.isEmpty != false,
              items.isEmpty == false
        else {
            return response
        }
        fields[StreamKey.output] = .array(items)
        return .object(fields)
    }

    /// Every event payload in an SSE body, decoded, in arrival order.
    ///
    /// A payload that is not JSON is DROPPED rather than fatal: a keep-alive
    /// comment or a field this reader does not model must not cost the answer
    /// that arrives three events later.
    static func streamEvents(in text: String) -> [AIJSONValue] {
        streamDataBlocks(in: text).compactMap(AIJSONValue.parsed(_:))
    }

    /// One joined `data:` value per event, `[DONE]` dropped.
    ///
    /// `event:`, `id:`, `retry:` and `:` comment lines are skipped on purpose —
    /// the payload's own `type` field names the event, and trusting the `event:`
    /// line instead would add a second, disagreeable source of truth.
    static func streamDataBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var pending: [String] = []
        for line in normalizedLines(in: text) {
            guard line.isEmpty == false else {
                appendBlock(pending, to: &blocks)
                pending = []
                continue
            }
            guard line.hasPrefix(StreamKey.dataField) else { continue }
            pending.append(dataValue(in: line))
        }
        // A final event with no trailing blank line is malformed SSE that real
        // servers still emit; reading it costs nothing and losing it costs the
        // whole answer.
        appendBlock(pending, to: &blocks)
        return blocks
    }

    /// The body's lines, with the SSE grammar's three line terminators —
    /// `\r\n`, `\n` and a bare `\r` — all reduced to one.
    ///
    /// The normalisation is not tidiness. Swift treats `"\r\n"` as a SINGLE
    /// `Character` (one grapheme cluster), so `split(separator: "\n")` does not
    /// split CRLF framing at all: a conforming stream would arrive as one
    /// enormous line with no terminal event in it.
    static func normalizedLines(in text: String) -> [Substring] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// The value of one `data:` line: the SSE grammar strips a SINGLE optional
    /// leading space and nothing else, because a multi-line data field's own
    /// whitespace is content.
    static func dataValue(in line: Substring) -> String {
        let value = line.dropFirst(StreamKey.dataField.count)
        return String(value.hasPrefix(" ") ? value.dropFirst() : value)
    }

    static func appendBlock(_ lines: [String], to blocks: inout [String]) {
        let joined = lines.joined(separator: "\n")
        guard joined.isEmpty == false, joined != StreamKey.doneSentinel else { return }
        blocks.append(joined)
    }

    /// The failure an event reports, or `nil` when it reports none.
    ///
    /// Only ONE shape maps precisely: `usage_limit_reached` carries
    /// `resets_in_seconds`, and it is the SAME condition that arrives pre-stream
    /// as an HTTP 429, so it must produce the same ``ConnectorFailure`` either
    /// way or the shell would tell the listener two different stories about one
    /// quota.
    ///
    /// Everything else is ``ConnectorFailure/malformedResponse`` — the
    /// taxonomy's own words for "answered successfully, then refused where
    /// content was expected". Synthesising an ``ConnectorFailure/httpStatus(_:body:)``
    /// out of a 200 would put a number in front of the listener that no server
    /// ever sent.
    ///
    /// A CUT-OFF answer is checked first because it is not an `error` object at
    /// all — the stream ends in a terminal event that reports success and simply
    /// stops, so nothing below this line would ever see it.
    static func streamFailure(in payload: AIJSONValue) -> ConnectorFailure? {
        if let cutOff = truncationFailure(in: payload) { return cutOff }
        guard let error = streamError(in: payload) else { return nil }
        let tokens = [error[StreamKey.type]?.stringValue, error[StreamKey.code]?.stringValue]
        guard tokens.contains(StreamKey.usageLimitReached) else { return .malformedResponse }
        return .rateLimited(retryAfter: error[StreamKey.resetsInSeconds]?.numberValue)
    }

    /// The error object an event carries, in the three places this backend puts
    /// one. A JSON `null` under `error` — which every SUCCESSFUL response object
    /// carries — reads as absent, which is why the object check is not optional.
    static func streamError(in payload: AIJSONValue) -> AIJSONValue? {
        if let error = payload[StreamKey.error], error.objectValue != nil {
            return error
        }
        if let error = payload[StreamKey.response]?[StreamKey.error], error.objectValue != nil {
            return error
        }
        guard payload[StreamKey.type]?.stringValue == StreamKey.error else { return nil }
        return payload
    }

    /// The truncation an EVENT reports, or `nil` when it reports none.
    ///
    /// The terminal event is `response.incomplete`, not `response.completed`, so
    /// the unwrapper's terminal check never matches it and the whole stream reads
    /// as "never terminated". That is the measured shape behind a long list that
    /// comes back as a generic shrug.
    static func truncationFailure(in payload: AIJSONValue) -> ConnectorFailure? {
        guard payload[StreamKey.type]?.stringValue == StreamKey.incomplete,
              let response = payload[StreamKey.response],
              isTruncated(response)
        else {
            return nil
        }
        return .truncated
    }

    /// The same check against a whole response OBJECT, for the plain-JSON body
    /// this reader still accepts.
    ///
    /// `throws` rather than returning a `Bool` so the caller spends no branch on
    /// it: ``completedResponse(in:)`` sits near SwiftLint's complexity ceiling
    /// and CI runs `--strict`.
    static func throwIfTruncated(_ response: AIJSONValue) throws {
        guard isTruncated(response) else { return }
        throw ConnectorFailure.truncated
    }

    /// Both halves are required. `status: "incomplete"` alone says the turn ended
    /// early; only `incomplete_details.reason` says the OUTPUT BUDGET is why, and
    /// that is the one cause "ask for fewer items" actually answers.
    static func isTruncated(_ response: AIJSONValue) -> Bool {
        response[StreamKey.status]?.stringValue == StreamKey.incompleteStatus
            && response[StreamKey.incompleteDetails]?[StreamKey.reason]?.stringValue == StreamKey.maxOutputTokens
    }
}
