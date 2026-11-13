// ChatDownloadResolveTests — the download-time lookup, and the status a row reads back.
//
// The composition half of the suggestion table: `ChatDownloadStatusStoreTests` proves the
// projection is total, this suite proves the production wiring actually FEEDS it, and
// that an unverified row travels the whole way from a tick to a queued download.
//
// Four properties are worth more than the rest:
//
//   * ONE BATCH, ONE RE-ENTRY — a press resolves in a single `resolve(_:)` call and
//     re-enters `handleChatDownloadRequest` exactly once, however many candidates it
//     carried. That function emits at most one `.notRegisteredNoPlaylist` and one
//     `.queueFull(count:)` per call, so per-candidate re-entry would say the same
//     sentence once per song for what the listener performed as one action.
//   * THE BUDGET COSTS NOTHING TO ENFORCE — a candidate past
//     `maxChatResolutionsPerSession` is `.notFound` with the resolver never called.
//   * BOTH KEYS REACH ONE ROW — after a bind, the status is readable through the
//     candidate key the table still draws AND the video id the queue knows.
//   * THE FEEDS ARE INSTALLED — snapshots, progress samples and append events reach the
//     store through the closures PRODUCTION installed, not through a hand-built graph.
//
// The resolver is replaced by `AppEnvironment.resolveChatCandidates`, so nothing here
// touches the network.
import AIConnectorKit
import Foundation
@testable import MacAMP
import Persistence
import Services
import Testing
import ViewModels

@Suite("Chat download resolution", .serialized)
@MainActor
struct ChatDownloadResolveTests {
    // MARK: - (a) One batch, one re-entry

