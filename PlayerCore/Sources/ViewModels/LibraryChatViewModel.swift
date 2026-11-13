// LibraryChatViewModel — the multi-turn conversation the assistant surface renders.
//
// A NEW, PARALLEL surface. `AssistantViewModel.submit` and its four-tier ladder are
// untouched: a shell whose chat tier is unavailable keeps using the ladder, and a
// shell that has one keeps the ladder for its non-chat paths (Organize actions,
// Library Health). Nothing here can produce a proposal on its own — `propose_playlist`
// FILES through W1's ``ToolboxProposalFiling`` seam, which the composition root
// conforms over the same ``ProposalStore`` the preview sheet reads.
//
// ── THE BUSY LATCH REJECTS; IT DOES NOT QUEUE ─────────────────────────────────
//
// Identical in shape and rationale to ``FMAssistantBackend``'s and to
// ``LibraryChatSession``'s: there is NO suspension point between reading
// ``isResponding`` and setting it, so main-actor isolation makes the check
// race-free by construction rather than by a lock. A second send while one is in
// flight is DROPPED, not enqueued — a queued message would be answered against a
// transcript the listener has since reset, and the surface has no way to show a
// pending message honestly.
//
// ── RESET IS "DISCARD THE ENGINE", NOT "CLEAR A LIST" ─────────────────────────
//
// The tier owns the history (see ``LibraryChatEngine``), so clearing `messages`
// alone would leave the model still holding every previous turn — the listener
// would see an empty pane and get answers that referred to a conversation they can
// no longer read. ``reset()`` therefore drops the engine too, and the next send
// mints a fresh one through the factory.
//
// ── ONE LISTENER MESSAGE CAN PRODUCE TWO ASSISTANT ROWS ───────────────────────
//
// A tier that is clearly asked for a playlist and answers in prose without calling
// `propose_playlist` leaves the listener with nothing to apply. When the ask is
// recognised (``PlaylistIntentDetector``), the turn filed no proposal, and the tier
// opted in (``LibraryChatEngine/supportsCorrectiveFollowUp``), the turn sends ONE
// fixed directive back through the same engine and appends its answer as a SECOND
// assistant row. No listener row is appended for it — it is a system instruction the
// listener never wrote — and it happens at most once per message.
//
// ── GENERATION GUARD ──────────────────────────────────────────────────────────
//
// A reset (or a profile switch) can land while a turn is in flight. Every append is
// guarded by the generation the turn started in, so a late answer to a discarded
// conversation is dropped rather than appearing under the new one.
//
// ── ENRICHMENT REWRITES A LANDED ROW, BY ID ───────────────────────────────────
//
// A miss the library could not answer is worth a link, and resolving one is a network
// round trip this module may neither make nor wait for. So a turn lands FIRST with its
// suggestions exactly as the tier reported them, and an optional ``suggestionEnricher``
// is given the chance to fill in their video links afterwards. ``LibraryChatMessage``
// is a value type of `let`s, so "filling in" is a REBUILD: the row is found by its
// `id`, rebuilt carrying that same `id`, and written back at its own index. The
// transcript's `count` and every `id` in it are therefore invariant across enrichment,
// which is what stops SwiftUI re-animating a list the listener is reading.
//
// The enrichment task captures the same generation a turn does and is tracked beside
// `inFlight`, so ``reset()`` and ``cancelInFlight()`` cancel it and a late answer to a
// discarded conversation writes nothing. See `LibraryChatViewModel+Enrichment.swift`
// for what an enricher is and is not allowed to contribute.
//
// This file imports only Foundation, Observation and Services; it MUST NOT import
// AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Observation
import Services

/// One conversation with the listener's own library.
@MainActor
@Observable
public final class LibraryChatViewModel {
    /// Longest listener message carried into a turn.
    ///
    /// 600 is BOTH tiers' own bound restated at the surface, not a third policy:
    /// `LibraryChatSession.maxRequestLength` and
    /// `ConnectorPayloadBudget.maxRequestCharacters` are both 600, and neither is
    /// reachable from this module (one is `@available(macOS 26)`, the other lives in
    /// `AIConnectorBridge`). `LibraryChatRequestBudgetTests` in the macOS shell — which
    /// CAN see the bridge — asserts the two agree, so a budget change goes red instead
    /// of silently letting a longer message through.
    ///
    /// Truncated rather than refused: a clipped request still gets an answer.
    public static let maxRequestLength = 600

