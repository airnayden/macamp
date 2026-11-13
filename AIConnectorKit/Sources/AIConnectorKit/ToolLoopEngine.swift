// ToolLoopEngine — the ONE bounded tool-calling loop, written once for four
// providers.
//
// ── EVERY BOUND IS CLIENT-SIDE, SO EVERY BOUND LIVES HERE ────────────────────
//
// No provider limits how many times a model may call a tool before answering; all
// four will happily keep emitting calls for as long as a client keeps answering
// them. The only thing standing between "the model got confused" and an unbounded
// spend is the client's own ceiling, which makes that ceiling a safety property
// rather than a tuning knob — and safety properties get exactly one
// implementation. Four connectors with four copies of this loop is four places
// for the ceiling to be wrong.
//
// Four bounds, all enforced here:
//
//   ROUNDS   ``maxToolRounds`` (default 20). Hitting it returns
//            ``ToolLoopTermination/toolBudgetExhausted`` WITH whatever text the
//            model has produced — never a silent stop and never an empty answer
//            that reads like a provider failure.
//   TIME     Every provider round is wrapped in
//            ``withDeadline(seconds:operation:)``. Per ROUND, not per turn: the
//            round cap already bounds the count, and a whole-turn deadline would
//            make a slow first round steal the budget of a fast second one.
//   SIZE     Each tool result is clamped to ``maxToolResultCharacters``. The
//            caller is expected to have capped it already (PlayerCore's
//            `ToolProfile.cloud` renders at most 8 KB), but "the caller capped
//            it" is a claim about a caller this kit does not own.
//   ROWS     A result's structured half is clamped to ``AIToolOutput/maxRows``,
//            on exactly the SIZE bound's reasoning: PlayerCore caps at fifty too,
//            and this is the backstop for the day some other caller does not.
//
// ── TOOL FAILURES ARE CONVERSATION, NOT CONTROL FLOW ─────────────────────────
//
// ``AITool/execute`` cannot throw, and a call naming a tool that was never
// published comes back as a sentence the model can read and correct against
// rather than as an error that ends the turn. That is the same decision
// PlayerCore's `LibraryToolbox.run(_:arguments:profile:)` makes one layer down,
// and it is why a hallucinated tool name costs one wasted round instead of a
// visible failure.
import Foundation

// MARK: - Request

/// One whole conversation turn: a question, the history behind it, and the tools
/// that may be used to answer it.
public struct ToolLoopRequest: Sendable {
    /// System framing, sent on every round.
    public var instructions: String
    /// Prose turns that survived earlier turns, oldest first.
    public var history: [ChatMessage]
    /// What the listener just asked.
    public var userText: String
    /// The tools the model may call.
    public var tools: [AITool]
    /// A ``ModelInfo/id`` from ``AIProviderConnector/listModels()``.
    public var model: String

    public init(
        instructions: String = "",
        history: [ChatMessage] = [],
        userText: String,
        tools: [AITool] = [],
        model: String
    ) {
        self.instructions = instructions
        self.history = history
        self.userText = userText
        self.tools = tools
        self.model = model
    }
}

// MARK: - Outcome

/// How a turn ended.
///
/// A TYPED terminal state rather than a bare string, because the two cases mean
/// different things to a shell: one is an answer, the other is an answer that was
/// cut short and should say so.
public enum ToolLoopTermination: Sendable, Equatable, Hashable {
    /// The model stopped calling tools and answered.
    case answered
    /// ``ToolLoopEngine/maxToolRounds`` was reached with the model still calling
    /// tools. ``ToolLoopOutcome/text`` holds whatever prose exists — possibly
    /// none.
    case toolBudgetExhausted
}

/// What one turn produced.
public struct ToolLoopOutcome: Sendable, Equatable {
    /// The model's final prose. Empty is possible under
    /// ``ToolLoopTermination/toolBudgetExhausted``.
    public var text: String
    /// Everything that happened, in order. See ``ChatEvent``.
    public var events: [ChatEvent]
    public var termination: ToolLoopTermination
    /// Provider rounds actually performed.
    public var rounds: Int

    public init(text: String, events: [ChatEvent], termination: ToolLoopTermination, rounds: Int) {
        self.text = text
        self.events = events
        self.termination = termination
        self.rounds = rounds
    }
}

// MARK: - The loop

/// Drives a ``ToolCallingConnector`` through a bounded tool-calling turn.
public struct ToolLoopEngine: Sendable {
    /// Provider rounds one turn may spend.
    ///
    /// Twenty is deliberately generous for the library tool set — a
    /// "make me a playlist" turn realistically spends three to six — and still
    /// finite. It is a RUNAWAY guard, not a quality setting: lowering it would
    /// start truncating legitimate multi-step answers, and the honest ceiling is
    /// the one a working conversation never reaches.
    public static let defaultMaxToolRounds = 20

    /// Seconds one provider round may take.
    ///
    /// Longer than ``URLSessionTransport/requestTimeout`` (20 s) because a round
    /// that must also generate an answer is not the same shape as a one-shot
    /// classification, and shorter than anything a listener would call "stuck".
    /// Worst-case turn time is this times ``maxToolRounds``, which is exactly why
    /// the round cap is not optional.
    public static let defaultRoundDeadlineSeconds: TimeInterval = 60

