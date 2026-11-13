// AIGatingTests — "zero cost when off", proven at the statement level.
//
// A call-count fake can only prove that the seam it stands in for went untouched.
// The claim here is stronger — that with the master toggle off the AI path executes
// NO SQL AT ALL — so the spy is GRDB's own `Database.trace`, which fires once per
// statement including transaction boundaries. A delta of zero across a
// `refreshIfStale` is not "the repository was not called": it is "the connection
// was not used".
//
// The disposition case is the one most likely to regress into data loss, so it is
// asserted from the listener's side: after the toggle goes off, the ORDINARY
// playlist query still lists what the feature materialised while it was on.
import Foundation
import GRDB
import os
import Persistence
import PlayerCoreTestSupport
import Services
import Testing
@testable import ViewModels

// MARK: - Fixture

/// A ``GeneratedPlaylistService`` over a real, statement-counting database.
@MainActor
struct AIGatingFixture {
    let database: AppDatabase
    let playlists: PlaylistRepository
    let generator = FakeMixGeneratorService()
    let settings = FakeAISettings()
    let service: GeneratedPlaylistService

    private let statements: OSAllocatedUnfairLock<Int>

    init() throws {
        let counter = OSAllocatedUnfairLock(initialState: 0)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { _ in counter.withLock { $0 += 1 } }
        }
        database = try AppDatabase(DatabaseQueue(configuration: configuration))
        statements = counter
        playlists = PlaylistRepository(database)
        service = GeneratedPlaylistService(
            database.writer,
            playlists: playlists,
            generator: generator,
            aiSettings: settings,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
    }

    /// How many SQL statements `work` executed.
    func statementsExecuted(during work: () async throws -> Void) async rethrows -> Int {
        let before = statements.withLock { $0 }
        try await work()
        return statements.withLock { $0 } - before
    }

    /// Two playable tracks and a draft over them, so a refresh has something to
    /// materialise (`playlistTrack.trackId` is a real foreign key).
    func seedLibrary() throws {
        try database.writer.write { db in
            for id in Int64(1) ... 2 {
                var track = TrackRecord(id: id, filePath: "/music/track\(id).flac", title: "Track \(id)")
                try track.insert(db)
            }
        }
        generator.setDraft(Self.draft([1, 2]))
    }

    /// The ordinary playlist listing — the exact query the sidebar runs.
    func listedPlaylists() throws -> [PlaylistWithTrackCount] {
        try playlists.playlistsWithTrackCounts(profileId: ProfileRecord.guestID, after: nil, limit: 50).items
    }

    func generatedNames() throws -> [String] {
        try listedPlaylists().map(\.playlist.name)
    }

    nonisolated static func draft(_ trackIds: [Int64]) -> PlaylistDraft {
        PlaylistDraft(
            entries: trackIds.map { MixDraftEntry(trackId: $0, provenance: .forgottenFavourite, score: 1) },
            nameHint: MixNameHint(sourceKind: .rediscovery, trackCount: trackIds.count)
        )
    }
}

// MARK: - Zero cost when off

@Suite("AI gating — zero cost when the master toggle is off")
@MainActor
struct AIZeroCostGatingTests {
    @Test("master off executes no SQL, runs no generator and writes nothing")
    func intelligenceOffTouchesNothing() async throws {
        let fixture = try AIGatingFixture()
        try fixture.seedLibrary()
        fixture.settings.intelligenceEnabled = false

        var refreshed: [GeneratedPlaylistRefresh] = []
        let executed = try await fixture.statementsExecuted {
            refreshed = try await fixture.service.refreshIfStale(profileId: ProfileRecord.guestID)
        }

        #expect(refreshed.isEmpty)
        #expect(executed == 0)
        #expect(fixture.generator.recording.specs.isEmpty)
        #expect(try fixture.generatedNames().isEmpty)
    }

    @Test("a per-bundle toggle silences only its own kind")
    func perBundleOffSkipsOnlyThatKind() async throws {
        let fixture = try AIGatingFixture()
        try fixture.seedLibrary()
        fixture.settings.autoMixesEnabled = false

        let refreshed = try await fixture.service.refreshIfStale(profileId: ProfileRecord.guestID)

        #expect(refreshed.map(\.kind) == [.rediscovery])
        #expect(fixture.generator.recording.specs.map(\.source.kind) == [.rediscovery])
    }

