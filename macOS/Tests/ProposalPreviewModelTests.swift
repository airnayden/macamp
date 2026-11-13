// ProposalPreviewModelTests — the two things the todo-23 XCUITests could not prove
// on their own, pinned in a target that runs without an automation session.
//
// Both new tests exist because a UITest failure is AMBIGUOUS: "the cell never
// appeared" and "the error text was wrong" each have two possible causes — a broken
// production path, or a broken query. These assert the PRODUCTION half directly, so a
// future UITest failure can be attributed immediately.
//
// The specific bugs they guard:
//
//   * `resolvedTracks` truncates past 100 ids via `Array(Set(ids).prefix(100))`, and
//     `Set` order is nondeterministic — so an unchunked preview of a 150-track draft
//     would silently resolve an ARBITRARY 100 and leave the rest blank.
//   * The failure copy the UITest matches on must be UNIQUE to `playlistNotFound`.
//     The obvious phrase, "nothing was changed", also appears in `failureUnexpected`,
//     so an assertion using it would pass even if the `as? AssistantProposalError`
//     cast had fallen through to the generic message.
import Foundation
import GRDB
@testable import MacAMP
import Persistence
import Services
import Testing
import ViewModels

@MainActor
@Suite("ProposalPreviewModelTests")
struct ProposalPreviewModelTests {
    private static let english = Locale(identifier: "en")

    // MARK: Failure copy

    @Test("a playlistNotFound throw maps to copy that names the playlist, not the generic fallback")
    func playlistNotFoundMapsToItsOwnCopy() {
        let resource = ProposalPreviewModel.message(for: AssistantProposalError.playlistNotFound(id: 42))
        let rendered = resource.resolved(in: Self.english)

        #expect(rendered.contains("exist any more"))
        #expect(rendered != ProposalPreviewStrings.failureUnexpected.resolved(in: Self.english))
    }

    /// The phrase `AssistantFlowTests` matches on has to discriminate. This is the
    /// assertion that makes that a guarantee rather than a hope: if someone reworded
    /// either string so both contained it, the UITest would start passing vacuously
    /// and this test fails first.
    @Test("the phrase the UITest matches on appears in playlistNotFound copy and NOWHERE else")
    func theMatchedPhraseIsUniqueToPlaylistNotFound() {
        let phrase = "exist any more"
        let notFound = ProposalPreviewStrings.failurePlaylistNotFound.resolved(in: Self.english)
        #expect(notFound.contains(phrase))

        let others = [
            ProposalPreviewStrings.failureUnexpected,
            ProposalPreviewStrings.failureBatchNotConfirmed,
            ProposalPreviewStrings.failureUnknownProposal,
            ProposalPreviewStrings.failurePlaylistNotCreated,
            ProposalPreviewStrings.failureWriterUnavailable,
            ProposalPreviewStrings.failureTagWrite,
            ProposalPreviewStrings.failureNoMatchingTracks,
            ProposalPreviewStrings.failureGeneration,
        ]
        for resource in others {
            #expect(!resource.resolved(in: Self.english).contains(phrase))
        }
    }

