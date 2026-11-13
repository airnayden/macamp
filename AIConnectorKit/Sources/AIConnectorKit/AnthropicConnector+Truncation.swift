// AnthropicConnector+Truncation — the one failure a `/v1/messages` HTTP 200 can
// still be carrying.
//
// Its OWN file, not more of `AnthropicConnector.swift`, for the usual mechanical
// reason — `.swiftlint.yml` does not override `file_length`, that file sits at
// 383 of the 400-line ceiling, and CI runs `--strict`. Same precedent as
// `AnthropicWireTypes.swift` and `AnthropicConnector+ToolLoop.swift`.
//
// ── A CUT-OFF ANSWER IS A SUCCESSFUL RESPONSE ────────────────────────────────
//
// Anthropic ends a generation that hit `max_tokens` with `stop_reason:
// "max_tokens"` inside a normal 200 — no error object, no status to map, nothing
// for `throwIfFailed` to see. The `content` array is real and parses cleanly, so
// every reader downstream treats the fragment as the whole answer. A listener who
// asked for 43 songs got 20 and no indication that the other 23 exist.
//
// ── DISCARD, DO NOT CONTINUE ─────────────────────────────────────────────────
//
// The partial text is thrown away rather than returned with a warning, and no
// continuation request is issued. Resuming a truncated generation means replaying
// the turn with the fragment as an assistant prefix and stitching the halves — a
// protocol with its own failure modes (duplicated items, a seam mid-sentence,
// double the quota per ask) that is a feature, not a bug fix. Saying "that was
// cut off, ask for fewer" is the honest answer the shell can actually act on.
//
// ── SCOPE: THE CONVERSATION PATH ─────────────────────────────────────────────
//
// The detector below is called from ``AnthropicConnector/turnResponse(_:carried:)``
// — the tool-loop path, which is what BOTH Claude tiers travel
// (`ClaudeSubscriptionConnector.chatTurn` delegates to the wrapped
// `AnthropicConnector`), and the only one whose failures reach the chat surface's
// truncation copy. The one-shot `structuredCompletion` / `completion` paths are
// deliberately NOT wired here: their call sites live in `AnthropicConnector.swift`,
// which this work may not grow, and a truncated structured answer already fails as
// `malformedResponse` (its `tool_use` input is incomplete JSON). Wiring them is a
// two-line follow-up once that file has room.
import Foundation

extension AnthropicConnector {
    enum TruncationKey {
        static let stopReason = "stop_reason"
        static let maxTokens = "max_tokens"
    }

    /// Throws ``ConnectorFailure/truncated`` when the model stopped because it ran
    /// out of output budget.
    ///
    /// `throws` rather than returning a `Bool` so the caller spends no branch on
    /// it — ``AnthropicConnector/turnResponse(_:carried:)`` sits under SwiftLint's
    /// complexity ceiling and CI runs `--strict`.
    ///
    /// Called BEFORE the content is parsed, on purpose: a cut-off round has real
    /// `text` and possibly a real `tool_use` block, so a check placed after
    /// parsing would be a check the happy path routes around.
    static func throwIfTruncated(in body: Data) throws {
        guard isTruncated(in: body) else { return }
        throw ConnectorFailure.truncated
    }

    /// Whether a `/v1/messages` answer reports the `max_tokens` stop.
    ///
    /// Only that one value. `end_turn`, `tool_use`, `stop_sequence` and
    /// `pause_turn` are all ordinary completions, and `refusal` is the model
    /// declining — which is an answer, not a cut-off one.
    static func isTruncated(in body: Data) -> Bool {
        AIJSONValue.decoded(from: body)?[TruncationKey.stopReason]?.stringValue == TruncationKey.maxTokens
    }
}
