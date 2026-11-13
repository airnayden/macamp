// EnergyReorderWiringTests — "Reorder by Energy" over the REAL mix pipeline.
//
// Every other suite around this one stops short of the join that was suspected:
// `AssistantContextualUnavailabilityTests` drives a scripted `FakeMixGeneratorService`,
// and `AudioFeatureIntegrationTests` proves the pass's rows reach
// `MixCandidateResolver` but never asks the assistant for a proposal. So neither
// could answer the actual question — does the `.rulesResult` source, the one a
// playlist reorder uses, actually carry `trackAudioFeature` energy through to
// `PlaylistDraft.energyArcApplied`?
//
// It does, and these cases are the proof: a real `MixGeneratorService` over a real
// database, seeded with real analysis rows, driven through the real
// `proposeEnergyReorder`. The negative case removes the rows and nothing else, so
// a green pair localises any future breakage to the energy read alone.
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services
import Testing
@testable import ViewModels

@MainActor
@Suite("EnergyReorderWiringTests")
struct EnergyReorderWiringTests {
    /// The happy path the listener reports as broken: a fully analysed playlist
    /// produces a real reordering proposal.
    @Test("a fully analysed playlist reorders through the real mix generator")
    func aFullyAnalysedPlaylistReordersThroughTheRealGenerator() async throws {
        let fixture = try WiringFixture.make(energies: [0.1, 0.3, 0.5, 0.7, 0.9])

        let proposal = await fixture.viewModel.proposeEnergyReorder(
            playlistId: 1,
            orderedTrackIds: fixture.trackIds,
            profileId: ProfileRecord.guestID
        )

        let filed = try #require(proposal, "an analysed playlist must produce an energy reorder")
        #expect(fixture.viewModel.lastUnavailability == nil)
        #expect(fixture.viewModel.lastError == nil)
        guard case let .organize(_, diff) = filed.kind else {
            Issue.record("an energy reorder must be an organize proposal")
            return
        }
        // rise/fall deal over ascending energy: [1,3,5] + reversed([2,4]).
        #expect(diff.proposedTrackIds == [1, 3, 5, 4, 2])
        #expect(Set(diff.proposedTrackIds) == Set(fixture.trackIds), "membership is preserved exactly")
    }

    /// The same library with the analysis rows deleted — the ONLY difference —
    /// takes the coverage path and says so, instead of returning a bare `nil`.
    @Test("the same playlist without analysis rows reports insufficientAnalysis")
    func theSamePlaylistWithoutAnalysisRowsReportsInsufficientAnalysis() async throws {
        let fixture = try WiringFixture.make(energies: [0.1, 0.3, 0.5, 0.7, 0.9])
        try fixture.discardAnalysis()

        let proposal = await fixture.viewModel.proposeEnergyReorder(
            playlistId: 1,
            orderedTrackIds: fixture.trackIds,
            profileId: ProfileRecord.guestID
        )

        #expect(proposal == nil)
        #expect(
            fixture.viewModel.lastUnavailability == .insufficientAnalysis(required: MixRanking.energyArcCoverage)
        )
        #expect(fixture.viewModel.lastError == nil)
    }

    /// The gate measures the SELECTION after unresolvable rows are dropped, so a
    /// playlist whose analysed share sits below the threshold is refused even on a
    /// library that is mostly analysed. This is the case a library-wide menu gate
    /// can never see, which is why the reason has to be reportable.
    @Test("a playlist below the coverage threshold is refused with a reason")
    func aPlaylistBelowTheCoverageThresholdIsRefusedWithAReason() async throws {
        let fixture = try WiringFixture.make(energies: [0.1, 0.3, 0.5, 0.7, 0.9], analysing: 3)

        let proposal = await fixture.viewModel.proposeEnergyReorder(
            playlistId: 1,
            orderedTrackIds: fixture.trackIds,
            profileId: ProfileRecord.guestID
        )

        #expect(proposal == nil)
        #expect(
            fixture.viewModel.lastUnavailability == .insufficientAnalysis(required: MixRanking.energyArcCoverage)
        )
    }

    /// A `missing` file is dropped by the resolver BEFORE coverage is measured, so
    /// four analysed tracks out of five rows still clear the gate — the drop
    /// shrinks the denominator rather than diluting it.
    @Test("an unavailable track is dropped before coverage is measured")
    func anUnavailableTrackIsDroppedBeforeCoverageIsMeasured() async throws {
        let fixture = try WiringFixture.make(
            energies: [0.1, 0.3, 0.5, 0.7, 0.9],
            analysing: 4,
            missing: [5]
        )

        let proposal = await fixture.viewModel.proposeEnergyReorder(
            playlistId: 1,
            orderedTrackIds: fixture.trackIds,
            profileId: ProfileRecord.guestID
        )

        let filed = try #require(proposal)
        guard case let .organize(_, diff) = filed.kind else {
            Issue.record("an energy reorder must be an organize proposal")
            return
        }
        #expect(
            Set(diff.proposedTrackIds) == Set(fixture.trackIds),
            "the dropped track is appended, never deleted from the playlist"
        )
    }
}

// MARK: - Fixture

/// A real library, real analysis rows, and an assistant over the real
/// ``MixGeneratorService``.
@MainActor
private struct WiringFixture {
    let database: AppDatabase
    let viewModel: AssistantViewModel
    let trackIds: [Int64]

    /// One present track per entry in `energies`. The first `analysing` of them
    /// get a `trackAudioFeature` row; ids listed in `missing` are inserted as
    /// unavailable.
    static func make(
        energies: [Double],
        analysing: Int? = nil,
        missing: [Int64] = []
    ) throws -> WiringFixture {
        let database = try AppDatabase.makeEmpty()
        let repository = TrackRepository(database)
        var ids: [Int64] = []
        for (index, energy) in energies.enumerated() {
            let ordinal = Int64(index + 1)
            let track = try repository.insert(TrackRecord(
                filePath: "/music/wiring-\(ordinal).flac",
                title: "Wiring \(ordinal)",
                sortTitle: "wiring \(ordinal)",
                artistName: "Artist \(ordinal)",
                duration: 200,
                fileSize: fileSize,
                mtime: mtime,
                availability: missing.contains(ordinal) ? .missing : .present
            ))
            let trackId = try #require(track.id)
            ids.append(trackId)
            guard index < (analysing ?? energies.count) else { continue }
            try write(database, trackId: trackId, energy: energy)
        }
        return WiringFixture(database: database, viewModel: makeViewModel(database), trackIds: ids)
    }

    func discardAnalysis() throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM trackAudioFeature")
        }
    }

    private static let fileSize: Int64 = 4096
    private static let mtime = 7.0

    private static func write(_ database: AppDatabase, trackId: Int64, energy: Double) throws {
        try database.writer.write { db in
            try TrackAudioFeatureRecord(
                trackId: trackId,
                fileSize: fileSize,
                mtime: mtime,
                bpm: 120,
                energy: energy,
                brightness: 0.5,
                analysisVersion: AudioAnalysisService.analysisVersion,
                computedAt: 0
            ).insert(db)
        }
    }

    private static func makeViewModel(_ database: AppDatabase) -> AssistantViewModel {
        AssistantViewModel(
            proposals: ProposalStore(),
            backends: AssistantBackendStack(fallbackParser: FakeAssistantQueryParser()),
            repositories: AssistantRepositoryStack(
                playlists: PlaylistRepository(database),
                smartPlaylists: SmartPlaylistRepository(database),
                mixGenerator: MixGeneratorService(database)
            )
        )
    }
}
