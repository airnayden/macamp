// SimilarityServiceTests — the scripted co-occurrence fixture and its guarantees.
//
// The fixture is deliberately hand-scripted rather than generated: every session, its
// membership and its exact age are written out below, so an expected ranking can be
// derived on paper and the test fails on a REASON rather than on a number nobody can
// re-derive.
//
// `now` is pinned to 2026-08-19T00:00:00Z and every instant is raw UTC epoch seconds,
// so the recency weights — and therefore the published scores — are the same in June
// as in July, on any machine, in any time zone.
import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@Suite("SimilarityServiceTests")
struct SimilarityServiceTests {
    // MARK: - Co-occurrence ranking

    @Test("A track co-played in every one of the seed's sessions ranks first")
    func coOccurringRanksCoPlayedTracksFirst() async throws {
        let database = try SimilarityFixture.makeSeededDatabase()
        let neighbours = try await SimilarityFixture.makeService(database)
            .coOccurring(with: SimilarityFixture.seedTrackId, profileId: SimilarityFixture.profileId, limit: 10)

        #expect(neighbours.map(\.trackId) == [43, 45])
        #expect(neighbours.allSatisfy { $0.basis == .coSession })
        // 43 shared all three of the seed's sessions; 45 shared two of them. The exact
        // weights are asserted only as an ordering — they are `pow` results, and a
        // hand-copied decimal would test the transcription, not the ranking.
        let strongest = try #require(neighbours.first)
        let weakest = try #require(neighbours.last)
        #expect(strongest.score > weakest.score)
        #expect(weakest.score > 0)
    }

    @Test("A track that never shared a session with the seed is absent")
    func neverCoPlayedTrackIsAbsent() async throws {
        let database = try SimilarityFixture.makeSeededDatabase()
        let neighbours = try await SimilarityFixture.makeService(database)
            .coOccurring(with: SimilarityFixture.seedTrackId, profileId: SimilarityFixture.profileId, limit: 10)

        // 44 was played, and often — just never in a sitting that also held 42.
        #expect(!neighbours.contains { $0.trackId == 44 })
        // The seed never proposes itself.
        #expect(!neighbours.contains { $0.trackId == SimilarityFixture.seedTrackId })
    }

    @Test("A co-play older than the lookback horizon is not scanned")
    func coPlayBeyondTheHorizonIsIgnored() async throws {
        let database = try SimilarityFixture.makeSeededDatabase()
        let neighbours = try await SimilarityFixture.makeService(database)
            .coOccurring(with: SimilarityFixture.seedTrackId, profileId: SimilarityFixture.profileId, limit: 10)

        // 47 shared a session with the seed 400 days ago — past `lookbackDays`.
        #expect(!neighbours.contains { $0.trackId == 47 })
    }

    @Test("Another profile's history never leaks into these results")
    func resultsAreProfileScoped() async throws {
        let database = try SimilarityFixture.makeSeededDatabase()
        let service = SimilarityFixture.makeService(database)

        let mine = try await service.coOccurring(
            with: SimilarityFixture.seedTrackId,
            profileId: SimilarityFixture.profileId,
            limit: 10
        )
        #expect(!mine.contains { $0.trackId == 99 })

        // Guest played the same seed with a track profile 2 has never heard.
        let guest = try await service.coOccurring(
            with: SimilarityFixture.seedTrackId,
            profileId: ProfileRecord.guestID,
            limit: 10
        )
        #expect(guest.map(\.trackId) == [99])
    }

    @Test("The limit caps the ranking, keeping the strongest neighbours")
    func limitIsHonoured() async throws {
        let database = try SimilarityFixture.makeSeededDatabase()
        let service = SimilarityFixture.makeService(database)
        let one = try await service.coOccurring(
            with: SimilarityFixture.seedTrackId,
            profileId: SimilarityFixture.profileId,
            limit: 1
        )
        #expect(one.map(\.trackId) == [43])

        let none = try await service.coOccurring(
            with: SimilarityFixture.seedTrackId,
            profileId: SimilarityFixture.profileId,
            limit: 0
        )
        #expect(none.isEmpty)
    }

    // MARK: - Determinism

    @Test("The same fixture produces an identical ranking every run")
    func rankingIsDeterministic() async throws {
        let database = try SimilarityFixture.makeSeededDatabase()
        let service = SimilarityFixture.makeService(database)
        var runs: [[SimilarTrack]] = []
        for _ in 0 ..< 5 {
            try await runs.append(service.coOccurring(
                with: SimilarityFixture.seedTrackId,
                profileId: SimilarityFixture.profileId,
                limit: 10
            ))
        }
        #expect(runs.allSatisfy { $0 == runs[0] })
    }

