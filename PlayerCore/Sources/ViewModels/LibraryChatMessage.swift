// LibraryChatMessage — the transcript a chat surface renders, and the tier-agnostic
// seam it is filled from.
//
// ── WHY AN ENGINE IS TWO CLOSURES AND NOT A PROTOCOL ──────────────────────────
//
// Two tiers answer a conversation and they cannot share a protocol conformance:
//
//   * ``LibraryChatSession`` is `@available(macOS 26, iOS 26, *)`, so a conformance
//     to a floor-available protocol would have to be availability-annotated, and an
//     availability-annotated conformance cannot be used from a floor-available
//     existential — which is exactly what this view model holds.
//   * `ConnectorChatEngine` lives in `AIConnectorBridge`, a module PlayerCore MUST
//     NOT import (the dependency direction is bridge -> PlayerCore).
//
// A struct of `@Sendable` closures crosses both boundaries for free: the shell
// builds it inside its own `#if canImport(FoundationModels)` + `if #available`
// island, or out of the bridge's engine, and this module never learns which. It is
// also the cheapest possible fake — a test supplies two closures and no test double
// type at all.
//
// ── EVENTS ARE DATA; THE SHELL WRITES THE COPY ────────────────────────────────
//
// ``AssistantChatEvent`` carries W1's stable snake_case tool NAME and the tool's own
// model-facing English summary. Note (2) of the W1 contract applies verbatim here: a
// shell keys a LOCALIZED caption off the name and treats the summary as inspection
// payload. Rendering a summary verbatim to a person is a shell bug, not a gap in
// this type.
//
// This file imports only Foundation + Services; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation
import Services

// MARK: - The tier seam

/// One completed turn as the view model needs it: the turn itself, plus the one
/// fact ``AssistantChatTurn`` cannot carry.
///
/// `isTruncated` is `ToolLoopTermination.toolBudgetExhausted` from the connector
/// tier — a turn that ran out of tool rounds and answered with whatever prose it
/// had. It is a per-turn NOTICE, not a failure: the answer above it is real. The
/// on-device tier has no such bound and always reports `false`.
public struct LibraryChatReply: Sendable, Equatable {
    public let turn: AssistantChatTurn
    public let isTruncated: Bool

    public init(turn: AssistantChatTurn, isTruncated: Bool = false) {
        self.turn = turn
        self.isTruncated = isTruncated
    }
}

/// One multi-turn conversation, whichever tier is answering it.
///
/// The engine owns its own history — the FoundationModels session in its transcript,
/// the connector adapter in a `[ChatMessage]` box — so `send` takes only the new
/// message. Discarding the engine is therefore how a conversation is reset, which is
/// what ``LibraryChatViewModel/reset()`` does.
public struct LibraryChatEngine: Sendable {
    /// Warms the tier's prefix. Called when the listener starts TYPING, never from
    /// construction — see note (8) of the W3 contract.
    public let prewarm: @Sendable () async -> Void
    /// Answers one message. Throws ``AssistantFailure``, ``AssistantChatUnavailable``
    /// or `CancellationError`; anything else is mapped to `.answerFailed`.
    public let send: @Sendable (String) async throws -> LibraryChatReply
    /// Whether this tier accepts a second, model-facing directive within one listener
    /// message — see ``LibraryChatViewModel/correctiveDirective``.
    ///
    /// A STORED property with a defaulted init parameter rather than a hardcoded
    /// constant, because the decision is the COMPOSITION ROOT's: it is the shell that
    /// knows which tier it just minted, and a fixed `let` would make the per-tier
    /// choice impossible while still compiling. It defaults to `false` so a tier has
    /// to opt in deliberately, and so every existing call site — the fakes in
    /// particular — keeps its exact behaviour.
    public let supportsCorrectiveFollowUp: Bool

    public init(
        prewarm: @escaping @Sendable () async -> Void,
        send: @escaping @Sendable (String) async throws -> LibraryChatReply,
        supportsCorrectiveFollowUp: Bool = false
    ) {
        self.prewarm = prewarm
        self.send = send
        self.supportsCorrectiveFollowUp = supportsCorrectiveFollowUp
    }
}

