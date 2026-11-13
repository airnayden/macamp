// LibraryChatToolCounts — how the on-device tier gets a row count out of a
// transcript that has no room for one.
//
// ── THE PROBLEM THIS SOLVES ──────────────────────────────────────────────────
//
// A FoundationModels `Tool.call` returns TEXT and nothing else, and
// `Transcript.Entry.toolOutput` carries that same text and the tool's name. There
// is no field on the round trip for `ToolResult.resultCount`, and there must not
// be one in the text: a number spelled into the model-facing prose would have to
// be parsed back out, which is the "a shell that renders a model-facing string
// verbatim has a shell bug" failure one step removed — and it would spend context
// on every turn saying something the shell already knows.
//
// So the count takes the SHORT WAY ROUND. The wrapper has the `ToolRunOutcome` in
// hand at the moment it answers; it records the count here, and the mapper reads
// it back when the same turn's entries are converted into events. Nothing about
// the text the model sees changes.
//
// ── WHY THE JOIN KEY IS THE RENDERED TEXT ────────────────────────────────────
//
// The obvious key is (tool name, call order), and it is wrong twice: the SDK is
// free to run a round's tool calls concurrently, so completion order need not be
// transcript order, and two calls to the same tool in one turn would then be
// paired by luck. The rendered text is the one value that is IDENTICAL on both
// sides by construction — the wrapper returns it and the transcript stores it —
// so the join is exact and order-independent.
//
// Two calls that produced the same text collide, and that collision is harmless
// rather than tolerated: identical rendered text means identical rows, which
// means an identical count. There is no key for which the two answers differ.
//
// This is NOT "parsing the rendered text": nothing is read OUT of the string. It
// is used as an opaque identity for a record this layer wrote itself, from
// structured data, one layer down.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant). It is deliberately NOT behind
// `canImport(FoundationModels)` — the mapper it feeds is floor-available, and so
// are its tests.
import Foundation

/// What one turn's tool calls reported, keyed by their answers.
///
/// The structured rows take the SAME short way round the count does, and for the
/// same reason: `ToolResultRow.payload` cannot ride a `toolOutput` entry either,
/// and reading a track list back out of the rendered text would be the failure this
/// file's header refuses, one type larger. The join key is unchanged — see above.
public struct ChatToolResultCounts: Sendable, Equatable {
    private var byRenderedText: [String: Int]
    private var rowsByRenderedText: [String: [AssistantChatRow]]
    private var suggestionsByRenderedText: [String: [AssistantChatSuggestion]]

    public init() {
        byRenderedText = [:]
        rowsByRenderedText = [:]
        suggestionsByRenderedText = [:]
    }

    /// Remembers what a tool answered, against the text it answered with.
    ///
    /// Each part is stored INDEPENDENTLY, so recording rows for an answer that is
    /// not list-shaped leaves the count absent rather than inventing a zero. A
    /// `nil` count is still not stored at all: an answer that is not list-shaped is
    /// the same as an answer nobody recorded, and storing the absence would only
    /// make the two indistinguishable from a lookup this layer never saw.
    public mutating func record(
        renderedText: String,
        resultCount: Int?,
        rows: [AssistantChatRow] = [],
        suggestions: [AssistantChatSuggestion] = []
    ) {
        if let resultCount {
            byRenderedText[renderedText] = resultCount
        }
        if !rows.isEmpty {
            rowsByRenderedText[renderedText] = rows
        }
        if !suggestions.isEmpty {
            suggestionsByRenderedText[renderedText] = suggestions
        }
    }

    /// The count recorded for `renderedText`, or `nil`.
    public func resultCount(forRenderedText renderedText: String) -> Int? {
        byRenderedText[renderedText]
    }

    /// The rows recorded for `renderedText`, or none.
    ///
    /// Empty rather than optional: "no rows" and "nothing recorded" are the same
    /// thing to every caller, and an optional would only add a `?? []` at each one.
    public func rows(forRenderedText renderedText: String) -> [AssistantChatRow] {
        rowsByRenderedText[renderedText] ?? []
    }

    public func suggestions(forRenderedText renderedText: String) -> [AssistantChatSuggestion] {
        suggestionsByRenderedText[renderedText] ?? []
    }

    public var isEmpty: Bool {
        byRenderedText.isEmpty && rowsByRenderedText.isEmpty && suggestionsByRenderedText.isEmpty
    }
}

/// The per-session ledger the five on-device wrappers write into.
///
/// An `actor` because the wrappers' `call` is `async` and the SDK may run a
/// round's calls concurrently. ``LibraryChatSession`` clears it at the start of
/// every attempt, so a turn is only ever joined against its own answers.
public actor LibraryChatToolCounts {
    private var counts = ChatToolResultCounts()

    public init() {}

    public func record(
        renderedText: String,
        resultCount: Int?,
        rows: [AssistantChatRow] = [],
        suggestions: [AssistantChatSuggestion] = []
    ) {
        counts.record(
            renderedText: renderedText,
            resultCount: resultCount,
            rows: rows,
            suggestions: suggestions
        )
    }

    public func snapshot() -> ChatToolResultCounts {
        counts
    }

    public func reset() {
        counts = ChatToolResultCounts()
    }
}
