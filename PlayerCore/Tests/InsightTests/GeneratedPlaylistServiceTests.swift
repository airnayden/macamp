import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

/// ``GeneratedPlaylistService`` over a REAL in-memory v16 database with a scripted
/// generator, a spy repository and a settable clock.
///
/// The generator is faked because its own suite proves the ranking; the database
/// is not, because every promise here is about rows — that a fresh kind writes
/// nothing at all, that a refresh rewrites membership in one transaction, and that
/// each profile gets its own playlist.
@MainActor
@Suite("GeneratedPlaylistServiceTests")
struct GeneratedPlaylistServiceTests {
    private static let guestId = ProfileRecord.guestID
    private static let daypartIds: [Int64] = [101, 102, 103]
    private static let rediscoveryIds: [Int64] = [104, 105]

    private func makeFixture() throws -> GeneratedPlaylistFixture {
        let fixture = try GeneratedPlaylistFixture()
        try fixture.library(ids: Array(100 ... 110))
        fixture.seedDrafts(daypart: Self.daypartIds, rediscovery: Self.rediscoveryIds)
        return fixture
    }

    @Test("First access creates one profile-scoped playlist per kind and materialises it")
    func createsBothMixesOnFirstAccess() async throws {
        let fixture = try makeFixture()

        let applied = try await fixture.service.refreshIfStale(profileId: Self.guestId)

        #expect(applied.map(\.kind) == [.daypartMix, .rediscovery])
        #expect(applied.map(\.created) == [true, true])
        #expect(applied.map(\.refreshedAt) == [GeneratedPlaylistFixture.start, GeneratedPlaylistFixture.start])
        let playlists = try fixture.playlists(profileId: Self.guestId)
        #expect(playlists.map(\.name) == ["Daily Mix", "Rediscover"])
        #expect(playlists.allSatisfy { $0.profileId == Self.guestId })
        let daypart = try #require(applied.first)
        let rediscovery = try #require(applied.last)
        #expect(try fixture.membership(playlistId: daypart.playlistId) == Self.daypartIds)
        #expect(try fixture.membership(playlistId: rediscovery.playlistId) == Self.rediscoveryIds)
    }

    @Test("A stored row carries the kind, the spec version and the refresh instant")
    func storedRowRecordsTheRefresh() async throws {
        let fixture = try makeFixture()

        try await fixture.service.refreshIfStale(profileId: Self.guestId)

        let record = try #require(try fixture.storedRecord(kind: .daypartMix, profileId: Self.guestId))
        #expect(record.generatorKind == "daypartMix")
        #expect(record.specVersion == 1)
        #expect(record.lastRefreshedAt == GeneratedPlaylistFixture.start)
        let spec = try JSONDecoder().decode(
            StoredSpec.self,
            from: Data(record.specJson.utf8)
        )
        #expect(spec.kind == "daypartMix")
        #expect(spec.targetCount == 25)
        #expect(spec.daypart == "evening")
        #expect(spec.rediscoveryList == nil)
    }

    @Test("Each kind asks its own candidate pool; rediscovery uses forgotten favourites")
    func eachKindAsksItsOwnPool() async throws {
        let fixture = try makeFixture()

        try await fixture.service.refreshIfStale(profileId: Self.guestId)

        let specs = fixture.generator.recording.specs
        #expect(specs.map(\.source) == [.daypart(part: nil), .rediscovery(list: .forgottenFavourites)])
        #expect(specs.allSatisfy { $0.profileId == Self.guestId })
        #expect(specs.allSatisfy { $0.targetCount == 25 })
        // Two kinds refreshed at the same instant must not rank identically.
        #expect(Set(specs.map(\.seed)).count == 2)
    }

    @Test("Two refreshes inside the TTL window cost exactly one — the second writes nothing")
    func freshMixesAreNotRefreshedAgain() async throws {
        let fixture = try makeFixture()
        try await fixture.service.refreshIfStale(profileId: Self.guestId)
        let callsAfterFirst = fixture.repository.recording.callCount

        fixture.clock.advance(by: 60 * 60)
        let applied = try await fixture.service.refreshIfStale(profileId: Self.guestId)

        #expect(applied.isEmpty)
        #expect(fixture.repository.recording.callCount == callsAfterFirst)
        #expect(fixture.generator.recording.specs.count == 2)
        let record = try #require(try fixture.storedRecord(kind: .daypartMix, profileId: Self.guestId))
        #expect(record.lastRefreshedAt == GeneratedPlaylistFixture.start)
    }

