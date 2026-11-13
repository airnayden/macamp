// ConnectorChatEngine — connector + tools + history, composed once.
//
// What the shell needs is "answer this, using the library, and tell me what
// happened". That is ``ToolLoopEngine`` plus three things it deliberately does
// not own: which connector, which tools, and what was said before. This type is
// those three things and nothing else.
//
// ── STATELESS ON PURPOSE ────────────────────────────────────────────────────
//
// History goes IN as a parameter and comes back OUT in ``ConnectorChatTurn``;
// this type stores none of it. That keeps it `Sendable` and cheap to rebuild
// whenever composition rebuilds the AI graph — the same discipline every
// connector in the kit follows, where a settings change is expressed by building
// a new value rather than mutating a live one. W4 owns the `@Observable` store
// that holds the returned history; putting that store here would drag
// main-actor isolation into a type four connectors have to be callable from.
//
// ── THE HISTORY CAP IS A PAYLOAD BOUND, NOT A UX CHOICE ─────────────────────
//
// Every round of every turn re-sends the whole prose history — that is how all
// four wire formats work, and the ChatGPT adapter is additionally stateless by
// design. An uncapped history is therefore an unbounded request body that grows
// until the provider refuses it, and it grows fastest for the listener who uses
// the feature most. ``maxHistoryMessages`` bounds what is SENT; the returned
// history is never truncated, so a shell can still render the whole conversation.
import AIConnectorKit
import Foundation

/// What one `reply(to:history:)` produced.
public struct ConnectorChatTurn: Sendable, Equatable {
    /// The model's answer. Empty is possible under
    /// ``ToolLoopTermination/toolBudgetExhausted``.
    public var text: String
    /// Everything that happened during the turn, in order — the surface a shell
    /// renders tool activity from.
    public var events: [ChatEvent]
    public var termination: ToolLoopTermination
    /// The conversation to carry into the next turn: the history that was passed
    /// in, plus this turn's user message and the answer.
    public var history: [ChatMessage]
    /// Provider rounds this turn spent.
    public var rounds: Int

    public init(
        text: String,
        events: [ChatEvent],
        termination: ToolLoopTermination,
        history: [ChatMessage],
        rounds: Int
    ) {
        self.text = text
        self.events = events
        self.termination = termination
        self.history = history
        self.rounds = rounds
    }
}

/// A configured conversation: one connector, one model, one tool set.
public struct ConnectorChatEngine: Sendable {
    /// Prose turns re-sent with each request.
    ///
    /// Ten exchanges. A static constant rather than an init parameter because
    /// ``init(connector:model:tools:instructions:loop:)`` is already at
    /// SwiftLint's five-parameter ceiling, and because it is a payload bound the
    /// consent surface can quote — the same reason `ConnectorPayloadBudget`'s
    /// numbers live in one place.
    public static let maxHistoryMessages = 20

    public let connector: any ToolCallingConnector
    public let model: String
    public let tools: [AITool]
    /// System framing sent on every round.
    public let instructions: String
    public let loop: ToolLoopEngine

    public init(
        connector: any ToolCallingConnector,
        model: String,
        tools: [AITool],
        instructions: String = "",
        loop: ToolLoopEngine = ToolLoopEngine()
    ) {
        self.connector = connector
        self.model = model
        self.tools = tools
        self.instructions = instructions
        self.loop = loop
    }

    /// Answers `text`, using the tools, against `history`.
    ///
    /// Throws only ``ConnectorFailure`` and `CancellationError` — a misbehaving
    /// tool is answered in prose, never raised. See ``ToolLoopEngine``.
    public func reply(to text: String, history: [ChatMessage] = []) async throws -> ConnectorChatTurn {
        let request = ToolLoopRequest(
            instructions: instructions,
            history: Array(history.suffix(Self.maxHistoryMessages)),
            userText: text,
            tools: tools,
            model: model
        )
        let outcome = try await loop.run(request, connector: connector)
        return ConnectorChatTurn(
            text: outcome.text,
            events: outcome.events,
            termination: outcome.termination,
            history: Self.appended(history, userText: text, answer: outcome.text),
            rounds: outcome.rounds
        )
    }

    /// The user turn always lands; a BLANK answer does not.
    ///
    /// An exhausted tool budget can end a turn with no prose at all, and storing
    /// an empty assistant message would put a turn in the history that says
    /// nothing — re-sent on every subsequent round, and rendered as an empty
    /// bubble by any shell that trusts the history.
    static func appended(_ history: [ChatMessage], userText: String, answer: String) -> [ChatMessage] {
        var updated = history + [.user(userText)]
        if answer.isEmpty == false {
            updated.append(.assistant(answer))
        }
        return updated
    }
}