    /// The one directive sent when a playlist ask is answered in prose alone.
    ///
    /// MODEL-FACING ENGLISH, never localized and never rendered: it is an instruction
    /// to the tier, in the same register as ``LibraryChatInstructions``, and it is not
    /// appended to the transcript. Localizing it would translate a system prompt into
    /// a language the tool names it references are not written in.
    public static let correctiveDirective = """
    Use propose_playlist now to offer the playlist the listener just asked for. \
    Do not answer in prose.
    """

    /// The conversation so far, oldest first.
    public private(set) var messages: [LibraryChatMessage] = []

    /// Whether a turn is in flight. Drives the surface's busy state AND the latch.
    public private(set) var isResponding = false

    /// Mints a fresh conversation, or explains why it cannot.
    ///
    /// A `Result` rather than an optional, mirroring ``LibraryChatSession/make`` — the
    /// refusal has to reach the transcript as a sentence, and an optional would strand
    /// the reason in the shell that already decided not to offer the surface.
    private let makeEngine: @MainActor () -> Result<LibraryChatEngine, LibraryChatFailure>

    /// Proposals filed since the last drain, in filing order. See
    /// ``LibraryChatMessage/proposalIds``.
    private let drainFiledProposals: @MainActor () -> [UUID]

    /// Playlists `get_playlist` served since the last drain, in call order.
    ///
    /// A SECOND drain rather than a field on the first: the two recorders watch
    /// different seams (``ToolboxProposalFiling`` and ``ToolboxPlaylistReadObserving``)
    /// and a turn can trip either, neither, or both. Both are drained at exactly the
    /// same points so neither can leak an id into the turn after it — see
    /// ``LibraryChatMessage/appendTarget``.
    ///
    /// Defaulted to none, which is what every non-composed test wants.
    private let drainPlaylistReads: @MainActor () -> [(playlistId: Int64, profileId: Int64)]

    /// Resolves video links for the suggestions on a row that has already landed.
    ///
    /// A CLOSURE rather than a protocol, for the reason ``LibraryChatEngine`` is one:
    /// the resolver lives above this module, and `PlayerCore/Sources/ViewModels` is a
    /// scanned network-boundary target, so the transport that answers may not even be
    /// nameable here. `nil` by default — with no enricher nothing is scheduled and a
    /// transcript is exactly what the tier reported.
    ///
    /// Internal rather than `private`: the mechanics live in a sibling file.
    let suggestionEnricher: (@Sendable ([AssistantChatSuggestion]) async -> [AssistantChatSuggestion])?

    /// Enrichment tasks in flight, keyed by the row each one will rebuild.
    ///
    /// `@ObservationIgnored` because this is bookkeeping, not transcript state: a view
    /// that redrew when one was filed would redraw again for the write it eventually
    /// makes. Internal for the sibling file, and read by its tests as the fence that
    /// an enrichment has landed.
    @ObservationIgnored var enrichments: [UUID: Task<Void, Never>] = [:]

    /// Announces that ``reset()`` has finished, so state kept OUTSIDE this view model
    /// on behalf of the conversation can be discarded with it.
    ///
    /// The seam lives here rather than on the caller because the only caller is a
    /// SwiftUI view ("New Conversation"), which is not the composition root and holds
    /// nothing to clean up. The macOS shell uses it to drop the chat-initiated download
    /// registrations: those name proposals from a transcript that no longer exists, so
    /// leaving them would park appends nothing can ever resolve.
    ///
    /// `nil` by default, `@ObservationIgnored` because it is wiring rather than
    /// transcript state, and invoked LAST — after every field is already cleared — so a
    /// handler that reads this view model sees the post-reset state.
    @ObservationIgnored public var onReset: (() -> Void)?

    private var engine: LibraryChatEngine?
    /// Internal, not `private`, because the enrichment task in the sibling file has to
    /// re-read it before it writes. See the generation-guard note in the file header.
    var generation = 0
    private var hasPrewarmed = false
    private var inFlight: Task<Void, Never>?

