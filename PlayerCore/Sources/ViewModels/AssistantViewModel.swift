// AssistantViewModel — the one door every AI mutation in MacAMP goes through.
//
// Two methods, and the gap between them is the whole feature:
//
//   submit(text:profileId:)              READS ONLY. Parses, selects, ranks, and
//                                        puts an ``AIProposal`` in the store.
//                                        Touches no writer and no write transaction.
//   apply(_:confirmedBatch:)             The ONLY code that writes. Always called
//                                        by the listener, never by `submit`.
//
// There is deliberately no method that both generates and applies, so "the AI
// changed my library without asking" is not a bug that can be introduced by a
// careless call site — it would require a new API.
//
// ── THE LADDER ─────────────────────────────────────────────────────────────────
//
// Availability gates the FoundationModels tier ONLY — with one exception.
// `.intelligenceDisabled` is the listener's own switch and stops everything:
// with AI off the assistant must produce nothing at all. Every other reason
// (`deviceNotEligible`, `osTooOld`, `modelNotReady`, `appleIntelligenceNotEnabled`)
// means only "no model", and the lower tiers still answer — which is the point of
// having built them. So:
//
//   connector parser, if injected AND its OWN predicate passes -> deadline-bounded
//   FM parser, if injected AND available  ->  on ANY throw, fall through
//   heuristic parser (never throws, per its own contract)
//   deterministic default (its shape mirrors `HeuristicQueryParser`'s tier 4)
//
// The connector tier deliberately does NOT read ``AssistantAvailability``: that
// reading describes Apple Intelligence, and a third-party connector is exactly the
// thing that still works on a Mac which cannot run Apple Intelligence at all.
//
// The ladder itself lives in `AssistantViewModel+Ladder.swift`; a fall-through past
// a failing tier is recorded in ``lastTierDiagnostic`` so the UI can say which
// provider went quiet without changing where the answer came from.
//
// `submit` therefore NEVER throws to the caller: every path ends in a proposal or
// in a typed ``lastError`` the UI can explain.
//
// This file imports only Foundation + Observation + Metadata + Persistence +
// Services; it MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Metadata
import Observation
import Persistence
import Services

// MARK: - Dependency stacks

/// The natural-language backends, bundled so the view model's initialiser stays
/// inside SwiftLint's `function_parameter_count` budget.
public struct AssistantBackendStack: Sendable {
    /// How long the connector tier gets before the ladder stops waiting for it.
    public static let defaultConnectorDeadlineSeconds: Double = 20

    /// The tier that always answers. `HeuristicQueryParser` in production — its
    /// documented contract is that parsing never throws.
    public var fallbackParser: any NaturalLanguageQueryParsing
    /// The FoundationModels tier, or `nil` when composition could not build one
    /// (an SDK without the framework, or the feature switched off).
    public var modelParser: (any NaturalLanguageQueryParsing)?
    /// The third-party connector tier, tried FIRST, or `nil` when none is selected.
    public var connectorParser: (any NaturalLanguageQueryParsing)?
    /// The connector's OWN readiness predicate — never `AssistantAvailabilityProbe`,
    /// which describes Apple Intelligence and would wrongly veto a connector on a
    /// Mac that has none. Never consulted while ``connectorParser`` is `nil`, so an
    /// unconfigured stack costs exactly nothing.
    public var connectorAvailability: @Sendable () async -> Bool
    /// Optional generated naming. When absent — or when it throws — the listener's
    /// own request text names the playlist, which is data in their language by
    /// construction.
    public var naming: (any PlaylistNaming)?
    /// Optional generated narration, carried so ONE composition root owns every
    /// generative seam. This view model does not narrate; it hands the slot on.
    public var narrating: (any InsightNarrating)?
    /// Seconds the connector tier gets before the ladder abandons it and falls
    /// through. Configurable so a test can prove the bound without waiting.
    public var connectorDeadlineSeconds: Double