    @Test("a mixed request resolves its candidates in ONE call and re-enters ONCE")
    func aMixedRequestResolvesInOneBatch() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        let resolver = ChatResolverDouble(harness: harness)
        resolver.answers = [
            ChatResolveFixtures.harrow: ChatDownloadFixtureIDs.first,
            ChatResolveFixtures.marrow: ChatDownloadFixtureIDs.second,
        ]

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: [ChatResolveFixtures.verifiedID],
            unresolved: [ChatResolveFixtures.harrowCandidate, ChatResolveFixtures.marrowCandidate],
            appendTarget: .playlist(12),
            appendProfileId: ProfileRecord.guestID
        ))
        await harness.environment.drainChatResolution()

        #expect(resolver.batches.count == 1)
        #expect(resolver.batches.first?.count == 2)
        // Two enqueues: the verified id went straight out, the two resolved ids followed
        // as ONE re-entry rather than one press each.
        #expect(harness.queueDouble.enqueuedURLs.count == 2)
        #expect(harness.queueDouble.enqueuedURLs.last?.count == 2)
        #expect(harness.registry.count == 3)
    }

    /// Both keys, both directions: the table is still drawing the `"q:"` key while every
    /// queue event that follows is addressed by the video id.
    @Test("a resolved candidate is readable through its candidate key AND its video id")
    func aResolvedCandidateIsReadableThroughBothKeys() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        let resolver = ChatResolverDouble(harness: harness)
        resolver.answers = [ChatResolveFixtures.harrow: ChatDownloadFixtureIDs.first]

        harness.environment.handleChatDownloadRequest(ChatResolveFixtures.candidatesOnlyRequest)
        await harness.environment.drainChatResolution()
        let item = try harness.item(ChatDownloadFixtureIDs.first)
        await harness.publishPending([item])

        #expect(harness.status(ChatResolveFixtures.harrowCandidate.key) == .queued)
        #expect(harness.status(ChatDownloadFixtureIDs.first) == .queued)
    }

    /// Every picked candidate says so before the lookup returns — the table must not sit
    /// blank for the length of a network round-trip.
    @Test("candidates say Resolving before the lookup answers")
    func candidatesAnnounceThemselvesBeforeTheLookupAnswers() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        let resolver = ChatResolverDouble(harness: harness)
        resolver.answers = [ChatResolveFixtures.harrow: ChatDownloadFixtureIDs.first]

        harness.environment.handleChatDownloadRequest(ChatResolveFixtures.candidatesOnlyRequest)

        #expect(harness.status(ChatResolveFixtures.harrowCandidate.key) == .resolving)
        await harness.environment.drainChatResolution()
    }

    // MARK: - (a2) The session budget

    /// The budget is per SESSION, and a candidate past it is refused WITHOUT a lookup —
    /// `makeYouTubeLinkResolver()` mints a fresh value per call, so this counter is the
    /// only rate limit the feature has.
    @Test("a candidate past the session budget is Not found with ZERO resolver calls")
    func aCandidatePastTheBudgetIsRefusedWithoutALookup() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        let resolver = ChatResolverDouble(harness: harness)
        harness.environment.chatResolutionCount = AppEnvironment.maxChatResolutionsPerSession

        harness.environment.handleChatDownloadRequest(ChatResolveFixtures.candidatesOnlyRequest)
        await harness.environment.drainChatResolution()

        #expect(resolver.batches.isEmpty)
        #expect(harness.status(ChatResolveFixtures.harrowCandidate.key) == .notFound)
        #expect(harness.queueDouble.enqueuedURLs.isEmpty)
    }

    /// The split is in list order, so a batch straddling the ceiling spends what is left
    /// on the rows the listener picked FIRST rather than on an arbitrary subset.
    @Test("a batch straddling the ceiling accepts the earlier rows and refuses the rest")
    func aStraddlingBatchSplitsInListOrder() {
        let candidates = (0 ..< 4).map {
            ChatDownloadCandidate(key: "q:\($0)|", title: "Song \($0)", artist: nil)
        }
        let split = AppEnvironment.chatResolutionSplit(
            candidates,
            alreadySpent: AppEnvironment.maxChatResolutionsPerSession - 2
        )

        #expect(split.accepted.map(\.key) == ["q:0|", "q:1|"])
        #expect(split.refused.map(\.key) == ["q:2|", "q:3|"])
    }

    // MARK: - (b) Nothing resolved

    @Test("a candidate that resolves to nothing is Not found, enqueues nothing, registers nothing")
    func anUnresolvableCandidateChangesNothing() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        let resolver = ChatResolverDouble(harness: harness)

        harness.environment.handleChatDownloadRequest(ChatResolveFixtures.candidatesOnlyRequest)
        await harness.environment.drainChatResolution()

        #expect(resolver.batches.count == 1)
        #expect(harness.status(ChatResolveFixtures.harrowCandidate.key) == .notFound)
        #expect(harness.queueDouble.enqueuedURLs.isEmpty)
        #expect(harness.registry.count == 0)
        #expect(harness.activeToastText == nil)
    }

    // MARK: - (c) The queue feeds

    @Test("a snapshot and a progress sample both reach the row")
    func theQueueSeamsFeedTheStore() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        let item = try harness.item(ChatDownloadFixtureIDs.first)

        await harness.publishPending([item])
        #expect(harness.status(ChatDownloadFixtureIDs.first) == .queued)

        await harness.emitProgress(item.id, .downloading(fraction: 0.42, speedBytesPerSec: nil, etaSeconds: nil))
        #expect(harness.status(ChatDownloadFixtureIDs.first) == .downloading(fraction: 0.42))

        await harness.emitProgress(item.id, .postProcessing(fraction: nil))
        #expect(harness.status(ChatDownloadFixtureIDs.first) == .converting)
    }

    /// The retention contract, end to end: a `.finished` routinely arrives once the row
    /// has already left the snapshot, and the status lookup has to run BEFORE the
    /// terminal handler prunes the correlation that is the only thing still naming it.
    @Test("a terminal sample for a row absent from the latest snapshot still lands Downloaded")
    func aTerminalSampleAfterTheRowLeftTheSnapshotStillResolves() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        let item = try harness.item(ChatDownloadFixtureIDs.first)
        await harness.publishPending([item])
        await harness.publishPending([])

        let file = try harness.importedTrack(named: "Gone [\(ChatDownloadFixtureIDs.first)].m4a")
        await harness.emitProgress(item.id, .finished(fileURL: file.url))

        #expect(harness.status(ChatDownloadFixtureIDs.first) == .downloaded)
    }

    // MARK: - (d) The append feed

    @Test("an appended download reads Added to the playlist the coalescer names")
    func anAppendedDownloadNamesItsPlaylist() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        let playlistId = try harness.makePlaylist(named: ChatResolveFixtures.playlistName)
        harness.registry.register(
            videoID: ChatDownloadFixtureIDs.first,
            target: .playlist(playlistId),
            profileId: ProfileRecord.guestID
        )
        let file = try harness.importedTrack(named: "Kept [\(ChatDownloadFixtureIDs.first)].m4a")

        try await harness.finish(harness.item(ChatDownloadFixtureIDs.first), at: file.url)
        await harness.environment.drainChatDownloadWork()

        #expect(harness.status(ChatDownloadFixtureIDs.first)
            == .addedToPlaylist(name: ChatResolveFixtures.playlistName))
    }

    // MARK: - (e) History priming

    @Test("a video download history already knows reads Already downloaded")
    func historyPrimesTheAlreadyDownloadedRow() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        try await harness.recordHistory(videoID: ChatDownloadFixtureIDs.first)

        harness.environment.primeChatDownloadHistory(
            videoIDs: [ChatDownloadFixtureIDs.first, ChatDownloadFixtureIDs.second]
        )
        await harness.waitUntil { harness.status(ChatDownloadFixtureIDs.first) == .alreadyDownloaded }

        #expect(harness.status(ChatDownloadFixtureIDs.first) == .alreadyDownloaded)
        #expect(harness.status(ChatDownloadFixtureIDs.second) == .none)
    }

    /// History is read off the main actor, so its answer can land after the listener has
    /// already pressed Download — it must never overwrite a live row.
    @Test("history priming never overwrites a row that is already working")
    func historyPrimingNeverOverwritesALiveRow() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        try await harness.recordHistory(videoID: ChatDownloadFixtureIDs.first)
        try await harness.publishPending([harness.item(ChatDownloadFixtureIDs.first)])

        harness.environment.primeChatDownloadHistory(videoIDs: [ChatDownloadFixtureIDs.first])
        try await Task.sleep(for: .milliseconds(120))

        #expect(harness.status(ChatDownloadFixtureIDs.first) == .queued)
    }

    // MARK: - (f) Reset

    @Test("resetting the chat forgets every row")
    func resettingTheChatClearsTheStore() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        try await harness.publishPending([harness.item(ChatDownloadFixtureIDs.first)])
        #expect(harness.status(ChatDownloadFixtureIDs.first) == .queued)

        let chat = try #require(harness.environment.intelligence?.chat)
        chat.reset()

        #expect(harness.status(ChatDownloadFixtureIDs.first) == .none)
        #expect(harness.registry.count == 0)
    }

    // MARK: - QA (failure)

    /// The resolver's contract is one slot per request IN ORDER. A short answer cannot be
    /// trusted to name the right songs, and a candidate left out of a truncated pairing
    /// would sit at `.resolving` forever.
    @Test("a resolver answer of the wrong length fails the whole batch rather than pairing it")
    func aMismatchedAnswerFailsTheWholeBatch() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        let resolver = ChatResolverDouble(harness: harness)
        resolver.truncateAnswer = true
        resolver.answers = [
            ChatResolveFixtures.harrow: ChatDownloadFixtureIDs.first,
            ChatResolveFixtures.marrow: ChatDownloadFixtureIDs.second,
        ]

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: [],
            unresolved: [ChatResolveFixtures.harrowCandidate, ChatResolveFixtures.marrowCandidate],
            appendTarget: nil,
            appendProfileId: nil
        ))
        await harness.environment.drainChatResolution()

        #expect(harness.status(ChatResolveFixtures.harrowCandidate.key) == .notFound)
        #expect(harness.status(ChatResolveFixtures.marrowCandidate.key) == .notFound)
        #expect(harness.queueDouble.enqueuedURLs.isEmpty)
    }

    /// Two candidates naming the same song are ONE download: enqueuing the id twice would
    /// register two targets for it and append the track to the playlist twice.
    @Test("two candidates that resolve to the same video enqueue it once")
    func duplicateResolutionsEnqueueOnce() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        let resolver = ChatResolverDouble(harness: harness)
        resolver.answers = [
            ChatResolveFixtures.harrow: ChatDownloadFixtureIDs.first,
            ChatResolveFixtures.marrow: ChatDownloadFixtureIDs.first,
        ]

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: [],
            unresolved: [ChatResolveFixtures.harrowCandidate, ChatResolveFixtures.marrowCandidate],
            appendTarget: .playlist(9),
            appendProfileId: ProfileRecord.guestID
        ))
        await harness.environment.drainChatResolution()

        let expected = try downloadFixtureURL("https://www.youtube.com/watch?v=\(ChatDownloadFixtureIDs.first)")
        #expect(harness.queueDouble.enqueuedURLs == [[expected]])
        #expect(harness.registry.count == 1)
    }

    @Test("a request with no candidates never reaches the resolver")
    func aRequestWithoutCandidatesNeverResolves() async throws {
        let harness = try ChatDownloadWiringHarness()
        defer { harness.cleanUp() }
        let resolver = ChatResolverDouble(harness: harness)

        harness.environment.handleChatDownloadRequest(ChatDownloadRequest(
            videoIDs: [ChatDownloadFixtureIDs.first],
            appendTarget: nil,
            appendProfileId: nil
        ))
        await harness.environment.drainChatResolution()

        #expect(resolver.batches.isEmpty)
        #expect(harness.environment.chatResolutionCount == 0)
    }
}
