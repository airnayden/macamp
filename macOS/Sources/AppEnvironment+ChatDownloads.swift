// AppEnvironment+ChatDownloads — the wiring that turns "download these songs" in the
// assistant into rows in the playlist the turn was about.
//
// Everything new lives here rather than in `AppEnvironment+Downloads.swift`, which
// receives exactly one behavioural edit (the routing parameter) and is otherwise
// untouched. The pieces themselves are all landed and tested in `PlayerCore`; this file
// is the composition, and the composition is where the three hard orderings live.
//
// ── REGISTER BEFORE ENQUEUE ──────────────────────────────────────────────────
//
// `enqueue` is `async` and suspends. A video already in flight can finish DURING that
// suspension, and a finished download claims registrations synchronously — so a
// registration made after the await would arrive at a claim that has already happened:
// the file takes the legacy path and the registration leaks with no terminal state left
// to evict it. Registering first also gets fan-out right, because an id that dedupes
// against an in-flight row still gets its new target.
//
// ── CLAIM INSIDE THE SEAM, NEVER INSIDE THE TASK ─────────────────────────────
//
// `onItemFinished` is synchronous. ``routeChatFinished(_:fileURL:appender:)`` claims
// inside the seam's own `MainActor.assumeIsolated` and returns whether it claimed
// anything; the claim IS the decision. A check-then-claim-in-a-`Task` split would let
// ordinary main-actor work — discarding a proposal, resetting the chat, a policy
// eviction — empty the registry between the two, after suppression had already been
// decided, and the file would be imported by neither path.
//
// ── `.finished` MUST NOT TOUCH THE REGISTRY ──────────────────────────────────
//
// The driver publishes the terminal `onItemProgress(.finished)` BEFORE `onItemFinished`.
// The progress chain therefore routes through `ChatDownloadTerminalStateHandler`, whose
// `.ignore` classification (which `.finished` falls into) returns before touching either
// the registry or the map. Pinned end-to-end by the ordering lock in
// `ChatDownloadWiringTests`.
//
// ── THE SEAMS OUTLIVE THE AI GRAPH, THE AI GRAPH DOES NOT OUTLIVE THEM ───────
//
// `makeAI` mints a fresh `ProposalStore`, a fresh assistant and a fresh chat on every
// toggle flip, provider change and profile switch, and returns `nil` outright while
// Intelligence is off. So installation is re-run on every rebuild
// (``handleAIGraphRebuilt()``), and the registry hygiene that rebuild demands runs
// UNCONDITIONALLY — outside the nil guard, because the ON→OFF flip is exactly the edge
// where there is no new graph to install onto and the old proposals became unclaimable.
//
// This file constructs no `Process` and no `URLSession`; it reaches the network only
// through the queue it was handed.
import Foundation
import Observation
import Persistence
import Services
import ViewModels

// MARK: - Composition

extension AppEnvironment {
    /// Builds the chat-download half of the download graph and returns the routing
    /// closure `wireDownloadSeams` installs.
    ///
    /// Called from `connectDownloads(settings:)` BEFORE `wireDownloadSeams`, because the
    /// route closure captures the appender by value: at that point it certainly exists,
    /// and a route that resolved it lazily could fire against a `nil` it has no way to
    /// report. (The AI-graph seams do the opposite — see ``connectChatDownloadSeams()``.)
    func connectChatDownloads(boxes: DownloadBoxes) -> @MainActor @Sendable (DownloadItem, URL) -> Bool {
        let coalescer = makeChatDownloadCoalescer()
        chatDownloadToasts = coalescer
        let appender = makeChatDownloadAppender(boxes: boxes, coalescer: coalescer)
        chatAppender = appender
        chatTerminalHandler = makeChatDownloadTerminalHandler(appender: appender, coalescer: coalescer)
        return { [weak self] item, fileURL in
            self?.routeChatFinished(item, fileURL: fileURL, appender: appender) ?? false
        }
    }

    // `connectChatDownloadQueueSeams(_:)` lives in `+Resolve.swift`, beside the status
    // projection that is now most of what it installs.
}

// MARK: - The leaves