    @Test("an error that is not an AssistantProposalError falls back to the generic copy")
    func unknownErrorFallsBackToTheGenericCopy() {
        struct Unrelated: Error {}
        let resource = ProposalPreviewModel.message(for: Unrelated())
        #expect(
            resource.resolved(in: Self.english)
                == ProposalPreviewStrings.failureUnexpected.resolved(in: Self.english)
        )
    }

    // MARK: Title resolution

    @Test("a create proposal resolves a display title for every seeded track")
    func createProposalResolvesItsTrackTitles() async throws {
        let database = try makeDatabase(trackCount: 3)
        let model = ProposalPreviewModel()
        await model.load(proposal(forTrackIds: [1, 2, 3]), database: database)

        for index in 1 ... 3 {
            let title = try #require(model.title(for: Int64(index)))
            #expect(title.contains("Fixture \(index)"))
            #expect(title.contains("Fixture Artist"))
        }
        #expect(!model.isTruncated)
    }

    /// The regression guard for the chunking: 150 ids span two ``idsPerBatch`` round
    /// trips, so an implementation that dropped the chunking and handed the whole list
    /// to one `resolvedTracks` call would have to lean on that method's own bound
    /// instead of this type's.
    @Test("a draft larger than one repository batch still resolves every title")
    func draftsLargerThanOneBatchResolveCompletely() async throws {
        let count = 150
        let database = try makeDatabase(trackCount: count)
        let model = ProposalPreviewModel()
        let trackIds = [Int64](1 ... Int64(count))
        await model.load(proposal(forTrackIds: trackIds), database: database)

        let unresolved = trackIds.filter { model.title(for: $0) == nil }
        #expect(unresolved.isEmpty)
    }

    /// The case that distinguishes a 500 ceiling from the 300 that shipped before the
    /// proposal cap was raised: at 300 this draft resolves only its first 300 titles
    /// and reports itself truncated. Five batches of ``idsPerBatch``, none dropped.
    @Test("a 500-track draft resolves all 500 titles and is NOT marked truncated")
    func draftsAtTheCeilingResolveCompletely() async throws {
        let count = 500
        let database = try makeDatabase(trackCount: count)
        let model = ProposalPreviewModel()
        let trackIds = [Int64](1 ... Int64(count))
        await model.load(proposal(forTrackIds: trackIds), database: database)

        #expect(ProposalPreviewModel.maxResolvedIds == count)
        let unresolved = trackIds.filter { model.title(for: $0) == nil }
        #expect(unresolved.isEmpty)
        #expect(!model.isTruncated)
    }

    @Test("a draft past the preview ceiling resolves the ceiling and says so")
    func draftsPastTheCeilingAreMarkedTruncated() async throws {
        let count = ProposalPreviewModel.maxResolvedIds + 20
        let database = try makeDatabase(trackCount: count)
        let model = ProposalPreviewModel()
        await model.load(proposal(forTrackIds: [Int64](1 ... Int64(count))), database: database)

        #expect(model.isTruncated)
        #expect(model.title(for: 1) != nil)
        #expect(model.title(for: Int64(count)) == nil)
    }

    // MARK: Per-track selection

    //
    // The write path is asserted END TO END — through the real `AssistantViewModel`,
    // the real `PlaylistRepository`, and then a read of the created playlist's
    // membership. A test that only checked `model.filtered(_:)` would prove the
    // narrowing works while leaving the actual bug (apply ignoring the selection)
    // completely uncovered.

    @Test("every track is ticked by default, so an untouched sheet applies the whole list")
    func theDefaultSelectionAppliesEveryTrack() async throws {
        let database = try makeDatabase(trackCount: 3)
        let model = ProposalPreviewModel()
        let proposal = proposal(forTrackIds: [1, 2, 3])

        #expect(model.excludedTrackIds.isEmpty)
        #expect(model.includedCount(in: proposal) == 3)
        #expect(model.filtered(proposal) == proposal)

        try await apply(proposal, with: model, in: database)
        #expect(try writtenTrackIds(in: database) == [1, 2, 3])
    }

    @Test("an unticked track is absent from the playlist apply actually writes")
    func untickedTracksAreNotWritten() async throws {
        let database = try makeDatabase(trackCount: 3)
        let model = ProposalPreviewModel()
        let proposal = proposal(forTrackIds: [1, 2, 3])

        model.setIncluded(false, for: 2)

        #expect(!model.isIncluded(2))
        #expect(model.isIncluded(1))
        #expect(model.includedCount(in: proposal) == 2)

        try await apply(proposal, with: model, in: database)
        #expect(try writtenTrackIds(in: database) == [1, 3])
    }

    @Test("unticking every track refuses to apply rather than writing an empty playlist")
    func untickingEverythingWritesNothing() async throws {
        let database = try makeDatabase(trackCount: 3)
        let model = ProposalPreviewModel()
        let proposal = proposal(forTrackIds: [1, 2, 3])

        model.setIncluded(false, for: [1, 2, 3])

        #expect(!ProposalPreviewModel.isActionable(model.filtered(proposal)))

        let assistant = makeAssistant(database)
        assistant.proposals.add(proposal)
        let applied = await model.apply(proposal, using: assistant, confirmedBatch: false)

        #expect(!applied)
        #expect(try playlistCount(in: database) == 0)
        #expect(assistant.proposals.contains(id: proposal.id), "a refused apply must keep the proposal")
    }

    @Test("re-ticking a track puts it back in the write")
    func reTickingRestoresATrack() async throws {
        let database = try makeDatabase(trackCount: 3)
        let model = ProposalPreviewModel()
        let proposal = proposal(forTrackIds: [1, 2, 3])

        model.setIncluded(false, for: [1, 2, 3])
        model.setIncluded(true, for: 2)

        #expect(model.includedCount(in: proposal) == 1)

        try await apply(proposal, with: model, in: database)
        #expect(try writtenTrackIds(in: database) == [2])
    }
}