    @Test("A page size of 3 and of 500 produce identical results")
    func rankingIsPageSizeIndependent() async throws {
        let database = try SimilarityFixture.makeSeededDatabase()
        let tiny = try await SimilarityFixture.makeService(database, pageSize: 3)
            .coOccurring(with: SimilarityFixture.seedTrackId, profileId: SimilarityFixture.profileId, limit: 10)
        let wide = try await SimilarityFixture.makeService(database, pageSize: 500)
            .coOccurring(with: SimilarityFixture.seedTrackId, profileId: SimilarityFixture.profileId, limit: 10)

        #expect(tiny == wide)
        #expect(!tiny.isEmpty)
    }

    // MARK: - Cold start

    @Test("A seed with no plays falls back to metadata neighbours")
    func zeroEventSeedFallsBackToMetadata() async throws {
        let database = try SimilarityFixture.makeSeededDatabase()
        let service = SimilarityFixture.makeService(database)

        let coPlayed = try await service.coOccurring(
            with: SimilarityFixture.coldSeedTrackId,
            profileId: SimilarityFixture.profileId,
            limit: 10
        )
        #expect(coPlayed.isEmpty)

        let neighbours = try await service.similar(
            to: SimilarityFixture.coldSeedTrackId,
            profileId: SimilarityFixture.profileId,
            limit: 10
        )
        #expect(!neighbours.isEmpty)
        #expect(neighbours.allSatisfy { $0.basis == .metadata })
    }

    @Test("Metadata neighbours rank artist over genre over decade")
    func metadataNeighborsRankByTagStrength() async throws {
        let database = try SimilarityFixture.makeSeededDatabase()
        let neighbours = try await SimilarityFixture.makeService(database)
            .metadataNeighbors(
                for: SimilarityFixture.coldSeedTrackId,
                profileId: SimilarityFixture.profileId,
                limit: 10
            )

        // 51 artist+genre+decade, 52 artist, 53 genre+decade, 54 genre.
        #expect(neighbours.map(\.trackId) == [51, 52, 53, 54])
        #expect(neighbours.map(\.score) == [1.75, 1.0, 0.75, 0.5])
    }

    @Test("A track sharing nothing with the seed is not proposed")
    func unrelatedTrackIsNotAMetadataNeighbour() async throws {
        let database = try SimilarityFixture.makeSeededDatabase()
        let neighbours = try await SimilarityFixture.makeService(database)
            .metadataNeighbors(
                for: SimilarityFixture.coldSeedTrackId,
                profileId: SimilarityFixture.profileId,
                limit: 10
            )

        #expect(!neighbours.contains { $0.trackId == 55 })
    }

    @Test("An unavailable track is never proposed as a neighbour")
    func missingTrackIsExcluded() async throws {
        let database = try SimilarityFixture.makeSeededDatabase()
        let neighbours = try await SimilarityFixture.makeService(database)
            .metadataNeighbors(
                for: SimilarityFixture.coldSeedTrackId,
                profileId: SimilarityFixture.profileId,
                limit: 10
            )

        // 56 is a perfect tag match whose file has gone missing.
        #expect(!neighbours.contains { $0.trackId == 56 })
    }

    @Test("A seed that is not in the library returns nothing and does not throw")
    func unknownSeedIsEmpty() async throws {
        let database = try SimilarityFixture.makeSeededDatabase()
        let service = SimilarityFixture.makeService(database)
        let neighbours = try await service.metadataNeighbors(for: 9999, profileId: 2, limit: 10)
        #expect(neighbours.isEmpty)
        #expect(try await service.similar(to: 9999, profileId: 2, limit: 10).isEmpty)
    }

    @Test("An empty history yields no neighbours rather than an error")
    func emptyHistoryIsEmpty() async throws {
        let database = try AppDatabase.makeEmpty()
        let neighbours = try await SimilarityFixture.makeService(database)
            .similar(to: SimilarityFixture.seedTrackId, profileId: ProfileRecord.guestID, limit: 10)
        #expect(neighbours.isEmpty)
    }
}

// MARK: - The scripted fixture

/// The hand-written history and library every assertion above is derived from.
///
/// Sittings are days apart and the plays inside one are a minute apart, so the
/// 30-minute session gap cuts them exactly where the table below says it does.
enum SimilarityFixture {
    /// The profile under test. Guest (id 1) holds a rival history, so a result that
    /// crosses profiles is visible rather than merely absent.
    static let profileId: Int64 = 2
    /// The seed with a real listening history.
    static let seedTrackId: Int64 = 42
    /// The seed with NO play events at all — the cold-start path.
    static let coldSeedTrackId: Int64 = 50

    /// 2026-08-19T00:00:00Z, the pinned reference every recency weight is measured
    /// back from.
    static let now: Double = 1_787_097_600
    static let secondsPerDay: Double = 86400