    public init(
        fallbackParser: any NaturalLanguageQueryParsing,
        modelParser: (any NaturalLanguageQueryParsing)? = nil,
        connectorParser: (any NaturalLanguageQueryParsing)? = nil,
        connectorAvailability: @escaping @Sendable () async -> Bool = { false },
        naming: (any PlaylistNaming)? = nil,
        narrating: (any InsightNarrating)? = nil,
        connectorDeadlineSeconds: Double = Self.defaultConnectorDeadlineSeconds
    ) {
        self.fallbackParser = fallbackParser
        self.modelParser = modelParser
        self.connectorParser = connectorParser
        self.connectorAvailability = connectorAvailability
        self.naming = naming
        self.narrating = narrating
        self.connectorDeadlineSeconds = connectorDeadlineSeconds
    }
}

/// The write and read seams `apply` routes through, bundled for the same reason as
/// ``AssistantBackendStack``.
public struct AssistantRepositoryStack: Sendable {
    public var playlists: any PlaylistRepositoryProviding
    /// Used for its READ-ONLY `previewTrackIds(matching:profileId:)` only. `evaluate`
    /// materialises, so a proposal-generation path must never call it.
    public var smartPlaylists: any SmartPlaylistRepositoryProviding
    public var mixGenerator: any MixGenerating
    /// `nil` composes a view model that can propose tag fixes but not apply them.
    public var metadataWriter: (any MetadataWriting)?
    /// Suppresses the FSEvents change a tag write triggers, so the folder watcher
    /// does not re-scan a file MacAMP just wrote itself.
    public var selfWriteRegistry: MetadataSelfWriteRegistry?

    public init(
        playlists: any PlaylistRepositoryProviding,
        smartPlaylists: any SmartPlaylistRepositoryProviding,
        mixGenerator: any MixGenerating,
        metadataWriter: (any MetadataWriting)? = nil,
        selfWriteRegistry: MetadataSelfWriteRegistry? = nil
    ) {
        self.playlists = playlists
        self.smartPlaylists = smartPlaylists
        self.mixGenerator = mixGenerator
        self.metadataWriter = metadataWriter
        self.selfWriteRegistry = selfWriteRegistry
    }
}

// MARK: - View model

/// Turns listener requests into reviewable proposals, and applies the ones they accept.
@MainActor
@Observable
public final class AssistantViewModel {
    /// The tier-3 spec used when no parser produced anything.
    ///
    /// `nonisolated` because a `static let` on a `@MainActor` type is otherwise
    /// main-actor-isolated and unusable from a nonisolated default argument.
    /// Its shape mirrors `HeuristicQueryParser`'s own deterministic default, so the
    /// two tiers degrade to the same request.
    public nonisolated static let deterministicDefault = PlaylistQuerySpec(
        recency: .recentlyPlayed,
        lowConfidence: true
    )

    /// Whether a request is in flight. A second ``submit(text:profileId:locale:)``
    /// while one is running is REJECTED, not queued — the same choice
    /// `FMAssistantBackend` makes for its own busy latch, and correct for a typing
    /// listener whose second thought supersedes the first. It is not an error and
    /// does not set ``lastError``.
    public private(set) var isBusy = false

    /// The availability reading taken at the last ``submit(text:profileId:locale:)``.
    public private(set) var availability: AssistantAvailability = .available

    /// Why the last request produced no proposal, or `nil` when it did.
    public private(set) var lastError: AssistantProposalError?

    /// Which ladder tier failed on the last request, or `nil` when none did.
    ///
    /// Orthogonal to ``lastError`` — a request can produce a perfectly good proposal
    /// AND leave this set, which is precisely the case worth telling the listener
    /// about. See ``AssistantTierDiagnostic``.
    public private(set) var lastTierDiagnostic: AssistantTierDiagnostic?

    /// Why the last CONTEXTUAL action produced no proposal without failing, or
    /// `nil` when it produced one.
    ///
    /// Orthogonal to ``lastError``, which reports a failure. Every method in
    /// `AssistantViewModel+Contextual.swift` clears it on entry and sets it on
    /// each of its `nil` returns, so a caller can tell "too long", "not analysed
    /// enough" and "already in order" apart instead of reporting one vague
    /// sentence for all three.
    public private(set) var lastUnavailability: AIProposalUnavailability?

    /// The pending proposals. Never persisted — see ``ProposalStore``.
    @ObservationIgnored public let proposals: ProposalStore

