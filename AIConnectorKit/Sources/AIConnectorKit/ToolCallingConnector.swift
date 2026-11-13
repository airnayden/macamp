// ToolCallingConnector — one provider round of a tool-calling conversation.
//
// ── ONE ROUND, NOT ONE LOOP ──────────────────────────────────────────────────
//
// A conformer sends ONE request and maps ONE response. The loop — how many rounds
// are allowed, what deadline bounds each, which tool answers a call, what happens
// when the budget runs out — belongs to ``ToolLoopEngine`` and is written once.
// Four providers with four copies of a bounded retry loop is four places for the
// bound to be wrong, and the bound is the whole safety property.
//
// ── THE THREE THINGS A ROUND NEEDS, AND WHY THEY ARE SEPARATE ────────────────
//
//   `messages`    prose history. Provider-agnostic, survives the turn.
//   `transcript`  provider-NATIVE items accumulated within this turn. Opaque to
//                 everything but the connector that produced it — the loop moves
//                 it from one round to the next and never reads it.
//   `outcomes`    results of the calls the PREVIOUS round emitted, still
//                 undelivered. Empty on the first round.
//
// Splitting `transcript` from `outcomes` is what lets one engine drive four
// mutually incompatible wire formats. Anthropic wants the assistant's content
// array replayed verbatim and then ONE user message whose content STARTS with
// `tool_result` blocks; OpenAI wants an assistant message carrying `tool_calls`
// and then one `role: "tool"` message per call; Ollama wants the same but keyed
// by `tool_name` because it has no call-id concept at all; the ChatGPT Responses
// backend wants `response.output` items replayed — reasoning items included — and
// `function_call_output` items appended. Every one of those is "append the
// pending results, then append what the model just said, in my own shape", and
// each connector expresses it by returning the transcript it wants back.
//
// ── FAILURE AND DEADLINE CONTRACTS ARE INHERITED ─────────────────────────────
//
// ``AIProviderConnector``'s two contracts apply unchanged: ``chatTurn(_:)``
// throws ``ConnectorFailure`` and nothing else, and it is the CALLER that bounds
// runtime — ``ToolLoopEngine`` wraps every round in
// ``withDeadline(seconds:operation:)``, so a conformer must stay
// cancellation-cooperative.
import Foundation

// MARK: - Calls and results

/// One tool invocation the model emitted.
public struct ToolCall: Sendable, Equatable, Hashable {
    /// The provider's own identifier for this call, used to match the result back.
    ///
    /// EMPTY on Ollama, which has no call-id concept: its `/api/chat` tool calls
    /// carry only a name, and results are matched positionally by the order they
    /// are sent back. See ``OllamaConnector``'s tool-loop file for what that
    /// costs when a model emits the same tool twice in one round.
    public var id: String

    /// The tool's name, as published in ``AITool/name``.
    public var name: String

    /// The arguments as a JSON object string, exactly as the model wrote them.
    ///
    /// Normalized to TEXT even where the provider hands back a parsed object
    /// (Ollama does), so a tool sees the same argument shape whoever it is
    /// talking to and ``ChatEvent/toolCall(name:argumentsJSON:)`` renders one way.
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// What one tool answered, paired with the call it answers.
public struct ToolCallOutcome: Sendable, Equatable, Hashable {
    public var call: ToolCall
    /// The text handed back to the model — already clamped by the loop.
    public var text: String

    public init(call: ToolCall, text: String) {
        self.call = call
        self.text = text
    }
}

// MARK: - Carry-over

/// Provider-native conversation items accumulated within ONE turn.
///
/// Opaque outside the connector that wrote it. The engine copies it from a
/// response into the next request and never inspects it; a test asserts on it
/// precisely because it IS the provider's wire shape.
public struct ToolTranscript: Sendable, Equatable {
    /// Items in wire order, each in the provider's own vocabulary.
    public var items: [AIJSONValue]

    public init(items: [AIJSONValue] = []) {
        self.items = items
    }

    /// This transcript with `appended` added to the end.
    ///
    /// The one operation every adapter performs, spelled once so "results before
    /// the assistant turn that follows them" cannot be got backwards in one
    /// connector and right in three.
    public func appending(_ appended: [AIJSONValue]) -> ToolTranscript {
        ToolTranscript(items: items + appended)
    }

    /// Whether anything has been carried over yet — i.e. whether this is the
    /// first round of a turn.
    public var isEmpty: Bool {
        items.isEmpty
    }
}

// MARK: - Round

/// Everything one provider round needs.
///
/// A value type rather than six parameters: SwiftLint's `function_parameter_count`
/// ceiling is five and CI runs `--strict`, and a bundled request is what lets
/// ``ClaudeSubscriptionConnector`` RE-SHAPE a round before forwarding it — it
/// empties ``instructions`` and moves that text onto ``messages`` `[0]`, so the
/// OAuth edge sees a `system` field carrying its identity line and nothing else.
/// An adapter may therefore not assume the request it forwards is the one the
/// engine built.
public struct ToolTurnRequest: Sendable {
    /// System framing. Empty means "send none" — every adapter omits the field
    /// rather than sending a blank one.
    public var instructions: String
    /// Prose turns for this request, oldest first, INCLUDING the current user
    /// turn as the last entry. ``ToolLoopEngine`` appends it, so an adapter never
    /// has to special-case "the one that is being answered".
    public var messages: [ChatMessage]
    /// Provider-native carry-over from earlier rounds of this turn.
    public var transcript: ToolTranscript
    /// Results of the previous round's calls, still undelivered.
    public var outcomes: [ToolCallOutcome]
    /// The tools the model may call this round.
    public var tools: [AITool]
    /// A ``ModelInfo/id`` from ``AIProviderConnector/listModels()``.
    public var model: String

    public init(
        instructions: String = "",
        messages: [ChatMessage] = [],
        transcript: ToolTranscript = ToolTranscript(),
        outcomes: [ToolCallOutcome] = [],
        tools: [AITool] = [],
        model: String
    ) {
        self.instructions = instructions
        self.messages = messages
        self.transcript = transcript
        self.outcomes = outcomes
        self.tools = tools
        self.model = model
    }
}

/// What one provider round produced.
public struct ToolTurnResponse: Sendable, Equatable {
    /// Prose this round emitted. Empty when the model only called tools.
    public var text: String
    /// Calls the model emitted, in the order it emitted them.
    ///
    /// ORDER IS LOAD-BEARING: Ollama matches results positionally, and Anthropic
    /// requires one user message carrying a `tool_result` for every call in the
    /// assistant turn it answers.
    public var toolCalls: [ToolCall]
    /// The carry-over to hand back on the next round: the request's transcript
    /// PLUS this round's undelivered results PLUS what the model just said, all
    /// in the provider's own shape.
    public var transcript: ToolTranscript

    public init(text: String, toolCalls: [ToolCall] = [], transcript: ToolTranscript = ToolTranscript()) {
        self.text = text
        self.toolCalls = toolCalls
        self.transcript = transcript
    }

    /// Whether this round finished the turn.
    public var isFinal: Bool {
        toolCalls.isEmpty
    }
}

// MARK: - The seam

/// A connector that can run one round of a tool-calling conversation.
///
/// Refines ``AIProviderConnector`` rather than standing alone: a tool loop needs
/// the same identity, credential descriptor and model list as every other call,
/// and the failure/deadline contracts are stated there once.
public protocol ToolCallingConnector: AIProviderConnector {
    /// Sends one request and maps one response. See this file's header.
    func chatTurn(_ request: ToolTurnRequest) async throws -> ToolTurnResponse
}
