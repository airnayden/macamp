// ConnectorLibraryChat — the connector tier, adapted onto the one chat seam.
//
// ── THE EVENT MAPPING IS W2'S DOCUMENTED 1:1, WRITTEN OUT ─────────────────────
//
// `.omo/notepads/library-chat/decisions.md` (W2) states the mapping is total and
// drops exactly one field. This file IS that statement in code, and it is a `switch`
// with no `default:` on purpose — `ChatEvent` is repo-internal, so a fourth case has
// to break this build rather than silently render as nothing.
//
//   ChatEvent.assistantText(String)                     -> AssistantChatEvent.assistantText
//   ChatEvent.toolCall(name:argumentsJSON:)             -> .toolCall(name:)   [arguments dropped]
//   ChatEvent.toolResult(name:text:resultCount:         -> .toolResult(name:summary:resultCount:
//                        rows:suggestions:)                              rows:suggestions:)
//
// `name` is W1's stable snake_case `LibraryTool.name` on both sides and `text` is
// already `renderedText(profile: .cloud)`, so both tiers hand the surface the same
// vocabulary from the same source. There is deliberately NO third enum.
//
// `rows` and `suggestions` are the kit's mirror of the SAME two fields
// `AssistantChatEvent.toolResult` already carries, built by `LibraryToolAdapter`
// from PlayerCore's own discriminator — including its allow-list, which is applied
// on the bridge's side because the kit may not learn PlayerCore's tool names. So the
// copy below is a FIELD-FOR-FIELD move and nothing more: this file must never
// filter, cap or re-derive a row, because doing so would put a second copy of a
// discriminator that already exists on the other side of a module boundary.
//
// `resultCount` is W1's `ToolResult.resultCount`, carried through
// `AIToolOutput` -> `ChatEvent` unchanged. It is COPIED, never recomputed: this
// file must not learn how to count rows, because the two tiers render at
// different budgets and only the tool knows what it found.
//
// ── HISTORY LIVES HERE, BECAUSE THE ENGINE REFUSES TO OWN IT ──────────────────
//
// `ConnectorChatEngine` stores no history (W2 note 9): it takes one in and returns
// the next one. Something has to be the conversation, and it is this actor — an
// `actor` rather than a `@MainActor` class so a turn that spends sixty seconds on
// the network never holds main-actor isolation. Discarding it is how the surface
// resets a conversation, which is exactly the shape `LibraryChatSession` has too.
//
// ── THE SESSION CHECK IS THE CANCELLATION ─────────────────────────────────────
//
// `ConnectorSession.cancel()` already fires on a graph rebuild — a profile switch or
// a provider change — and `connectorReadiness(registry:connectorID:session:)` sets
// the precedent of consulting it BEFORE spending a round trip. A turn on a cancelled
// session raises `CancellationError`, which the view model renders as silence rather
// than as a failure the listener has to read.
//
// No `URLSession` appears here; every byte leaves through the connector.
import AIConnectorBridge
import AIConnectorKit
import Services
import ViewModels

/// The kit's `ChatEvent` on the one floor-available vocabulary.
enum ConnectorChatEventMapping {
    static func event(_ event: ChatEvent) -> AssistantChatEvent {
        switch event {
        case let .assistantText(text):
            .assistantText(text)
        case let .toolCall(name, _):
            .toolCall(name: name)
        case let .toolResult(name, text, resultCount, rows, suggestions):
            .toolResult(
                name: name,
                summary: text,
                resultCount: resultCount,
                rows: rows.map { AssistantChatRow(trackId: $0.trackId, title: $0.title, artist: $0.artist) },
                suggestions: suggestions.map { AssistantChatSuggestion(title: $0.title, artist: $0.artist) }
            )
        }
    }

    static func events(_ events: [ChatEvent]) -> [AssistantChatEvent] {
        events.map(event)
    }

    /// One connector turn as the surface reads it.
    static func reply(_ turn: ConnectorChatTurn) -> LibraryChatReply {
        LibraryChatReply(
            turn: AssistantChatTurn(text: turn.text, events: events(turn.events)),
            isTruncated: turn.termination == .toolBudgetExhausted
        )
    }
}