private extension AppEnvironment {
    func makeChatDownloadCoalescer() -> ChatDownloadToastCoalescer {
        ChatDownloadToastCoalescer(
            emit: { [weak self] toast in self?.toast.show(text: toast.text, icon: toast.icon) },
            playlistName: Self.chatPlaylistNameLookup(database)
        )
    }

    /// The appender, over the SHIPPED scanner, the LIVE auto-import box, and the active
    /// profile's real roots.
    ///
    /// Both database reads hop off the main actor explicitly: `rootsForProfile` and
    /// `fetchTrack(filePath:)` are synchronous GRDB calls, and the appender declares both
    /// seams `async` precisely so the composition root can place that hop.
    func makeChatDownloadAppender(
        boxes: DownloadBoxes,
        coalescer: ChatDownloadToastCoalescer
    ) -> ChatDownloadPlaylistAppender {
        let autoImportBox = boxes.autoImport
        let roots = LibraryRootRepository(database)
        let tracks = TrackRepository(database)
        return ChatDownloadPlaylistAppender(
            registry: suggestionDownloadRegistry,
            scanner: scanner,
            isAutoImportEnabled: { autoImportBox.withLock { $0 } },
            libraryRoots: { profileId in
                await Task.detached(priority: .utility) {
                    let records = try? roots.rootsForProfile(profileId, limit: LibraryRootRepository.fetchLimit)
                    return (records ?? []).map { URL(fileURLWithPath: $0.path) }
                }.value
            },
            activeProfileId: { [weak self] in
                self?.profileService.activeProfile.id ?? ProfileRecord.guestID
            },
            trackLookup: { filePath in
                try await Task.detached(priority: .utility) {
                    try tracks.fetchTrack(filePath: filePath)?.id
                }.value
            },
            playlists: PlaylistRepository(database),
            announce: chatDownloadAnnouncementSink(coalescer)
        )
    }

    func makeChatDownloadTerminalHandler(
        appender: ChatDownloadPlaylistAppender,
        coalescer: ChatDownloadToastCoalescer
    ) -> ChatDownloadTerminalStateHandler {
        let history = DownloadHistoryRepository(database)
        return ChatDownloadTerminalStateHandler(
            registry: suggestionDownloadRegistry,
            map: chatDownloadVideoIDMap,
            appender: appender,
            historyFilePath: { videoID in
                let entry = try? await history.latestEntry(canonicalVideoID: videoID)
                return entry?.filePath
            },
            announce: chatDownloadAnnouncementSink(coalescer)
        )
    }
}

// MARK: - The finished route

extension AppEnvironment {
    /// Claims, and by claiming decides.
    ///
    /// - Returns: `true` when the appender owns this file, which suppresses BOTH the
    ///   legacy import and its toast. `false` leaves today's path byte for byte.
    func routeChatFinished(
        _ item: DownloadItem,
        fileURL: URL,
        appender: ChatDownloadPlaylistAppender
    ) -> Bool {
        let registrations = suggestionDownloadRegistry.claimRegistrations(videoID: item.canonicalVideoID)
        switch ChatDownloadRoutePolicy.route(isRegistered: !registrations.isEmpty) {
        case .legacyImport:
            return false
        case .appender:
            let videoID = item.canonicalVideoID
            enqueueChatDownloadWork { [weak self] in
                await self?.announcingChatDownloads(as: videoID) {
                    await appender.handleFinished(
                        videoID: videoID,
                        fileURL: fileURL,
                        registrations: registrations
                    )
                }
            }
            return true
        }
    }

    /// Queues one unit of chat-download work behind everything already queued.
    func enqueueChatDownloadWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = chatDownloadWork
        chatDownloadWorkSequence += 1
        chatDownloadWork = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Waits until the chain has stopped growing and every unit has finished.
    ///
    /// A TEST SEAM, in the shape `LibraryFolderCoordinator.waitForIdle()` already
    /// established: the seams that feed this chain are synchronous, so there is no task
    /// a suite could await instead. Awaiting the tail is not enough on its own — a unit
    /// can enqueue the next one — hence the sequence comparison.
    ///
    /// It deliberately does NOT wait on the toast coalescer's open window: that window
    /// is a two-second product decision, and a suite asserting on the append itself must
    /// not pay for it. A suite that wants the summary awaits
    /// ``ChatDownloadToastCoalescer/waitForPendingWindow()`` explicitly.
    func drainChatDownloadWork() async {
        var observed = -1
        while chatDownloadWorkSequence != observed {
            observed = chatDownloadWorkSequence
            await chatDownloadWork?.value
        }
    }
}

