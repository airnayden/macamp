// ChatMessage / ChatEvent — the two conversation surfaces, kept apart on purpose.
//
// ── HISTORY IS PROSE; A TURN IS A TRANSCRIPT ─────────────────────────────────
//
// ``ChatMessage`` is what SURVIVES a turn: the listener said this, the assistant
// answered that. It carries no tool material at all, because tool calls are an
// implementation detail of how one answer was reached and replaying them into the
// next turn would grow the context without bound — a ten-turn conversation would
// re-send every tool result it ever produced.
//
// ``ChatEvent`` is what HAPPENED during one turn, in order, so a shell can render
// "searching your library…" between the question and the answer. It is emitted
// once and never re-sent to a provider. W4 owns the rendering; this kit only
// guarantees the ORDER: every `.toolCall` is followed by its own `.toolResult`
// before the next call is announced, and a round's `.assistantText` precedes the
// calls that round emitted.
//
// The provider-native carry-over WITHIN a turn — the assistant content blocks
// Anthropic wants replayed verbatim, the reasoning items the Responses API wants
// replayed — is neither of these. It is ``ToolTranscript``, which is opaque to
// everything except the connector that produced it.
import Foundation

/// Who said something.
///
/// Two cases, not three: system framing is a separate `instructions` parameter on
/// every one of the four wire formats (Anthropic rejects `role: "system"`
/// outright, and the Responses API carries it as a top-level `instructions`
/// field), so modelling it as a role would invite a message this kit cannot send.
public enum ChatRole: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case user
    case assistant
}

/// One surviving conversation turn.
public struct ChatMessage: Sendable, Equatable, Hashable, Codable {
    public var role: ChatRole
    public var text: String

    public init(role: ChatRole, text: String) {
        self.role = role
        self.text = text
    }

    public static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, text: text)
    }

    public static func assistant(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: text)
    }
}

/// One thing that happened during a turn, in the order it happened.
///
/// Deliberately NOT `Codable`: an event is a live rendering surface, not state.
/// Persisting one would mean persisting a tool result, which is precisely the
/// material the history model above exists to leave behind.
public enum ChatEvent: Sendable, Equatable, Hashable {
    /// Prose the model emitted. A round may produce this, tool calls, or both.
    case assistantText(String)
    /// A tool the model asked for, with its arguments exactly as it wrote them.
    case toolCall(name: String, argumentsJSON: String)
    /// What that tool answered — the same text the model was handed back, plus
    /// ``AIToolOutput/resultCount`` when the answer was list-shaped, and the
    /// answer's structured half.
    ///
    /// The count and the rows ride HERE rather than being recovered from `text`,
    /// so a shell can say "— 12 results" and DRAW those twelve without parsing
    /// prose the tool is free to rephrase. The count is `nil` for a refusal, a
    /// digest, and a tool name that was never published; `rows` and `suggestions`
    /// are empty for all three, and for any tool whose answer is not a library
    /// list.
    ///
    /// `rows` and `suggestions` are DEFAULTED so every labelled construction site
    /// compiles untouched. Defaults do not apply to pattern matching, so a
    /// positional `case let .toolResult(a, b, c)` has to be widened by hand.
    case toolResult(
        name: String,
        text: String,
        resultCount: Int?,
        rows: [AIToolRow] = [],
        suggestions: [AIToolSuggestion] = []
    )
}
