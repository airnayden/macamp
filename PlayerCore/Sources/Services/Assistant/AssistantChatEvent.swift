// AssistantChatEvent — the ONE event vocabulary every chat tier reports in.
//
// ── WHY THIS IS NOT BEHIND `canImport(FoundationModels)` ──────────────────────
//
// Two tiers will produce these: the on-device ``LibraryChatSession`` (this wave)
// and the AIConnectorKit agentic loop (W4, which maps its own `ChatEvent` onto
// this type). A shell renders ONE transcript, so the two tiers must not have two
// event types — and a type gated on the FoundationModels SDK could not be the one
// the connector tier speaks. So the vocabulary lives at the floor, exactly like
// ``AssistantFailure`` and ``RawModelAvailability``: the FoundationModels types
// stay inside the gated island, and everything above the island trades in this.
//
// ── THESE ARE DATA, NOT COPY ──────────────────────────────────────────────────
//
// A tool name is a wire format (see ``LibraryTool``) and a result summary is the
// tool's own English sentence, addressed to a MODEL — the same audience and the
// same rationale as ``ToolArgumentError/message``. Neither is a
// `LocalizedStringResource` and neither may be rendered verbatim to a person: a
// shell shows a localized caption ("Searched your library") keyed off the NAME and
// treats the summary as a debug/inspection payload. That is why this file carries
// no String Catalog keys and is not in `check-hardcoded-strings.sh`'s scope
// (which scans `macOS/Sources` + `iOS/Sources`).
//
// ── `ChatTranscriptEntry` IS THE TESTABILITY SEAM ─────────────────────────────
//
// `Transcript.Entry` is a FoundationModels type, so a mapper written against it
// could only be tested on a macOS 26 host with the SDK present. This file's
// ``ChatTranscriptEntry`` is this module's own mirror of the five cases that SDK
// ships — the same trick ``RawModelAvailability`` plays on
// `SystemLanguageModel.Availability` — so ``AssistantChatEventMapping`` is a pure
// function over repo-internal types and every branch is table-testable anywhere.
// The gated translation lives in `LibraryChatTranscript.swift` and does nothing
// but move one enum onto the other.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation

/// One thing that happened while the assistant answered.
///
/// Ordered as it occurred, so a shell can render the turn as it unfolded: the
/// lookups the assistant performed, then what it said about them.
public enum AssistantChatEvent: Sendable, Equatable, Hashable {
    /// The assistant said something. Carries the model's own prose.
    case assistantText(String)
    /// The assistant decided to call a tool. `name` is the stable snake_case
    /// ``LibraryTool/name`` — a wire format, safe to key a localized caption off.
    case toolCall(name: String)
    /// A tool answered. `summary` is the tool's rendered text, already bounded by
    /// ``ToolProfile/onDevice``'s character budget. See the file header: this is
    /// data for inspection, not copy for display.
    ///
    /// `resultCount` is ``ToolResult/resultCount`` — how many results the lookup
    /// found, BEFORE the tier's budget dropped any rows — or `nil` when the answer
    /// was not list-shaped. It is the one number a shell may draw beside a lookup,
    /// and it travels here precisely so nobody has to count lines in `summary`.
    ///
    /// `rows` and `suggestions` are the STRUCTURED half of the same answer, built
    /// from ``ToolResultRow/payload`` by ``AssistantChatRow`` and empty for every
    /// tool that is not on its allow-list. They exist for the same reason
    /// `resultCount` does — a shell that wanted a track list would otherwise have
    /// to read one back out of `summary`, which is the "a shell that renders a
    /// model-facing string verbatim has a shell bug" failure one step removed.
    ///
    /// Both are DEFAULTED so a tier that carries no structure — and every existing
    /// labelled construction — keeps compiling and keeps meaning exactly what it
    /// meant before. Note that a default does NOT apply to pattern matching: a
    /// positional `case let .toolResult(a, b, c)` has to be widened by hand.
    case toolResult(
        name: String,
        summary: String,
        resultCount: Int?,
        rows: [AssistantChatRow] = [],
        suggestions: [AssistantChatSuggestion] = []
    )
}

/// One lookup a turn performed, as a shell draws it: what was done, and how much
/// came back.
///
/// A row is keyed to the tool CALL, because that is what the transcript renders in
/// order; the count comes from the matching result. `resultCount` is `nil` for a
/// tool whose answer is not a list, and for a call that never got an answer at all.
/// `rows` and `suggestions` come from the matching result too, and are empty for
/// every tool outside ``AssistantChatRow/rowCarryingToolNames``. Both are DEFAULTED
/// parameters: the shell's own tests construct this type, so a required parameter
/// would break a target no package-level command builds.
public struct AssistantChatActivity: Sendable, Equatable, Hashable {
    public let name: String
    public let resultCount: Int?
    public let rows: [AssistantChatRow]
    public let suggestions: [AssistantChatSuggestion]