    @Test("A day later the daypart mix rebuilds and the weekly rediscovery mix does not")
    func staleDaypartMixRebuildsAlone() async throws {
        let fixture = try makeFixture()
        try await fixture.service.refreshIfStale(profileId: Self.guestId)
        let rediscoveryBefore = try #require(try fixture.storedRecord(kind: .rediscovery, profileId: Self.guestId))

        fixture.clock.advance(by: GeneratedPlaylistKind.daypartRefreshInterval)
        fixture.generator.seed(.daypart, draft: GeneratedPlaylistFixture.draft([106, 107], kind: .daypart))
        let applied = try await fixture.service.refreshIfStale(profileId: Self.guestId)

        let refresh = try #require(applied.first)
        #expect(applied.count == 1)
        #expect(refresh.kind == .daypartMix)
        #expect(refresh.created == false)
        #expect(try fixture.membership(playlistId: refresh.playlistId) == [106, 107])
        #expect(try fixture.membership(playlistId: rediscoveryBefore.playlistId) == Self.rediscoveryIds)
        #expect(fixture.repository.recording.createdNames.count == 2)
        let record = try #require(try fixture.storedRecord(kind: .daypartMix, profileId: Self.guestId))
        #expect(record.lastRefreshedAt == GeneratedPlaylistFixture.start + 86400)
    }

    @Test("After a week both kinds are stale and both rebuild")
    func bothKindsRebuildAfterTheLongerTTL() async throws {
        let fixture = try makeFixture()
        try await fixture.service.refreshIfStale(profileId: Self.guestId)

        fixture.clock.advance(by: GeneratedPlaylistKind.rediscoveryRefreshInterval)
        let applied = try await fixture.service.refreshIfStale(profileId: Self.guestId)

        #expect(applied.map(\.kind) == [.daypartMix, .rediscovery])
        #expect(applied.map(\.created) == [false, false])
        #expect(fixture.repository.recording.createdNames.count == 2)
    }

    @Test("A row that has never refreshed is stale, and materialises without a new playlist")
    func neverRefreshedRowIsStale() async throws {
        let fixture = try makeFixture()
        let guestId = Self.guestId
        let playlist = try await fixture.appDB.writer.write { db -> PlaylistRecord in
            var created = PlaylistRecord(name: "Daily Mix", profileId: guestId)
            try created.insert(db)
            var record = GeneratedPlaylistRecord(
                playlistId: created.id ?? 0,
                generatorKind: GeneratedPlaylistKind.daypartMix.rawValue,
                specJson: "{}",
                specVersion: 1
            )
            try record.insert(db)
            return created
        }

        let applied = try await fixture.service.refreshIfStale(profileId: Self.guestId)

        let refresh = try #require(applied.first)
        #expect(refresh.playlistId == playlist.id)
        #expect(refresh.created == false)
        #expect(try fixture.membership(playlistId: refresh.playlistId) == Self.daypartIds)
        #expect(fixture.repository.recording.createdNames == ["Rediscover"])
    }

    @Test("Mixes are per profile: a second profile gets its own playlists and rows")
    func mixesAreProfileScoped() async throws {
        let fixture = try makeFixture()
        let otherId = try fixture.makeProfile(named: "Ada")
        try await fixture.service.refreshIfStale(profileId: Self.guestId)
        let guestMembership = try #require(try fixture.storedRecord(kind: .daypartMix, profileId: Self.guestId))

        fixture.generator.seed(.daypart, draft: GeneratedPlaylistFixture.draft([108], kind: .daypart))
        let applied = try await fixture.service.refreshIfStale(profileId: otherId)

        #expect(applied.count == 2)
        #expect(try fixture.playlists(profileId: otherId).count == 2)
        #expect(try fixture.playlistCount() == 4)
        #expect(applied.map(\.created) == [true, true])
        // The other profile's rebuild must not have touched Guest's membership.
        #expect(try fixture.membership(playlistId: guestMembership.playlistId) == Self.daypartIds)
        let otherRecord = try #require(try fixture.storedRecord(kind: .daypartMix, profileId: otherId))
        #expect(otherRecord.playlistId != guestMembership.playlistId)
        #expect(try fixture.membership(playlistId: otherRecord.playlistId) == [108])
    }

    @Test("The listing returns this profile's generated playlists only")
    func listingIsBoundedAndProfileScoped() async throws {
        let fixture = try makeFixture()
        let otherId = try fixture.makeProfile(named: "Ada")
        try await fixture.service.refreshIfStale(profileId: Self.guestId)

        let summaries = try await fixture.service.generatedPlaylists(profileId: Self.guestId)

        #expect(summaries.map(\.kind) == [.daypartMix, .rediscovery])
        #expect(summaries.map(\.name) == ["Daily Mix", "Rediscover"])
        #expect(summaries.allSatisfy { $0.lastRefreshedAt == GeneratedPlaylistFixture.start })
        #expect(try await fixture.service.generatedPlaylists(profileId: otherId).isEmpty)
    }
}

/// The `generatedPlaylist.specJson` payload, decoded from the outside so the test
/// asserts the stored WIRE FORMAT rather than the type that wrote it.
private struct StoredSpec: Decodable {
    var kind: String
    var seed: UInt64
    var targetCount: Int
    var rediscoveryList: String?
    var daypart: String?
}