    /// - Parameters:
    ///   - makeEngine: Builds the tier that answers. Called lazily — on the first
    ///     keystroke via ``prewarm()`` or on the first send — so opening the pane
    ///     costs nothing.
    ///   - drainFiledProposals: Returns and clears the proposal ids filed since the
    ///     previous call. Defaults to none, which is what every non-composed test
    ///     wants.
    ///   - drainPlaylistReads: Returns and clears the playlists read since the
    ///     previous call. Defaults to none, so every construction that predates the
    ///     seam compiles and behaves unchanged.
    ///   - suggestionEnricher: Resolves video links for a landed row's suggestions.
    ///     Defaults to none, which leaves every transcript byte-for-byte as it landed.
    public init(
        makeEngine: @escaping @MainActor () -> Result<LibraryChatEngine, LibraryChatFailure>,
        drainFiledProposals: @escaping @MainActor () -> [UUID] = { [] },
        drainPlaylistReads: @escaping @MainActor () -> [(playlistId: Int64, profileId: Int64)] = { [] },
        suggestionEnricher: (@Sendable ([AssistantChatSuggestion]) async -> [AssistantChatSuggestion])? = nil
    ) {
        self.makeEngine = makeEngine
        self.drainFiledProposals = drainFiledProposals
        self.drainPlaylistReads = drainPlaylistReads
        self.suggestionEnricher = suggestionEnricher
    }

    /// Whether the conversation has not started.
    public var isEmpty: Bool {
        messages.isEmpty
    }

    /// Sends one message and appends both rows it produces.
    ///
    /// Never throws: every outcome is a row. Awaitable so a test can drive a whole
    /// turn, and internally a cancellable `Task` so ``cancelInFlight()`` can stop one.
    public func send(_ text: String) async {
        let request = Self.clamped(text)
        // No `await` between this read and the write below — that is what makes the
        // latch race-free without a lock. Do not introduce one.
        guard !request.isEmpty, !isResponding else { return }
        isResponding = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await perform(request)
        }
        inFlight = task
        await task.value
        inFlight = nil
        isResponding = false
    }

    /// Warms the tier because the listener started typing.
    ///
    /// Once per conversation: the prefix stays warm, and re-warming on every keystroke
    /// would spawn a task per character. ``reset()`` re-arms it.
    public func prewarm() {
        guard !hasPrewarmed, case let .success(engine) = resolvedEngine() else { return }
        hasPrewarmed = true
        Task { await engine.prewarm() }
    }

    /// Starts a new conversation: clears the transcript AND discards the tier's
    /// history. See the file header.
    public func reset() {
        generation &+= 1
        inFlight?.cancel()
        inFlight = nil
        cancelEnrichments()
        messages.removeAll()
        engine = nil
        hasPrewarmed = false
        isResponding = false
        _ = drainFiledProposals()
        _ = drainPlaylistReads()
        onReset?()
    }

    /// Stops a turn without clearing the transcript.
    ///
    /// Called by the composition root when the graph is rebuilt — a profile switch or
    /// a provider change — beside `ConnectorSession.cancel()`, so the outgoing
    /// conversation performs no further tier work.
    public func cancelInFlight() {
        inFlight?.cancel()
        cancelEnrichments()
    }

    /// Replaces the row carrying `id`, keeping both its position and its identity.
    ///
    /// The ONE writer the enrichment path has. `messages` is `public private(set)` and
    /// Swift scopes a `private(set)` SETTER to the declaring FILE, so this stays here
    /// rather than the setter being widened to the whole module: one named mutation is
    /// a far smaller surface than an openly writable transcript. A row that is gone —
    /// the conversation was reset, or its append never happened — is a no-op.
    func replaceMessage(id: UUID, with message: LibraryChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index] = message
    }
}

// MARK: - Turn execution

