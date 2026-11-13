// AppEnvironment+ChatDownloads+Resolve — looking a song up at the moment it is asked
// for, and telling every suggestion row where its own download got to.
//
// Two halves of one wiring, and they are here together because neither works alone: a
// candidate row cannot be downloaded until it has a video id, and it cannot SAY anything
// until the id it was looked up under is joined to the id the queue knows it by.
//
// ── RESOLVE AT DOWNLOAD TIME, ONCE PER BATCH ─────────────────────────────────
//
// A suggestion the model returned without a verified link is a real song with no id yet.
// Resolving every one at render time would spend the lookup provider's daily cap on rows
// nobody asked for, so nothing is looked up until Download is pressed — and then the
// WHOLE picked batch goes in ONE `resolve(_:)` call, because the resolver's deadline is
// per batch and its fan-out is already bounded.
//
// ── EXACTLY ONE RE-ENTRY, NEVER ONE PER SONG ─────────────────────────────────
//
// The resolved ids re-enter ``AppEnvironment/handleChatDownloadRequest(_:)`` as a single
// request. That is load-bearing rather than tidy: that function emits at most one
// `.notRegisteredNoPlaylist` and one `.queueFull(count:)` per call, so N re-entries would
// say the same sentence N times for what the listener performed as one action.
//
// ── THE SESSION BUDGET IS THE ONLY RATE LIMIT THERE IS ───────────────────────
//
// ``AppEnvironment/makeYouTubeLinkResolver()`` builds a FRESH value per call, so no cap
// state survives between presses. ``AppEnvironment/maxChatResolutionsPerSession`` is
// therefore counted here, on the composition root, and a candidate past it is answered
// `.notFound` WITHOUT a round-trip — the one case where that status means "we did not
// look" rather than "we looked and found nothing", which is the same fact to a listener
// and is documented on ``ChatDownloadRowStatus/notFound``.
//
// ── THE STATUS FEEDS, AND THE ONE ORDERING THEY DEPEND ON ────────────────────
//
// ``AppEnvironment/connectChatDownloadQueueSeams(_:)`` lives here rather than beside the
// rest of the composition because what it now installs is mostly this projection's
// input. Its one hard rule: the status `apply` reads ``DownloadItemVideoIDMap`` BEFORE
// the terminal handler's unit is enqueued, because that handler PRUNES the correlation
// once it has resolved the id — and a terminal `.finished` routinely arrives after the
// row has already left the snapshot, so the map is the only thing that can still name it.
//
// This file constructs no `Process` and no `URLSession`; the network is reached only
// through the injected ``AppEnvironment/resolveChatCandidates`` seam.
import AIConnectorKit
import Foundation
import Persistence
import Services

// MARK: - Download-time resolution

extension AppEnvironment {
    /// How many candidates one app session may look up, in total.
    ///
    /// A lookup is up to two round-trips against a provider with a daily cap that the
    /// listener never agreed to spend, and a chat transcript can accumulate hundreds of
    /// unverified rows. The budget is per SESSION rather than per batch so that pressing
    /// Download on thirty rows six times cannot quietly become three hundred requests.
    static let maxChatResolutionsPerSession = 50

    /// Looks the picked candidates up, then re-enters the download action ONCE with
    /// whatever they resolved to.
    ///
    /// Returns immediately: the lookup runs on ``chatResolutionWork``, and the rows it
    /// is about are already saying ``ChatDownloadRowStatus/resolving`` by then.
    func resolveAndEnqueue(
        _ candidates: [ChatDownloadCandidate],
        appendTarget: SuggestionAppendTarget?,
        appendProfileId: Int64?
    ) {
        guard !candidates.isEmpty else { return }
        let split = Self.chatResolutionSplit(candidates, alreadySpent: chatResolutionCount)
        for candidate in split.refused {
            chatDownloadStatus.markNotFound(candidateKey: candidate.key)
        }
        guard !split.accepted.isEmpty else { return }
        chatResolutionCount += split.accepted.count
        for candidate in split.accepted {
            chatDownloadStatus.markResolving(candidateKey: candidate.key)
        }

        let accepted = split.accepted
        let resolve = resolveChatCandidates
        let previous = chatResolutionWork
        chatResolutionWork = Task { @MainActor [weak self] in
            await previous?.value
            let resolved = await resolve(accepted.map(Self.lookupRequest))
            self?.applyChatResolution(
                accepted,
                resolved: resolved,
                appendTarget: appendTarget,
                appendProfileId: appendProfileId
            )
        }
    }