    public init(
        name: String,
        resultCount: Int? = nil,
        rows: [AssistantChatRow] = [],
        suggestions: [AssistantChatSuggestion] = []
    ) {
        self.name = name
        self.resultCount = resultCount
        self.rows = rows
        self.suggestions = suggestions
    }
}

public extension AssistantChatEvent {
    /// The lookups in `events`, in call order, each paired with its own result.
    ///
    /// Calls and results are matched FIFO within a tool name rather than by
    /// position: both tiers guarantee a result follows its call, but neither
    /// guarantees the two are adjacent, and a turn can call one tool twice.
    /// An answered call is queued as a finished ``AssistantChatActivity`` rather
    /// than as a tuple of its parts: `large_tuple` caps a tuple at two members and
    /// an answer now carries three, and building the row here keeps "what a call
    /// reported" in one place.
    static func activity(in events: [AssistantChatEvent]) -> [AssistantChatActivity] {
        var answers: [String: [AssistantChatActivity]] = [:]
        for case let .toolResult(name, _, resultCount, rows, suggestions) in events {
            answers[name, default: []].append(AssistantChatActivity(
                name: name,
                resultCount: resultCount,
                rows: rows,
                suggestions: suggestions
            ))
        }
        var activity: [AssistantChatActivity] = []
        for case let .toolCall(name) in events {
            var queue = answers[name] ?? []
            let answered = queue.isEmpty ? AssistantChatActivity(name: name) : queue.removeFirst()
            answers[name] = queue
            activity.append(answered)
        }
        return activity
    }
}

/// One completed exchange: what the assistant finally said, and how it got there.
public struct AssistantChatTurn: Sendable, Equatable {
    /// The assistant's answer. May be empty if the model produced only tool calls.
    public let text: String
    /// Every event this turn produced, in the order the transcript recorded them.
    public let events: [AssistantChatEvent]

    public init(text: String, events: [AssistantChatEvent] = []) {
        self.text = text
        self.events = events
    }

    /// The names of the tools this turn actually invoked, in call order.
    ///
    /// The deterministic half of a turn: a model's WORDING varies run to run, but
    /// whether it reached for `list_genres` does not. Tests assert on this.
    public var calledToolNames: [String] {
        events.compactMap {
            if case let .toolCall(name) = $0 { return name }
            return nil
        }
    }

    /// The lookups this turn performed, each with its own result count.
    public var toolActivity: [AssistantChatActivity] {
        AssistantChatEvent.activity(in: events)
    }
}

/// Why a chat session could not be created.
///
/// A thin `Error` wrapper so the typed reason survives a `Result`/`throws` hop.
/// The reason — and therefore the user-facing explanation — is
/// ``AssistantUnavailableReason``'s, unchanged: there is exactly one table of
/// "why is the assistant off" messages in this module and this is not a second.
public struct AssistantChatUnavailable: Error, Sendable, Equatable, Hashable {
    public let reason: AssistantUnavailableReason

    public init(reason: AssistantUnavailableReason) {
        self.reason = reason
    }

    /// The user-facing explanation, resolved through the shells' String Catalogs.
    public var message: LocalizedStringResource {
        reason.message
    }
}

// MARK: - The transcript mirror

/// This module's mirror of `FoundationModels.Transcript.Entry`.
///
/// Exactly the five cases the macOS 26.5 SDK ships — `.instructions`, `.prompt`,
/// `.toolCalls`, `.toolOutput`, `.response`. Verified against the local SDK, not
/// against documentation:
///
///   IFACE="$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/\
///   FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/\
///   arm64e-apple-macos.swiftinterface"
///   awk '/public enum Entry/,/^    }/' "$IFACE" | grep '    case '
///
/// A `.reasoning` case exists in newer previews behind `#if compiler(>=6.4)` and
/// is ABSENT here; re-run that command before adding one. Because this is a
/// REPO-INTERNAL enum, every switch over it is exhaustive with no `default:` — a
/// sixth case has to break the build, which is precisely the reminder a future SDK
/// bump needs.
public enum ChatTranscriptEntry: Sendable, Equatable, Hashable {
    /// The session's instructions and tool definitions. Carried so a condensed
    /// transcript can keep them (see ``LibraryChatBudget``), never turned into an
    /// event — the listener did not say this and neither did the assistant.
    case instructions(String)
    /// The listener's own request. Not an event for the same reason: the shell
    /// already knows what it sent.
    case prompt(String)
    /// Tools the model decided to call, in call order.
    case toolCalls([String])
    /// One tool's answer.
    case toolOutput(name: String, text: String)
    /// The assistant's prose.
    case response(String)