private extension LibraryChatViewModel {
    /// One turn, start to finish. Every append is generation-guarded.
    func perform(_ request: String) async {
        let turnGeneration = generation
        append(.listener(request), generation: turnGeneration)
        let resolved = resolvedEngine()
        guard case let .success(engine) = resolved else {
            if case let .failure(failure) = resolved {
                append(.assistant(failure: failure), generation: turnGeneration)
            }
            return
        }
        // Drop anything a previous turn left unclaimed, so an id can never be
        // attributed to the wrong message. BOTH recorders, for the same reason.
        _ = drainFiledProposals()
        _ = drainPlaylistReads()
        do {
            let reply = try await engine.send(request)
            let filed = drainFiledProposals()
            let captured = ChatAppendTargetCapture(proposals: filed, reads: drainPlaylistReads())
            // Constructed into a local before it is appended so the row's minted id is
            // capturable: the corrective turn below may have to back-fill THIS row.
            let landed = LibraryChatMessage.assistant(
                reply,
                proposalIds: filed,
                appendTarget: captured.target,
                appendProfileId: captured.profileId
            )
            append(landed, generation: turnGeneration)
            guard filed.isEmpty, engine.supportsCorrectiveFollowUp,
                  PlaylistIntentDetector.matches(request) else { return }
            await correct(through: engine, generation: turnGeneration, backFilling: landed.id)
        } catch is CancellationError {
            // A cancelled turn is not a failure to report: the listener switched
            // profile, changed provider or reset. Say nothing.
            _ = drainFiledProposals()
            _ = drainPlaylistReads()
        } catch {
            _ = drainFiledProposals()
            _ = drainPlaylistReads()
            append(.assistant(failure: Self.failure(for: error)), generation: turnGeneration)
        }
    }

    /// The one corrective directive, as its own assistant row.
    ///
    /// Sent through the SAME engine and from inside ``perform(_:)``, never by
    /// re-entering ``send(_:)`` — the busy latch is still held by the turn that got
    /// here, so a re-entrant call would be DROPPED and the nudge would silently never
    /// happen. It is at most once per listener message because nothing here can reach
    /// this function again.
    ///
    /// A failure is SILENT, cancellation included: the listener already has a real
    /// answer above this row, and a failure banner would report a message they never
    /// sent.
    ///
    /// - Parameter identifier: The row the answer above this one landed as. A proposal
    ///   this turn files is back-filled onto it — see
    ///   ``backFillAppendTarget(_:ontoRowWith:generation:)``.
    func correct(
        through engine: LibraryChatEngine,
        generation turnGeneration: Int,
        backFilling identifier: UUID
    ) async {
        do {
            let reply = try await engine.send(Self.correctiveDirective)
            let filed = drainFiledProposals()
            let captured = ChatAppendTargetCapture(proposals: filed, reads: drainPlaylistReads())
            append(
                .assistant(
                    reply,
                    proposalIds: filed,
                    appendTarget: captured.target,
                    appendProfileId: captured.profileId
                ),
                generation: turnGeneration
            )
            backFillAppendTarget(captured, ontoRowWith: identifier, generation: turnGeneration)
        } catch {
            _ = drainFiledProposals()
            _ = drainPlaylistReads()
        }
    }

    /// Appends `message` unless the conversation it belonged to is gone, then offers
    /// it to the enricher.
    ///
    /// Enrichment is offered HERE rather than at the two assistant call sites so the
    /// corrective follow-up row gets the same treatment the answer above it did. A row
    /// with no suggestions — every listener row, every failure — costs one early
    /// return.
    func append(_ message: LibraryChatMessage, generation turnGeneration: Int) {
        guard turnGeneration == generation else { return }
        messages.append(message)
        scheduleEnrichment(of: message, generation: turnGeneration)
    }

    /// The engine for this conversation, built once and cached.
    ///
    /// Only a SUCCESS is cached: an unavailable reading is a live condition (the model
    /// finishes preparing, a key is entered) and caching the refusal would freeze the
    /// surface off until the pane is left and re-entered.
    func resolvedEngine() -> Result<LibraryChatEngine, LibraryChatFailure> {
        if let engine { return .success(engine) }
        let made = makeEngine()
        if case let .success(built) = made { engine = built }
        return made
    }

    /// The listener's message, trimmed and clamped. See ``maxRequestLength``.
    static func clamped(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxRequestLength))
    }

    /// Both typed tiers narrow onto two cases; everything else is `.answerFailed`.
    ///
    /// A tier that already speaks this vocabulary is TRUSTED and passed through
    /// whole — that is how a provider-side reason (a throttle with its duration, an
    /// expired sign-in) reaches the transcript from a shell that knows what
    /// `ConnectorFailure` is, without this module ever learning that type exists.
    static func failure(for error: any Error) -> LibraryChatFailure {
        if let chat = error as? LibraryChatFailure {
            return chat
        }
        if let unavailable = error as? AssistantChatUnavailable {
            return .unavailable(unavailable.reason)
        }
        if let assistant = error as? AssistantFailure, assistant == .modelUnavailable {
            return .unavailable(.modelNotReady)
        }
        return .answerFailed
    }
}