    /// One sitting: how long ago it happened, and what was heard in it.
    ///
    /// | days ago | tracks       | shares a sitting with 42? |
    /// |----------|--------------|---------------------------|
    /// |        5 | 44, 46       | no                        |
    /// |       10 | 42, 43, 45   | yes                       |
    /// |       20 | 44, 45       | no                        |
    /// |       30 | 42, 43       | yes                       |
    /// |       60 | 42, 43, 45   | yes                       |
    /// |      400 | 42, 47       | yes, but past the horizon |
    static let sittings: [(daysAgo: Double, trackIds: [Int64])] = [
        (5, [44, 46]),
        (10, [42, 43, 45]),
        (20, [44, 45]),
        (30, [42, 43]),
        (60, [42, 43, 45]),
        (400, [42, 47]),
    ]

    /// Guest's rival sitting: the same seed, a track profile 2 has never played.
    static let guestSitting: (daysAgo: Double, trackIds: [Int64]) = (15, [42, 99])

    static func makeService(_ database: AppDatabase, pageSize: Int = 500) -> SimilarityService {
        SimilarityService(database, now: FakeClock(epochSeconds: now).nowProvider, pageSize: pageSize)
    }

    static func makeSeededDatabase() throws -> AppDatabase {
        let database = try AppDatabase.makeEmpty()
        try insertProfile(database)
        try insertHistory(database)
        try insertLibrary(database)
        return database
    }
}

private extension SimilarityFixture {
    static func insertProfile(_ database: AppDatabase) throws {
        try database.writer.write { db in
            var record = ProfileRecord(id: profileId, name: "Second", createdAt: Date(timeIntervalSince1970: 0))
            try record.insert(db)
        }
    }

    static func insertHistory(_ database: AppDatabase) throws {
        for sitting in sittings {
            try insert(sitting, into: database, profileId: profileId)
        }
        try insert(guestSitting, into: database, profileId: ProfileRecord.guestID)
    }

    static func insert(
        _ sitting: (daysAgo: Double, trackIds: [Int64]),
        into database: AppDatabase,
        profileId: Int64
    ) throws {
        let startedAt = now - sitting.daysAgo * secondsPerDay
        try database.writer.write { db in
            for (offset, trackId) in sitting.trackIds.enumerated() {
                var record = PlayEventRecord(
                    profileId: profileId,
                    trackId: trackId,
                    startedAt: startedAt + Double(offset) * 60,
                    utcOffsetSeconds: 0
                )
                try record.insert(db)
            }
        }
    }

    /// The cold-start library: two artists, two genres, three decades, and one row
    /// whose file has gone missing.
    ///
    /// | id | artist | genre | year | availability | shares with 50            |
    /// |----|--------|-------|------|--------------|---------------------------|
    /// | 50 |      1 | Rock  | 1994 | present      | the seed                  |
    /// | 51 |      1 | rock  | 1998 | present      | artist + genre + decade   |
    /// | 52 |      1 | Jazz  | 2005 | present      | artist                    |
    /// | 53 |      2 | Rock  | 1991 | present      | genre + decade            |
    /// | 54 |      2 | Rock  | 2011 | present      | genre                     |
    /// | 55 |      2 | Jazz  | 1960 | present      | nothing — never in a pool |
    /// | 56 |      1 | Rock  | 1994 | missing      | everything, but gone      |
    static let libraryRows: [(id: Int64, tags: LibraryTags)] = [
        (50, LibraryTags(artistId: 1, genre: "Rock", year: 1994)),
        (51, LibraryTags(artistId: 1, genre: "rock", year: 1998)),
        (52, LibraryTags(artistId: 1, genre: "Jazz", year: 2005)),
        (53, LibraryTags(artistId: 2, genre: "Rock", year: 1991)),
        (54, LibraryTags(artistId: 2, genre: "Rock", year: 2011)),
        (55, LibraryTags(artistId: 2, genre: "Jazz", year: 1960)),
        (56, LibraryTags(artistId: 1, genre: "Rock", year: 1994, availability: .missing)),
    ]

    struct LibraryTags {
        var artistId: Int64
        var genre: String
        var year: Int
        var availability: Availability = .present
    }

    static func insertLibrary(_ database: AppDatabase) throws {
        try database.writer.write { db in
            for (artistId, name) in [(Int64(1), "Aurora"), (Int64(2), "Bellwether")] {
                var artist = ArtistRecord(id: artistId, name: name, sortName: name)
                try artist.insert(db)
            }
            for row in libraryRows {
                var track = TrackRecord(
                    id: row.id,
                    filePath: "/Music/track-\(row.id).flac",
                    title: "Track \(row.id)",
                    sortTitle: "Track \(row.id)",
                    artistId: row.tags.artistId,
                    availability: row.tags.availability,
                    genre: row.tags.genre,
                    year: row.tags.year
                )
                try track.insert(db)
            }
        }
    }
}