/// The kit's failure taxonomy on the chat surface's own vocabulary.
///
/// A `switch` with no `default:`, like every other consumer of `ConnectorFailure` —
/// a tenth case has to break this build rather than silently read as "couldn't
/// answer that". The three cases that return `nil` are refusing to translate on
/// purpose: `unconfigured` cannot happen on a turn the routing matrix already gated,
/// `malformedResponse` and `cancelled` have no action behind them, and all three keep
/// exactly the copy they render today.
///
/// Three payloads cross: the two numbers, and — on an HTTP status alone — the
/// provider's own `providerMessage`, which `ConnectorFailure` sanitizes to the
/// `error.message` sentence for exactly this purpose. The `underlying` diagnostic
/// token and the `body` stay behind: both are machine diagnostics by that type's own
/// contract, the body in particular being a truncated response payload, and the
/// reason a host was unreachable is not a distinction a listener can act on
/// differently.
enum ConnectorChatFailureMapping {
    static func chatFailure(for failure: ConnectorFailure) -> LibraryChatFailure? {
        switch failure {
        case let .rateLimited(retryAfter):
            .providerFailed(LibraryChatProviderFailure(
                reason: LibraryChatProviderFailure.Reason.rateLimited,
                retryAfter: retryAfter
            ))
        case .authExpired:
            .providerFailed(LibraryChatProviderFailure(reason: LibraryChatProviderFailure.Reason.authExpired))
        case .unreachable:
            .providerFailed(LibraryChatProviderFailure(reason: LibraryChatProviderFailure.Reason.unreachable))
        case .timeout:
            .providerFailed(LibraryChatProviderFailure(reason: LibraryChatProviderFailure.Reason.timeout))
        case let .httpStatus(code, _, providerMessage):
            .providerFailed(LibraryChatProviderFailure(
                reason: LibraryChatProviderFailure.Reason.httpStatus,
                statusCode: code,
                detail: providerMessage
            ))
        case .truncated:
            .providerFailed(LibraryChatProviderFailure(reason: LibraryChatProviderFailure.Reason.truncated))
        case .unconfigured, .malformedResponse, .cancelled:
            nil
        }
    }
}

/// One conversation with a provider, holding the prose history between turns.
actor ConnectorChatConversation {
    private let engine: ConnectorChatEngine
    private let isActive: @Sendable () async -> Bool
    private var history: [ChatMessage] = []

    init(engine: ConnectorChatEngine, isActive: @escaping @Sendable () async -> Bool) {
        self.engine = engine
        self.isActive = isActive
    }

    func reply(to text: String) async throws -> LibraryChatReply {
        guard await isActive() else { throw CancellationError() }
        do {
            let turn = try await engine.reply(to: text, history: history)
            history = turn.history
            return ConnectorChatEventMapping.reply(turn)
        } catch let failure as ConnectorFailure {
            // Translating HERE rather than in the view model is the whole crossing:
            // this is the last place that both knows what a `ConnectorFailure` is and
            // is talking to a type that must never learn. An untranslated case is
            // rethrown unchanged, so it lands on the generic sentence exactly as before.
            throw ConnectorChatFailureMapping.chatFailure(for: failure) ?? failure
        }
    }
}

extension ConnectorChatConversation {
    /// The tier seam over this conversation.
    ///
    /// `prewarm` is a no-op and correctly so: a provider round trip has no warm prefix
    /// to establish, and issuing a speculative request would cost a real one against
    /// the listener's quota for a keystroke they may never finish.
    ///
    /// `supportsCorrectiveFollowUp` is on because this conversation HOLDS its history:
    /// the directive lands as the next turn of the exchange the listener's ask is
    /// already in, so the model still has the request it is being nudged about. It is
    /// set here rather than in `AppEnvironment` because this is where the connector
    /// tier's engine value is actually minted.
    nonisolated var engineValue: LibraryChatEngine {
        LibraryChatEngine(
            prewarm: {},
            send: { text in try await self.reply(to: text) },
            supportsCorrectiveFollowUp: true
        )
    }
}