/// Why a turn a PROVIDER was answering failed, as a machine-readable reason.
///
/// A string token plus two optional numbers, not an enum, for the reason
/// `ConnectorFailure.DiagnosticToken` and the registry's `disabled(reason:)` are
/// strings: the taxonomy this describes lives in `AIConnectorKit`, a module
/// PlayerCore MUST NOT import, so mirroring it as a Swift enum here would either
/// duplicate a type across a boundary that exists to prevent exactly that, or make
/// a token a later build introduces unrepresentable. A token is DATA — it crosses
/// whole, and the shell owns the closed vocabulary that renders it, with a generic
/// sentence as the safe default.
///
/// `reason` is a ``Reason`` token, never copy, and rendering it to a person is a
/// shell bug. ``detail`` is the ONE field here a shell may show, and it is
/// deliberately narrow: the provider's own `error.message` sentence, already
/// trimmed and length-bounded by whoever produced it. A raw response body, a URL,
/// a header and a credential all remain unrepresentable — there is no field that
/// could carry one.
public struct LibraryChatProviderFailure: Sendable, Equatable, Hashable {
    /// A ``Reason`` token. Rendering it to a person is a shell bug.
    public let reason: String
    /// How long until the provider will answer again, when it said so. Meaningful
    /// for ``Reason/rateLimited``; `nil` everywhere else, and `nil` for a throttle
    /// that stated no duration.
    public let retryAfter: TimeInterval?
    /// The HTTP status. Meaningful for ``Reason/httpStatus``; `nil` everywhere else.
    /// The code only — the response body never crosses this boundary.
    public let statusCode: Int?
    /// The provider's own explanation, sanitized for display, or `nil` when it
    /// sent none.
    ///
    /// The producer's contract, not this type's to re-derive: exactly the
    /// `error.message` field of the provider's error payload, trimmed, and capped
    /// short enough to sit under a failure banner. A shell renders it as a
    /// SECONDARY line beneath its own typed copy — never as the sentence itself,
    /// because it is the provider's English and no catalog can translate it.
    public let detail: String?

    /// `detail` is defaulted so every existing call site keeps its exact meaning:
    /// a failure class that has no provider sentence simply does not pass one.
    public init(
        reason: String,
        retryAfter: TimeInterval? = nil,
        statusCode: Int? = nil,
        detail: String? = nil
    ) {
        self.reason = reason
        self.retryAfter = retryAfter
        self.statusCode = statusCode
        self.detail = detail
    }
}

public extension LibraryChatProviderFailure {
    /// The closed vocabulary of ``LibraryChatProviderFailure/reason`` values.
    ///
    /// Stable, machine-comparable, and kebab-case like every other token vocabulary
    /// in this repo. A shell switches over these with a `default:` that degrades to
    /// its generic sentence, so an unrecognised token is vague rather than fatal.
    enum Reason {
        /// The provider is throttling. ``LibraryChatProviderFailure/retryAfter``
        /// carries the wait when the provider stated one.
        public static let rateLimited = "rate-limited"
        /// The saved credential was rejected. Only re-authentication can fix it.
        public static let authExpired = "auth-expired"
        /// The provider could not be reached at all — refused, unresolved, offline,
        /// TLS failure, or a bot-mitigation challenge.
        public static let unreachable = "unreachable"
        /// A deadline elapsed before the provider replied.
        public static let timeout = "timeout"
        /// The provider answered with a status the turn could not use.
        /// ``LibraryChatProviderFailure/statusCode`` carries the number.
        public static let httpStatus = "http-status"
        /// The provider answered and stopped mid-answer at its own output ceiling.
        /// The partial text is discarded, never shown as though it were whole, so
        /// the listener's action is to ask for less.
        public static let truncated = "truncated"
    }
}

/// Why a turn produced no answer.
///
/// Coarse where a listener can do nothing, specific where they can. The provider-side
/// detail behind ``unavailable(_:)`` is written by the one availability table;
/// ``providerFailed(_:)`` carries the reason a reachable PROVIDER refused, because a
/// rate limit, an expired sign-in and an unreachable host ask for three different
/// actions and collapsing them sends diagnosis down a dead end. Everything with no
/// action behind it — a refusal, a malformed exchange, a cancelled probe — stays
/// ``answerFailed``.
public enum LibraryChatFailure: Error, Sendable, Equatable, Hashable {
    /// The tier could not be reached at all, with the reason the one availability
    /// table already writes copy for.
    case unavailable(AssistantUnavailableReason)
    /// The listener has not agreed to let this provider browse their library.
    ///
    /// Carries NO provider name: this module must never learn that `AIConnectorKit`
    /// exists (the dependency direction is bridge -> PlayerCore), which is the same
    /// structural reason ``AssistantTierDiagnostic``'s notice copy is
    /// provider-agnostic. The shell names the provider in the surface that OFFERS
    /// the disclosure; this is the commit-point backstop behind it.
    case consentRequired
    /// A provider answered the turn and refused it, for a reason the listener can act
    /// on. Carries no provider NAME, for the same structural reason
    /// ``consentRequired`` does not: the shell names the provider it selected.
    case providerFailed(LibraryChatProviderFailure)
    /// The tier was reachable and the turn still failed.
    case answerFailed
}

// MARK: - The transcript

/// One row of the conversation.
///
/// `Identifiable` by a minted `UUID` rather than by position, so SwiftUI keeps a row's
/// identity when a later turn is appended — a positional id would re-animate the
/// whole list on every message.
public struct LibraryChatMessage: Identifiable, Sendable, Equatable {
    public enum Role: String, Sendable, Equatable, Hashable, CaseIterable {
        case listener
        case assistant
    }