    /// Fired with `(proposalId, playlistId)` once a `.createPlaylist` proposal has
    /// been applied SUCCESSFULLY — create, membership `reorder` and the store
    /// removal all done. Never fired on a throwing path: a failed `reorder` deletes
    /// the playlist it just made and keeps the proposal, and a retry may mint a
    /// DIFFERENT playlist id, so anything this seam feeds must treat the newest
    /// call as authoritative.
    ///
    /// `@ObservationIgnored` because a callback is plumbing, not state a view
    /// should re-render on. `public var` because the invocation site sits in a
    /// public extension and the macOS composition root assigns it (todo 9); `nil`
    /// by default, so every existing caller is unaffected.
    @ObservationIgnored public var onPlaylistCreatedFromProposal: ((UUID, Int64) -> Void)?

    /// Fired with the proposal id when a proposal is dropped WITHOUT being applied
    /// — the ``discard(_:)`` path, and only when a proposal was actually removed,
    /// so a second discard of the same handle is silent.
    ///
    /// Same `@ObservationIgnored public var` rationale as
    /// ``onPlaylistCreatedFromProposal``; assigned by the macOS composition root in
    /// todo 9 to evict anything held against the discarded proposal.
    @ObservationIgnored public var onProposalDiscarded: ((UUID) -> Void)?

    @ObservationIgnored let backends: AssistantBackendStack
    @ObservationIgnored let repositories: AssistantRepositoryStack
    @ObservationIgnored let availabilityProbe: @Sendable () -> AssistantAvailability
    @ObservationIgnored let now: @Sendable () -> Date

    public init(
        proposals: ProposalStore,
        backends: AssistantBackendStack,
        repositories: AssistantRepositoryStack,
        availabilityProbe: @escaping @Sendable () -> AssistantAvailability = { .available },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.proposals = proposals
        self.backends = backends
        self.repositories = repositories
        self.availabilityProbe = availabilityProbe
        self.now = now
    }

    /// Parses `text`, selects tracks for it and files a proposal. Writes nothing.
    ///
    /// - Returns: The filed proposal, or `nil` when the assistant is switched off,
    ///   a request is already in flight, the text was blank, or nothing matched.
    ///   Never throws: every failure is reported through ``lastError``.
    @discardableResult
    public func submit(
        text: String,
        profileId: Int64,
        locale: Locale = .current
    ) async -> AIProposal? {
        guard !isBusy else { return nil }
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return nil }
        setTierDiagnostic(nil)
        let reading = availabilityProbe()
        setAvailability(reading)
        if case .unavailable(reason: .intelligenceDisabled) = reading {
            setLastError(.assistantUnavailable(reason: .intelligenceDisabled))
            return nil
        }
        isBusy = true
        setLastError(nil)
        defer { isBusy = false }
        return await proposal(for: request, profileId: profileId, locale: locale, reading: reading)
    }

    func setLastError(_ error: AssistantProposalError?) {
        guard lastError != error else { return }
        lastError = error
    }

    /// Records — or, with `nil`, clears — which tier fell through.
    ///
    /// Guarded against a same-value write for the reason every `@Observable` setter
    /// in this repo is: Observation notifies on assignment, not on change (SKILL
    /// macOS UI perf rule 3).
    func setTierDiagnostic(_ diagnostic: AssistantTierDiagnostic?) {
        guard lastTierDiagnostic != diagnostic else { return }
        lastTierDiagnostic = diagnostic
    }

    /// Records — or, with `nil`, clears — why a contextual action filed nothing.
    ///
    /// Same file-scoped-setter seam as ``setBusy(_:)``, for the same reason: the
    /// contextual proposers live in a sibling file and `private(set)` scopes the
    /// setter to this one.
    func setUnavailability(_ reason: AIProposalUnavailability?) {
        guard lastUnavailability != reason else { return }
        lastUnavailability = reason
    }

    /// Raises or clears the busy latch.
    ///
    /// ``isBusy`` is `private(set)`, which in Swift scopes the SETTER to this FILE —
    /// so the contextual-proposal methods in `AssistantViewModel+Contextual.swift`
    /// cannot take the latch without this seam. They must: a menu-driven proposal
    /// and a typed request share one preview sheet, and two in-flight generations
    /// would race to fill it.
    func setBusy(_ value: Bool) {
        guard isBusy != value else { return }
        isBusy = value
    }

    private func setAvailability(_ reading: AssistantAvailability) {
        guard availability != reading else { return }
        availability = reading
    }
}