    /// Characters one tool result may occupy on the wire.
    ///
    /// A BACKSTOP over PlayerCore's own 8 KB `ToolProfile.cloud` cap, sized to
    /// `ToolResultBudget.externalCharacterLimit` so the widest tier this kit
    /// could ever be handed still passes through untouched.
    public static let maxToolResultCharacters = 16 * 1024

    /// Appended to a result the size clamp had to cut, so the model can tell a
    /// short answer from a truncated one.
    public static let truncationMarker = "… [truncated]"

    public let maxToolRounds: Int
    public let roundDeadlineSeconds: TimeInterval

    public init(
        maxToolRounds: Int = ToolLoopEngine.defaultMaxToolRounds,
        roundDeadlineSeconds: TimeInterval = ToolLoopEngine.defaultRoundDeadlineSeconds
    ) {
        self.maxToolRounds = maxToolRounds
        self.roundDeadlineSeconds = roundDeadlineSeconds
    }

    /// Runs `request` against `connector` until it answers or the budget runs out.
    ///
    /// Throws only ``ConnectorFailure`` (from the connector or from the round
    /// deadline) and `CancellationError`. A tool that misbehaves never throws —
    /// see this file's header.
    public func run(
        _ request: ToolLoopRequest,
        connector: any ToolCallingConnector
    ) async throws -> ToolLoopOutcome {
        var turn = ToolTurnRequest(
            instructions: request.instructions,
            messages: request.history + [.user(request.userText)],
            tools: request.tools,
            model: request.model
        )
        var events: [ChatEvent] = []
        var text = ""
        var rounds = 0

        while rounds < max(0, maxToolRounds) {
            rounds += 1
            let response = try await round(turn, connector: connector)
            if response.text.isEmpty == false {
                events.append(.assistantText(response.text))
                text = response.text
            }
            if response.isFinal {
                return ToolLoopOutcome(text: text, events: events, termination: .answered, rounds: rounds)
            }
            var outcomes: [ToolCallOutcome] = []
            for call in response.toolCalls {
                events.append(.toolCall(name: call.name, argumentsJSON: call.argumentsJSON))
                let result = await Self.execute(call, tools: request.tools)
                events.append(.toolResult(
                    name: call.name,
                    text: result.text,
                    resultCount: result.resultCount,
                    rows: result.rows,
                    suggestions: result.suggestions
                ))
                outcomes.append(ToolCallOutcome(call: call, text: result.text))
            }
            turn.transcript = response.transcript
            turn.outcomes = outcomes
        }

        return ToolLoopOutcome(text: text, events: events, termination: .toolBudgetExhausted, rounds: rounds)
    }
}

// MARK: - One round

private extension ToolLoopEngine {
    /// One deadline-bounded provider round.
    ///
    /// The request is copied into a local before the closure captures it so the
    /// `@Sendable` closure holds a value rather than a `var` the loop mutates.
    func round(_ request: ToolTurnRequest, connector: any ToolCallingConnector) async throws -> ToolTurnResponse {
        let pending = request
        return try await withDeadline(seconds: roundDeadlineSeconds) {
            try await connector.chatTurn(pending)
        }
    }

    /// Runs one call, or explains to the model why it could not be run.
    ///
    /// An unpublished name reports no count: nothing was looked up, so "0 results"
    /// would describe a lookup that never happened.
    ///
    /// This is where the backstops are applied, so the loop above can announce
    /// the answer as-is: the text is clamped to ``maxToolResultCharacters`` and
    /// the structured half to ``AIToolOutput/maxRows``.
    static func execute(_ call: ToolCall, tools: [AITool]) async -> AIToolOutput {
        guard let tool = tools.tool(named: call.name) else {
            return AIToolOutput(text: unknownToolMessage(call.name, tools: tools))
        }
        let output = await tool.execute(call.argumentsJSON)
        return AIToolOutput(
            text: clamped(output.text),
            resultCount: output.resultCount,
            rows: Array(output.rows.prefix(AIToolOutput.maxRows)),
            suggestions: Array(output.suggestions.prefix(AIToolOutput.maxRows))
        )
    }

    /// Model-facing English, deliberately NOT localized: this is protocol payload
    /// addressed to a model that will retry against it, exactly like PlayerCore's
    /// `LibraryToolError.message`. A shell that renders one to a person has a
    /// shell bug.
    static func unknownToolMessage(_ name: String, tools: [AITool]) -> String {
        let available = tools.map(\.name).joined(separator: ", ")
        guard available.isEmpty == false else {
            return "There is no tool named \"\(name)\", and no tools are available."
        }
        return "There is no tool named \"\(name)\". Available tools: \(available)."
    }

    static func clamped(_ text: String) -> String {
        guard text.count > maxToolResultCharacters else { return text }
        let keep = max(0, maxToolResultCharacters - truncationMarker.count)
        return String(text.prefix(keep)) + truncationMarker
    }
}