    public let id: UUID
    public let role: Role
    /// The listener's words, or the assistant's prose. Empty on a failed turn, and
    /// possibly empty on a turn that was pure tool calling.
    public let text: String
    /// What happened while the assistant answered, in transcript order. Always empty
    /// for a `.listener` row.
    public let events: [AssistantChatEvent]
    /// Proposals `propose_playlist` filed during THIS turn, in filing order.
    ///
    /// Collected from the composition root's ``ToolboxProposalFiling`` conformer
    /// rather than parsed out of `events`: the tool's rendered text is model-facing
    /// prose with no identifier in it, and W1 note (7) is explicit that filing is the
    /// only channel.
    public let proposalIds: [UUID]
    /// The turn hit the connector tier's tool-round budget. See ``LibraryChatReply``.
    public let isTruncated: Bool
    /// Set instead of `text` when the turn produced no answer at all.
    public let failure: LibraryChatFailure?
    /// Where a download started from THIS row's suggestions should be appended, or
    /// `nil` when the turn named no playlist at all.
    ///
    /// TURN-scoped rather than message-scoped: the playlist a turn is about is
    /// established by what the TOOLS did — a `propose_playlist` filing or a
    /// `get_playlist` read — and a corrective follow-up can establish it for the row
    /// ABOVE it (see ``LibraryChatViewModel``'s back-fill). A row with suggestions and
    /// no target is the plain-download case: the link still opens, nothing is linked.
    public let appendTarget: SuggestionAppendTarget?
    /// The profile a ``SuggestionAppendTarget/playlist(_:)`` target was read as.
    ///
    /// Filled ONLY for that case, from the read the tool layer reported, because that
    /// is the profile the tool actually ran as. A ``SuggestionAppendTarget/pendingProposal(_:)``
    /// leaves it `nil` on purpose: the proposal carries its own `profileId`, and the
    /// shell resolves it from the proposal store at registration time rather than
    /// having this layer restate it.
    public let appendProfileId: Int64?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String = "",
        events: [AssistantChatEvent] = [],
        proposalIds: [UUID] = [],
        isTruncated: Bool = false,
        failure: LibraryChatFailure? = nil,
        appendTarget: SuggestionAppendTarget? = nil,
        appendProfileId: Int64? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.events = events
        self.proposalIds = proposalIds
        self.isTruncated = isTruncated
        self.failure = failure
        self.appendTarget = appendTarget
        self.appendProfileId = appendProfileId
    }

    /// The listener's own message.
    public static func listener(_ text: String) -> LibraryChatMessage {
        LibraryChatMessage(role: .listener, text: text)
    }

    /// An answered turn.
    public static func assistant(
        _ reply: LibraryChatReply,
        proposalIds: [UUID] = [],
        appendTarget: SuggestionAppendTarget? = nil,
        appendProfileId: Int64? = nil
    ) -> LibraryChatMessage {
        LibraryChatMessage(
            role: .assistant,
            text: reply.turn.text,
            events: reply.turn.events,
            proposalIds: proposalIds,
            isTruncated: reply.isTruncated,
            appendTarget: appendTarget,
            appendProfileId: appendProfileId
        )
    }

    /// This row with its append target replaced, keeping its `id` and every other
    /// field exactly as they are.
    ///
    /// A REBUILD rather than a mutation because every field here is a `let` — the
    /// same constraint `SuggestionEnrichment.rebuilt` works under. The two rebuilds
    /// are independent and each copies the LIVE row, so whichever lands second
    /// preserves what the first one wrote.
    public func withAppendTarget(
        _ target: SuggestionAppendTarget?,
        profileId: Int64? = nil
    ) -> LibraryChatMessage {
        LibraryChatMessage(
            id: id,
            role: role,
            text: text,
            events: events,
            proposalIds: proposalIds,
            isTruncated: isTruncated,
            failure: failure,
            appendTarget: target,
            appendProfileId: profileId
        )
    }

    /// A turn that could not be answered.
    public static func assistant(failure: LibraryChatFailure) -> LibraryChatMessage {
        LibraryChatMessage(role: .assistant, failure: failure)
    }

    /// The tool names this row reports, in call order. The deterministic half of a
    /// turn — see ``AssistantChatTurn/calledToolNames``.
    public var calledToolNames: [String] {
        events.compactMap {
            if case let .toolCall(name) = $0 { return name }
            return nil
        }
    }

    /// The lookups this row reports, each with the result count its answer carried.
    ///
    /// What the transcript DRAWS. `calledToolNames` is kept beside it because a
    /// test asserting "did it reach for `list_genres`" should not have to know
    /// anything about counts.
    public var toolActivity: [AssistantChatActivity] {
        AssistantChatEvent.activity(in: events)
    }

    /// Whether this row has anything at all to draw.
    ///
    /// A pure-tool-calling turn with no prose and no proposal is not rendered as an
    /// empty bubble; the tool activity rows above it already said what happened.
    public var isEmpty: Bool {
        text.isEmpty && events.isEmpty && proposalIds.isEmpty && failure == nil
    }
}