// MARK: - Fixtures

private extension ProposalPreviewModelTests {
    func proposal(forTrackIds trackIds: [Int64]) -> AIProposal {
        let entries = trackIds.map { MixDraftEntry(trackId: $0, provenance: .rulesResult, score: 1) }
        let draft = PlaylistDraft(
            entries: entries,
            nameHint: MixNameHint(sourceKind: .rulesResult, trackCount: entries.count)
        )
        return AIProposal(
            profileId: ProfileRecord.guestID,
            kind: .createPlaylist(CreatePlaylistRequest(draft: draft, name: "Preview Fixture"))
        )
    }

    /// A real view model over real repositories on an in-memory database.
    ///
    /// The parser tiers are never reached: `apply` routes a `.createPlaylist` straight
    /// to `PlaylistRepositoryProviding`, so the backends only have to exist.
    func makeAssistant(_ database: AppDatabase) -> AssistantViewModel {
        AssistantViewModel(
            proposals: ProposalStore(),
            backends: AssistantBackendStack(fallbackParser: HeuristicQueryParser(knownGenres: { [] })),
            repositories: AssistantRepositoryStack(
                playlists: PlaylistRepository(database),
                smartPlaylists: SmartPlaylistRepository(database),
                mixGenerator: MixGeneratorService(database)
            )
        )
    }

    func apply(_ proposal: AIProposal, with model: ProposalPreviewModel, in database: AppDatabase) async throws {
        let assistant = makeAssistant(database)
        assistant.proposals.add(proposal)
        let applied = await model.apply(proposal, using: assistant, confirmedBatch: false)
        #expect(applied, "the apply should have succeeded")
        #expect(model.failure == nil)
    }

    /// The membership of the one playlist an apply created, in written order.
    func writtenTrackIds(in database: AppDatabase) throws -> [Int64] {
        let repository = PlaylistRepository(database)
        let playlists = try repository.playlistsWithTrackCounts(profileId: ProfileRecord.guestID)
        guard let playlistId = playlists.items.first?.playlist.id else { return [] }
        return try repository.playlistTracksPage(playlistId: playlistId).items.compactMap(\.track.id)
    }

    func playlistCount(in database: AppDatabase) throws -> Int {
        try PlaylistRepository(database)
            .playlistsWithTrackCounts(profileId: ProfileRecord.guestID)
            .items.count
    }

    func makeDatabase(trackCount: Int) throws -> AppDatabase {
        let database = try AppDatabase(DatabaseQueue())
        try database.writer.write { db in
            for index in 1 ... trackCount {
                var record = TrackRecord(
                    filePath: "/fixtures/track-\(index).mp3",
                    title: "Fixture \(index)",
                    sortTitle: "fixture \(index)",
                    artistName: "Fixture Artist",
                    duration: 100,
                    availability: .present
                )
                try record.insert(db)
            }
        }
        return database
    }
}