    /// Waits for every queued lookup AND everything the re-entry they made enqueued.
    ///
    /// A TEST SEAM, in the shape ``drainChatDownloadWork()`` already established. One
    /// await of the tail covers a second press too: that press's task begins by awaiting
    /// the first, so the tail transitively holds the whole chain.
    func drainChatResolution() async {
        await chatResolutionWork?.value
        await drainChatDownloadWork()
    }

    /// Splits a batch against the remaining session budget, in list order.
    ///
    /// Pure and static so the budget is assertable without a resolver, a network or a
    /// composition root — the refused half is the only outcome that reaches a listener
    /// without anything having happened.
    static func chatResolutionSplit(
        _ candidates: [ChatDownloadCandidate],
        alreadySpent: Int
    ) -> (accepted: [ChatDownloadCandidate], refused: [ChatDownloadCandidate]) {
        let remaining = max(0, maxChatResolutionsPerSession - alreadySpent)
        return (Array(candidates.prefix(remaining)), Array(candidates.dropFirst(remaining)))
    }

    static func lookupRequest(for candidate: ChatDownloadCandidate) -> YouTubeLinkResolver.Request {
        YouTubeLinkResolver.Request(title: candidate.title, artist: candidate.artist)
    }

    /// The production default behind ``resolveChatCandidates``.
    ///
    /// A fresh resolver per batch, which is also what makes the session budget this
    /// file's responsibility rather than the resolver's.
    static func liveChatCandidateResolution(
        _ requests: [YouTubeLinkResolver.Request]
    ) async -> [YouTubeLinkResolver.ResolvedVideo?] {
        await makeYouTubeLinkResolver().resolve(requests)
    }
}

private extension AppEnvironment {
    /// Joins what resolved, reports what did not, and re-enters with the ids.
    ///
    /// A slot count that does not match the batch is treated as a total failure rather
    /// than paired positionally as far as it goes: the resolver's contract is one slot
    /// per request IN ORDER, so a mismatch means the answer cannot be trusted to name
    /// the right songs — and a candidate left out of a truncated `zip` would sit at
    /// ``ChatDownloadRowStatus/resolving`` forever.
    func applyChatResolution(
        _ candidates: [ChatDownloadCandidate],
        resolved: [YouTubeLinkResolver.ResolvedVideo?],
        appendTarget: SuggestionAppendTarget?,
        appendProfileId: Int64?
    ) {
        guard resolved.count == candidates.count else {
            for candidate in candidates {
                chatDownloadStatus.markNotFound(candidateKey: candidate.key)
            }
            return
        }
        var videoIDs: [String] = []
        var seen: Set<String> = []
        for (candidate, video) in zip(candidates, resolved) {
            guard let video else {
                chatDownloadStatus.markNotFound(candidateKey: candidate.key)
                continue
            }
            // The bind carries `.resolving` across to the video id, so every queue event
            // that follows — all of which are addressed by that id — reaches the row the
            // table is still drawing under its candidate key.
            chatDownloadStatus.bind(candidateKey: candidate.key, toVideoID: video.videoId)
            // Two candidates can name the same song; enqueuing it twice would register
            // two targets for one download and append the track to the playlist twice.
            if seen.insert(video.videoId).inserted {
                videoIDs.append(video.videoId)
            }
        }
        guard !videoIDs.isEmpty else { return }
        handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: videoIDs,
            appendTarget: appendTarget,
            appendProfileId: appendProfileId
        ))
    }
}

// MARK: - The status feeds