    @Test("everything on refreshes every kind")
    func everythingOnRefreshesBothKinds() async throws {
        let fixture = try AIGatingFixture()
        try fixture.seedLibrary()

        let refreshed = try await fixture.service.refreshIfStale(profileId: ProfileRecord.guestID)

        #expect(Set(refreshed.map(\.kind)) == Set(GeneratedPlaylistKind.allCases))
    }
}

// MARK: - Off-state disposition

@Suite("AI gating — what survives the master toggle going off")
@MainActor
struct AIOffStateDispositionTests {
    @Test("materialised playlists stay listed while refresh goes silent")
    func materialisedPlaylistsSurviveTheToggle() async throws {
        let fixture = try AIGatingFixture()
        try fixture.seedLibrary()
        let created = try await fixture.service.refreshIfStale(profileId: ProfileRecord.guestID)
        #expect(created.count == GeneratedPlaylistKind.allCases.count)
        let namesWhileOn = try fixture.generatedNames()
        #expect(!namesWhileOn.isEmpty)

        fixture.settings.intelligenceEnabled = false
        var refreshed: [GeneratedPlaylistRefresh] = []
        let executed = try await fixture.statementsExecuted {
            refreshed = try await fixture.service.refreshIfStale(profileId: ProfileRecord.guestID)
        }

        // Refresh is a recorded no-op...
        #expect(refreshed.isEmpty)
        #expect(executed == 0)
        // ...and NOTHING the feature made was removed: the ordinary playlist query
        // (the one the sidebar uses) still lists every playlist, with its tracks.
        #expect(try fixture.generatedNames() == namesWhileOn)
        let membership = try fixture.listedPlaylists().map(\.trackCount)
        #expect(membership == Array(repeating: 2, count: namesWhileOn.count))
    }
}

// MARK: - Per-bundle gate

@Suite("AI feature gate")
@MainActor
struct AIFeatureGateTests {
    @Test("a disabled bundle reports intelligenceDisabled")
    func disabledBundleIsUnavailable() {
        let settings = FakeAISettings()
        settings.nlCreationEnabled = false
        let probe = AIFeatureGate.availabilityProbe(for: .nlCreation, settings: settings)

        #expect(probe() == .unavailable(reason: .intelligenceDisabled))
    }

    @Test("the master toggle disables every bundle's probe")
    func intelligenceOffDisablesEveryBundle() {
        let settings = FakeAISettings()
        settings.intelligenceEnabled = false

        for bundle in AIFeatureBundle.allCases {
            let probe = AIFeatureGate.availabilityProbe(for: bundle, settings: settings)
            #expect(probe() == .unavailable(reason: .intelligenceDisabled))
        }
    }

    @Test("an enabled bundle defers to the system reading")
    func enabledBundleDefersToTheSystem() {
        let settings = FakeAISettings()
        let probe = AIFeatureGate.availabilityProbe(for: .nlCreation, settings: settings)

        // The system reading is host state (Apple Intelligence may or may not be
        // enabled here), so the only host-independent claim is that the gate is not
        // the thing saying no.
        #expect(probe() != .unavailable(reason: .intelligenceDisabled))
    }

    @Test("flipping a bundle back on takes effect with no rebuild")
    func theProbeReadsSettingsLive() {
        let settings = FakeAISettings()
        settings.rediscoveryEnabled = false
        let probe = AIFeatureGate.availabilityProbe(for: .rediscovery, settings: settings)
        #expect(probe() == .unavailable(reason: .intelligenceDisabled))

        settings.rediscoveryEnabled = true

        #expect(probe() != .unavailable(reason: .intelligenceDisabled))
    }
}

// MARK: - The view model under a disabled bundle

@Suite("AI gating — a direct view-model call while switched off")
@MainActor
struct AIDisabledSubmitTests {
    @Test("submit refuses with a typed error and touches no repository")
    func submitIsRefusedWhenTheBundleIsOff() async {
        let settings = FakeAISettings()
        settings.nlCreationEnabled = false
        let harness = SubmitHarness(
            availability: AIFeatureGate.availabilityProbe(for: .nlCreation, settings: settings)
        )

        let proposal = await harness.viewModel.submit(text: "upbeat 90s rock", profileId: ProfileRecord.guestID)

        #expect(proposal == nil)
        #expect(harness.viewModel.lastError == .assistantUnavailable(reason: .intelligenceDisabled))
        #expect(harness.store.isEmpty)
        #expect(harness.smartPlaylists.recording.previewRequests.isEmpty)
        #expect(harness.mixGenerator.recording.specs.isEmpty)
        #expect(harness.playlists.recording.mutationCount == 0)
    }
}