    /// Every character this entry contributes to the context window.
    ///
    /// The input to the fallback token estimate used below macOS 26.4, where
    /// `SystemLanguageModel.tokenCount(for:)` does not exist.
    public var characterCount: Int {
        switch self {
        case let .instructions(text), let .prompt(text), let .response(text):
            text.count
        case let .toolCalls(names):
            names.reduce(0) { $0 + $1.count }
        case let .toolOutput(name, text):
            name.count + text.count
        }
    }
}

// MARK: - Mapping

/// Turns transcript entries into the events a shell renders.
public enum AssistantChatEventMapping {
    /// The events `entries` produced, in transcript order.
    ///
    /// `.instructions` and `.prompt` are DROPPED, not represented: the shell wrote
    /// the prompt and owns the instructions, so echoing either back would render
    /// the listener's own message twice. An empty or whitespace-only response
    /// segment is dropped too — the model emits one on a turn that was pure tool
    /// calling, and a blank bubble is worse than no bubble.
    ///
    /// Pure and floor-available: this is the function the mapping tests drive, and
    /// they need neither a model nor a macOS 26 host to do it.
    ///
    /// - Parameter counts: What the tool wrappers recorded for this turn. Absent by
    ///   default, because a transcript alone genuinely does not know — see
    ///   `LibraryChatToolCounts.swift`.
    public static func events(
        from entries: [ChatTranscriptEntry],
        counts: ChatToolResultCounts = ChatToolResultCounts()
    ) -> [AssistantChatEvent] {
        entries.flatMap { events(from: $0, counts: counts) }
    }

    /// The events one entry produces. Split out so the `flatMap` above stays a
    /// one-liner and this switch stays inside SwiftLint's complexity ceiling.
    static func events(from entry: ChatTranscriptEntry, counts: ChatToolResultCounts) -> [AssistantChatEvent] {
        switch entry {
        case .instructions, .prompt:
            []
        case let .toolCalls(names):
            names.map { .toolCall(name: $0) }
        case let .toolOutput(name, text):
            [toolResult(name: name, text: text, counts: counts)]
        case let .response(text):
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [.assistantText(text)]
        }
    }

    /// One tool's answer, with whatever the ledger recorded against it.
    ///
    /// The ledger is keyed on the rendered TEXT and knows nothing about tool names
    /// (see `LibraryChatToolCounts.swift`), so the allow-list is applied HERE — the
    /// first point that has both halves of the discriminator in hand. It is not a
    /// belt-and-braces check on the shape gate: a playback entry's payload is a
    /// strict subset of a track's, so this is the only thing that keeps a queue
    /// listing from being drawn as a library result.
    static func toolResult(name: String, text: String, counts: ChatToolResultCounts) -> AssistantChatEvent {
        let carriesRows = AssistantChatRow.carriesRows(toolNamed: name)
        return .toolResult(
            name: name,
            summary: text,
            resultCount: counts.resultCount(forRenderedText: text),
            rows: carriesRows ? counts.rows(forRenderedText: text) : [],
            suggestions: carriesRows ? counts.suggestions(forRenderedText: text) : []
        )
    }

    /// The assistant prose in `entries`, joined — the turn's answer text.
    ///
    /// Derived from the SAME entries the events come from rather than read off the
    /// response object separately, so the text a caller displays can never
    /// disagree with the events shown beside it.
    public static func answerText(from entries: [ChatTranscriptEntry]) -> String {
        entries.compactMap {
            if case let .response(text) = $0 { return text }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One finished turn, built from the entries a response appended.
    ///
    /// - Parameter fallbackText: The response object's own `content`. Used ONLY
    ///   when `entries` carry no prose at all — a shape the SDK is not documented
    ///   to produce, but one that would otherwise turn into a silently empty
    ///   answer beside a perfectly good list of tool events.
    public static func turn(
        from entries: [ChatTranscriptEntry],
        fallbackText: String,
        counts: ChatToolResultCounts = ChatToolResultCounts()
    ) -> AssistantChatTurn {
        let derived = answerText(from: entries)
        return AssistantChatTurn(
            text: derived.isEmpty ? fallbackText : derived,
            events: events(from: entries, counts: counts)
        )
    }
}