extension AppEnvironment {
    /// Chains the video-id map and the status projection onto the snapshot seam, and the
    /// status projection and the terminal-state handler onto the progress seam.
    ///
    /// Never REPLACES either seam, so the downloads pane's own projection and the toast
    /// policy keep firing. See this file's header for why the status `apply` has to run
    /// before the terminal handler's unit is enqueued.
    func connectChatDownloadQueueSeams(_ queue: DownloadQueueService) {
        let map = chatDownloadVideoIDMap
        let status = chatDownloadStatus
        let previousSnapshotHandler = queue.onQueueChanged
        queue.onQueueChanged = { snapshot in
            previousSnapshotHandler?(snapshot)
            MainActor.assumeIsolated {
                map.ingest(snapshot)
                status.ingest(snapshot)
            }
        }

        let previousProgressHandler = queue.onItemProgress
        queue.onItemProgress = { [weak self] id, state in
            previousProgressHandler?(id, state)
            MainActor.assumeIsolated {
                guard let self else { return }
                status.apply(itemID: id, state: state, videoID: map.videoID(for:))
                guard let handler = self.chatTerminalHandler else { return }
                let videoID = map.videoID(for: id)
                self.enqueueChatDownloadWork { [weak self] in
                    await self?.announcingChatDownloads(as: videoID) {
                        await handler.handle(itemID: id, state: state)
                    }
                }
            }
        }
    }

    /// The announcement sink both halves of the finish pipeline are handed.
    ///
    /// Fans one event out to two consumers that answer different questions: the
    /// coalescer says one buffered sentence per playlist, the status store writes one
    /// row's own column. The coalescer keeps its private name lookup and is untouched;
    /// this is a second, independent hop rather than a shared cache neither could
    /// invalidate.
    ///
    /// The store's half is `async`, so it rides ``enqueueChatDownloadWork(_:)`` — which
    /// both orders it behind the unit that announced it and keeps events for one row in
    /// the order they happened.
    func chatDownloadAnnouncementSink(
        _ coalescer: ChatDownloadToastCoalescer
    ) -> (ChatDownloadAppendEvent) -> Void {
        { [weak self, weak coalescer] event in
            coalescer?.record(event)
            guard let self else { return }
            let videoID = chatAnnouncingVideoID
            enqueueChatDownloadWork { [weak self] in
                await self?.chatDownloadStatus.apply(event, videoID: videoID)
            }
        }
    }

    /// Runs one unit of chain work with `videoID` installed as the row every
    /// ``ChatDownloadAppendEvent`` it emits belongs to.
    ///
    /// Restores `nil` rather than the previous value because units never nest: the chain
    /// is strictly serial and no unit awaits another, so there is no outer scope to
    /// return to. `nil` is also the honest answer for the one announcing path that has
    /// no video id at all — `flushHeldAppends`, which is addressed by track ids whose
    /// downloads finished long ago, and whose rows correctly keep saying
    /// ``ChatDownloadRowStatus/downloaded``.
    func announcingChatDownloads(as videoID: String?, _ work: () async -> Void) async {
        chatAnnouncingVideoID = videoID
        defer { chatAnnouncingVideoID = nil }
        await work()
    }

    /// Resolves a playlist's display name OFF the main actor.
    ///
    /// `fetchPlaylist(id:)` has no async overload and a synchronous GRDB read never runs
    /// on the main actor. ONE factory so the coalescer and the status store are handed
    /// the same lookup rather than two that could drift.
    static func chatPlaylistNameLookup(_ database: AppDatabase) -> @Sendable (Int64) async -> String? {
        let playlists = PlaylistRepository(database)
        return { playlistId in
            await Task.detached(priority: .utility) {
                try? playlists.fetchPlaylist(id: playlistId)?.name
            }.value ?? nil
        }
    }

    /// Marks the rows a turn just put on screen that download history already knows.
    ///
    /// Advisory only, and deliberately fire-and-forget: ``ChatDownloadStatusStore``
    /// refuses to overwrite a row that is already doing something, which is what makes a
    /// late answer harmless. The batch is bounded by
    /// ``DownloadHistoryRepository/videoIDLookupLimit`` inside the repository, so one
    /// statement answers however many rows a transcript accumulated.
    func primeChatDownloadHistory(videoIDs: [String]) {
        guard !videoIDs.isEmpty else { return }
        let history = DownloadHistoryRepository(database)
        Task { [weak self] in
            guard let known = try? await history.knownVideoIDs(in: videoIDs), !known.isEmpty else { return }
            self?.chatDownloadStatus.markKnown(videoIDs: known)
        }
    }

    /// What the suggestion table is handed: one read of the projection, one prime of it.
    var chatSuggestionHooks: ChatSuggestionHooks {
        ChatSuggestionHooks(
            status: { [weak self] key in self?.chatDownloadStatus.status(for: key) ?? .none },
            onSuggestionsShown: { [weak self] videoIDs in self?.primeChatDownloadHistory(videoIDs: videoIDs) }
        )
    }
}