// MARK: - The download action

/// Whether, and against what, a whole request's videos are registered.
///
/// Computed ONCE per request rather than per video: `ChatDownloadRequest` carries one
/// `appendTarget` for the whole batch, so every id in it resolves identically — which is
/// also what makes ``ChatDownloadAppendEvent/notRegisteredNoPlaylist`` one sentence
/// rather than one per song.
enum ChatDownloadRegistrationPlan: Equatable {
    /// A plain download. Enqueue only, register nothing.
    case none
    /// Register every id in the batch against this target for this profile.
    case register(SuggestionAppendTarget, profileId: Int64)
    /// The proposal is gone and never became a playlist, so there is nothing left to
    /// register against. The downloads still run; the appends do not.
    case unresolved
}

extension AppEnvironment {
    /// The assistant's "Download selected" action.
    ///
    /// Registration runs FIRST, inside the loop, before the `async` enqueue — see this
    /// file's header for the suspension window that closes.
    func handleChatDownloadRequest(_ request: ChatDownloadRequest) {
        guard let queue = downloads else { return }
        let plan = chatRegistrationPlan(for: request)
        var urls: [URL] = []
        var registered: [String] = []
        var capRefused = false
        for videoID in request.videoIDs {
            // An id the normalizer will not build a watch URL for can never be enqueued,
            // so registering it would leak an entry nothing can claim or evict.
            guard let url = YouTubeURLNormalizer.canonicalURL(forVideoID: videoID) else { continue }
            urls.append(url)
            guard case let .register(target, profileId) = plan else { continue }
            if suggestionDownloadRegistry.register(videoID: videoID, target: target, profileId: profileId) {
                registered.append(videoID)
            } else {
                capRefused = true
            }
        }
        // BEFORE the empty-URL guard: a request can be entirely candidates, and that one
        // is exactly the press this whole path exists for.
        resolveAndEnqueue(
            request.unresolved,
            appendTarget: request.appendTarget,
            appendProfileId: request.appendProfileId
        )
        guard !urls.isEmpty else { return }
        if plan == .unresolved { chatDownloadToasts?.record(.notRegisteredNoPlaylist) }
        if capRefused { chatDownloadToasts?.record(.queueFull(count: suggestionDownloadRegistry.count)) }
        enqueueChatDownloadWork { [weak self] in
            await self?.enqueueChatDownloads(urls, on: queue, registered: registered, requested: urls.count)
        }
    }

    /// Where a request's downloads should be appended, and for whom.
    func chatRegistrationPlan(for request: ChatDownloadRequest) -> ChatDownloadRegistrationPlan {
        guard let target = request.appendTarget else { return .none }
        guard let proposalId = target.proposalId else {
            return .register(target, profileId: request.appendProfileId ?? activeChatProfileId)
        }
        if let proposal = intelligence?.proposals.proposal(id: proposalId) {
            return .register(target, profileId: proposal.profileId)
        }
        // The proposal left the store. A recorded resolution means it was APPLIED and
        // the playlist really exists, so the target is swapped for it; no resolution
        // means it was DISCARDED, and a `.pendingProposal` registration left behind
        // would park appends no future apply could ever flush.
        if let playlistId = suggestionDownloadRegistry.resolvedPlaylistId(forProposal: proposalId) {
            return .register(.playlist(playlistId), profileId: activeChatProfileId)
        }
        return .unresolved
    }

    var activeChatProfileId: Int64 {
        profileService.activeProfile.id ?? ProfileRecord.guestID
    }
}

