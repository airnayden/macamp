import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

/// The two ways a refresh must do nothing: a toggle that is off, and a generator
/// that throws.
///
/// Both are asserted through the spy repository's call count rather than through
/// the return value — "returned an empty array" would still be true of a service
/// that read the whole library first, and the promise is that it never looks.
@MainActor
@Suite("GeneratedPlaylistGatingTests")
struct GeneratedPlaylistGatingTests {
    private static let guestId = ProfileRecord.guestID
    private static let daypartIds: [Int64] = [101, 102, 103]
    private static let rediscoveryIds: [Int64] = [104, 105]

    private func makeFixture() throws -> GeneratedPlaylistFixture {
        let fixture = try GeneratedPlaylistFixture()
        try fixture.library(ids: Array(100 ... 110))
        fixture.seedDrafts(daypart: Self.daypartIds, rediscovery: Self.rediscoveryIds)
        return fixture
    }

    @Test("Master toggle off makes refreshIfStale a recorded no-op")
    func intelligenceToggleOffIsARecordedNoOp() async throws {
        let fixture = try makeFixture()
        fixture.settings.intelligenceEnabled = false

        let applied = try await fixture.service.refreshIfStale(profileId: Self.guestId)

        #expect(applied.isEmpty)
        #expect(fixture.repository.recording.callCount == 0)
        #expect(fixture.generator.recording.specs.isEmpty)
        #expect(try fixture.playlistCount() == 0)
    }

    @Test("Master toggle off wins over every bundle flag")
    func intelligenceToggleOutranksBundleFlags() async throws {
        let fixture = try makeFixture()
        fixture.settings.setAll(true)
        fixture.settings.intelligenceEnabled = false

        #expect(fixture.settings.isEnabled(.autoMixes) == false)
        #expect(fixture.settings.isEnabled(.rediscovery) == false)
        try await fixture.service.refreshIfStale(profileId: Self.guestId)
        #expect(fixture.repository.recording.callCount == 0)
    }

    @Test("A bundle toggle off silences only its own kind")
    func bundleToggleOffSilencesOneKind() async throws {
        let fixture = try makeFixture()
        fixture.settings.autoMixesEnabled = false

        let applied = try await fixture.service.refreshIfStale(profileId: Self.guestId)

        #expect(applied.map(\.kind) == [.rediscovery])
        #expect(fixture.generator.recording.specs.map(\.source) == [.rediscovery(list: .forgottenFavourites)])
        #expect(fixture.repository.recording.createdNames == ["Rediscover"])
        #expect(try fixture.playlistCount() == 1)
    }

    @Test("A generator failure mid-refresh leaves the previous materialisation intact")
    func generatorFailureLeavesThePreviousMaterialisationIntact() async throws {
        let fixture = try makeFixture()
        try await fixture.service.refreshIfStale(profileId: Self.guestId)
        let before = try #require(try fixture.storedRecord(kind: .daypartMix, profileId: Self.guestId))

        fixture.clock.advance(by: GeneratedPlaylistKind.rediscoveryRefreshInterval)
        fixture.generator.setShouldFail(true)
        await #expect(throws: FakeMixGeneratorError.forcedFailure) {
            try await fixture.service.refreshIfStale(profileId: Self.guestId)
        }

        #expect(try fixture.membership(playlistId: before.playlistId) == Self.daypartIds)
        let after = try #require(try fixture.storedRecord(kind: .daypartMix, profileId: Self.guestId))
        #expect(after.lastRefreshedAt == GeneratedPlaylistFixture.start)
        #expect(after.specJson == before.specJson)
        #expect(try fixture.playlistCount() == 2)
    }

    @Test("A failure on first access leaves no empty playlist behind")
    func firstAccessFailureLeavesNoOrphan() async throws {
        let fixture = try makeFixture()
        fixture.generator.setShouldFail(true)

        await #expect(throws: FakeMixGeneratorError.forcedFailure) {
            try await fixture.service.refreshIfStale(profileId: Self.guestId)
        }

        #expect(try fixture.playlistCount() == 0)
        #expect(fixture.repository.recording.createdNames.isEmpty)
    }

    @Test("A failed refresh is retried by the next call, not swallowed")
    func aFailedRefreshIsRetriedNextTime() async throws {
        let fixture = try makeFixture()
        fixture.generator.setShouldFail(true)
        await #expect(throws: FakeMixGeneratorError.forcedFailure) {
            try await fixture.service.refreshIfStale(profileId: Self.guestId)
        }

        fixture.generator.setShouldFail(false)
        let applied = try await fixture.service.refreshIfStale(profileId: Self.guestId)

        #expect(applied.map(\.kind) == [.daypartMix, .rediscovery])
        #expect(try fixture.playlistCount() == 2)
    }
}
