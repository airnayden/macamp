import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services
import Testing
@testable import ViewModels

@MainActor
struct PlaylistProposalSafetyTests {
    @Test("A changed membership rejects an old preview without writing", arguments: [
        [Int64(1), 2, 3, 4], [Int64(1), 3], [Int64(3), 2, 1],
    ])
    func stalePreviewPreservesEdits(current: [Int64]) async throws {
        let database = try await library(trackCount: 4)
        let repository = PlaylistRepository(database)
        try await repository.reorder(playlistId: 1, orderedTrackIds: current)
        let viewModel = model(repository)
        let proposal = AIProposal(profileId: ProfileRecord.guestID, kind: .organize(
            playlistId: 1,
            diff: PlaylistOrganizeDiff(currentTrackIds: [1, 2, 3], proposedTrackIds: [2, 3, 1])
        ))
        viewModel.proposals.add(proposal)

        do {
            try await viewModel.apply(proposal)
            Issue.record("A stale preview must be rejected")
        } catch {
            #expect(error as? AssistantProposalError == .playlistChanged(id: 1))
            #expect(viewModel.proposals.contains(id: proposal.id))
        }
        #expect(try await membership(database) == current)
    }

    @Test("A partial preview cannot replace the full playlist")
    func partialPreviewPreservesTail() async throws {
        let database = try await library(trackCount: 3)
        let viewModel = model(PlaylistRepository(database))
        let proposal = AIProposal(profileId: ProfileRecord.guestID, kind: .organize(
            playlistId: 1,
            diff: PlaylistOrganizeDiff(currentTrackIds: [1, 2], proposedTrackIds: [1])
        ))
        viewModel.proposals.add(proposal)
        do {
            try await viewModel.apply(proposal)
            Issue.record("An incomplete preview must be rejected")
        } catch {
            #expect(error as? AssistantProposalError == .playlistChanged(id: 1))
            #expect(viewModel.proposals.contains(id: proposal.id))
        }
        #expect(try await membership(database) == [1, 2, 3])
    }

    @Test("Hygiene proposes cleanup only for a complete membership", arguments: [2000, 2001])
    func boundedCleanupRequiresCompleteMembership(trackCount: Int) async throws {
        let database = try await library(trackCount: trackCount, duplicatePair: true)
        let groups = try await LibraryHygieneService(database).duplicateGroups(
            profileId: ProfileRecord.guestID, limit: 10
        )
        let group = try #require(groups.first)
        if trackCount == 2000 {
            let cleanup = try #require(group.playlistCleanups.first)
            #expect(cleanup.currentTrackIds.count == 2000)
            #expect(cleanup.proposedTrackIds.count == 1999)
            let viewModel = model(PlaylistRepository(database))
            let proposals = viewModel.fileHygieneProposals(for: [.duplicate(group)], profileId: ProfileRecord.guestID)
            try await viewModel.apply(#require(proposals.first))
            #expect(try await membership(database).count == 1999)
        } else {
            #expect(group.playlistCleanups.isEmpty)
            #expect(try await membership(database).count == 2001)
        }
    }

    @Test("A deleted playlist rejects its old preview")
    func deletedPlaylistIsNotRecreated() async throws {
        let database = try await library(trackCount: 3)
        let repository = PlaylistRepository(database)
        let viewModel = model(repository)
        let proposal = AIProposal(profileId: ProfileRecord.guestID, kind: .organize(
            playlistId: 1, diff: PlaylistOrganizeDiff(currentTrackIds: [1, 2, 3], proposedTrackIds: [])
        ))
        viewModel.proposals.add(proposal)
        _ = try await repository.deletePlaylist(id: 1)

        await #expect(throws: AssistantProposalError.playlistNotFound(id: 1)) {
            try await viewModel.apply(proposal)
        }
        #expect(viewModel.proposals.contains(id: proposal.id))
        #expect(try await membership(database).isEmpty)
    }

    @Test("A failed replacement rolls back the whole membership")
    func failedReplacementPreservesMembership() async throws {
        let database = try await library(trackCount: 3)
        let viewModel = model(PlaylistRepository(database))
        let proposal = AIProposal(profileId: ProfileRecord.guestID, kind: .organize(
            playlistId: 1, diff: PlaylistOrganizeDiff(currentTrackIds: [1, 2, 3], proposedTrackIds: [3, 999])
        ))
        viewModel.proposals.add(proposal)

        await #expect(throws: DatabaseError.self) {
            try await viewModel.apply(proposal)
        }
        #expect(try await membership(database) == [1, 2, 3])
        #expect(viewModel.proposals.contains(id: proposal.id))
    }

    private func model(_ repository: PlaylistRepository) -> AssistantViewModel {
        AssistantViewModel(
            proposals: ProposalStore(),
            backends: AssistantBackendStack(fallbackParser: HeuristicQueryParser()),
            repositories: AssistantRepositoryStack(
                playlists: repository,
                smartPlaylists: FakeSmartPlaylistRepository(),
                mixGenerator: FakeMixGeneratorService()
            )
        )
    }

    private func library(trackCount: Int, duplicatePair: Bool = false) async throws -> AppDatabase {
        let database = try AppDatabase.makeEmpty()
        try await database.writer.write { db in
            var playlist = PlaylistRecord(id: 1, name: "Proposal safety", profileId: ProfileRecord.guestID)
            try playlist.insert(db)
            for number in 1 ... trackCount {
                let title = duplicatePair && number <= 2 ? "Duplicate" : "Track \(number)"
                var track = TrackRecord(
                    id: Int64(number), filePath: "/fixtures/\(number).flac", title: title,
                    sortTitle: title, artistName: "Fixture Artist", duration: 200, fileSize: 1_000_000,
                    genre: "Rock", albumArtist: "Fixture Artist", year: 2000
                )
                try track.insert(db)
                var entry = PlaylistTrackRecord(playlistId: 1, trackId: Int64(number), position: number - 1)
                try entry.insert(db)
            }
        }
        return database
    }

    private func membership(_ database: AppDatabase) async throws -> [Int64] {
        try await database.writer.read { db in
            try Int64.fetchAll(db, sql: "SELECT trackId FROM playlistTrack WHERE playlistId = 1 ORDER BY position")
        }
    }
}