private extension AppEnvironment {
    /// Enqueues the batch and reconciles the registrations against what the queue took.
    ///
    /// `EnqueueOutcome` reports how many rows were added and how many deduped, but NOT
    /// which ids the depth cap refused — a cap-refused row is explicitly not a duplicate.
    /// So the shortfall is computed against `requested`, which is the count of the URLs
    /// ACTUALLY ENQUEUED rather than the size of the whole request: an id the normalizer
    /// refused was never sent to the queue and so cannot be missing from its answer, and
    /// counting it would turn a one-for-one success into a phantom cap refusal. A
    /// positive shortfall evicts everything this batch registered rather than leaving
    /// entries no completion can ever claim. A `pendingPlaylist` outcome is structurally
    /// unreachable here (only canonical `watch?v=` URLs are built above) and fails safe
    /// the same way.
    func enqueueChatDownloads(
        _ urls: [URL],
        on queue: any DownloadQueueing,
        registered: [String],
        requested: Int
    ) async {
        let outcome = await queue.enqueue(urls: urls)
        let shortfall = requested - (outcome.added + outcome.duplicatesDropped)
        guard shortfall > 0 || outcome.pendingPlaylist != nil else { return }
        for videoID in registered {
            suggestionDownloadRegistry.evict(videoID: videoID)
        }
        chatDownloadToasts?.record(.queueFull(count: suggestionDownloadRegistry.count))
    }
}

// MARK: - The AI-graph seams

extension AppEnvironment {
    /// Installs the three seams the chat surface owns. Idempotent, and a no-op while
    /// Intelligence is off — there is no graph to install onto.
    ///
    /// Every closure resolves ``chatAppender`` at INVOCATION time rather than capturing
    /// it: the first `rebuildAI` runs from `connectAI`, which `live(settings:)` calls
    /// BEFORE `connectDownloads`, so at install time the appender does not exist yet.
    func connectChatDownloadSeams() {
        guard let stack = intelligence else { return }
        let registry = suggestionDownloadRegistry
        stack.assistant.onPlaylistCreatedFromProposal = { [weak self] proposalId, playlistId in
            let held = registry.resolveProposal(proposalId, playlistId: playlistId)
            guard !held.isEmpty, let self else { return }
            // The seam fires synchronously on the main actor inside `apply`; the flush
            // is database work and belongs behind the chain, not in that call.
            enqueueChatDownloadWork { [weak self] in
                await self?.chatAppender?.flushHeldAppends(trackIds: held, playlistId: playlistId)
            }
        }
        stack.assistant.onProposalDiscarded = { proposalId in
            registry.evictAll(forProposal: proposalId)
        }
        let status = chatDownloadStatus
        let discarded = discardedProposals
        stack.chat.onReset = {
            registry.removeAll()
            status.removeAll()
            discarded.removeAll()
        }
    }

    /// Re-establishes this feature after the AI graph was replaced.
    ///
    /// The eviction is deliberately OUTSIDE the nil guard in
    /// ``connectChatDownloadSeams()``: on the Intelligence ON→OFF flip `makeAI` answers
    /// `nil`, and that is precisely the edge where the on-screen proposals vanished
    /// without `reset()` ever running. `evictAllPendingProposals()` rather than
    /// `removeAll()` because downloads already bound for a REAL playlist are still in
    /// flight and still correct.
    func handleAIGraphRebuilt() {
        suggestionDownloadRegistry.evictAllPendingProposals()
        connectChatDownloadSeams()
    }
}

// MARK: - The import preview

extension AppEnvironment {
    /// Whether a download started now would actually reach the library — the answer the
    /// suggestion list previews next to its Download button.
    ///
    /// Reads the resident preferences value the view is already observing and
    /// ``LibraryAccessController/roots``, an in-memory `@Observable` projection; the gate
    /// it then calls resolves symlinks on copies of those paths, so this is a handful of
    /// `lstat`s rather than free. That cost is deliberately chosen over `rootsForProfile`
    /// or `GRDBLibraryRootsStore.load()` — this runs inside a SwiftUI `body`, where
    /// either would put a pooled GRDB connection on the main thread per row per redraw.
    func isChatDownloadImportConfigured(downloads preferences: DownloadPreferences) -> Bool {
        ChatDownloadImportGate.isEligible(
            autoImportEnabled: preferences.autoImportEnabled,
            fileURL: DownloadDestinationLocation.resolve(configuredPath: preferences.destinationPath),
            libraryRoots: libraryAccess.roots.map(\.url)
        )
    }
}
