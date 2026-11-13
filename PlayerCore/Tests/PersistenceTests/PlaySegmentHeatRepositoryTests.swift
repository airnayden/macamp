import Foundation
import GRDB
import Persistence
import Testing

@Suite("PlaySegmentHeatRepositoryTests")
struct PlaySegmentHeatRepositoryTests {
    private static let trackId: Int64 = 4242

    private func identity(duration: Double = 100) -> PlaySegmentIdentity {
        PlaySegmentIdentity(
            artistName: "Pink Floyd",
            title: "Comfortably Numb",
            albumTitle: "The Wall",
            genre: "Progressive Rock",
            durationSeconds: duration
        )
    }

    private func deltas(_ filled: ClosedRange<Int>, _ count: UInt32 = 1) -> [UInt32] {
        var buckets = [UInt32](repeating: 0, count: PlaySegmentHeatRecord.bucketCount)
        for index in filled {
            buckets[index] = count
        }
        return buckets
    }

    @Test("the first merge creates the row with its identity snapshot")
    func firstMergeCreatesTheRow() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = PlaySegmentHeatRepository(database)

        try await repository.mergeSegmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: Self.trackId,
            identity: identity(),
            deltas: deltas(0 ... 9),
            updatedAt: StatsFixtures.startedAt
        )

        let stored = try await repository.segmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: Self.trackId
        )
        let row = try #require(stored)
        let buckets = try row.decodedBuckets()
        #expect(row.totalPasses == 1)
        #expect(row.albumTitle == "The Wall")
        #expect(row.genre == "Progressive Rock")
        #expect(row.durationSeconds == 100)
        #expect(row.updatedAt == StatsFixtures.startedAt)
        #expect(buckets[0 ... 9].allSatisfy { $0 == 1 })
        #expect(buckets[10 ... 99].allSatisfy { $0 == 0 })
    }

    @Test("merges are additive and bump the pass count once each")
    func mergesAreAdditive() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = PlaySegmentHeatRepository(database)

        try await repository.mergeSegmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: Self.trackId,
            identity: identity(),
            deltas: deltas(0 ... 49),
            updatedAt: 1
        )
        try await repository.mergeSegmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: Self.trackId,
            identity: identity(),
            deltas: deltas(25 ... 74),
            updatedAt: 2
        )

        let row = try #require(try await repository.segmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: Self.trackId
        ))
        let buckets = try row.decodedBuckets()
        #expect(row.totalPasses == 2)
        #expect(row.updatedAt == 2)
        #expect(buckets[0 ... 24].allSatisfy { $0 == 1 })
        #expect(buckets[25 ... 49].allSatisfy { $0 == 2 })
        #expect(buckets[50 ... 74].allSatisfy { $0 == 1 })
        #expect(buckets[75 ... 99].allSatisfy { $0 == 0 })
    }

    @Test("a bucket at the maximum saturates instead of wrapping to zero")
    func countsSaturate() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = PlaySegmentHeatRepository(database)
        let saturated = try PlaySegmentHeatRecord.encodeBuckets(deltas(0 ... 0, UInt32.max))
        let trackId = Self.trackId
        try await database.writer.write { db in
            var seeded = StatsFixtures.heat(trackId: trackId, bucketCounts: saturated)
            try seeded.insert(db)
        }

        try await repository.mergeSegmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: Self.trackId,
            identity: identity(),
            deltas: deltas(0 ... 1),
            updatedAt: 3
        )

        let row = try #require(try await repository.segmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: Self.trackId
        ))
        let buckets = try row.decodedBuckets()
        #expect(buckets[0] == UInt32.max)
        #expect(buckets[1] == 1)
    }

    @Test("an all-zero merge writes nothing at all")
    func emptyMergeIsANoOp() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = PlaySegmentHeatRepository(database)

        try await repository.mergeSegmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: Self.trackId,
            identity: identity(),
            deltas: deltas(0 ... 0, 0),
            updatedAt: 1
        )

        let stored = try await repository.segmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: Self.trackId
        )
        #expect(stored == nil)
    }

    @Test("a wrong-length delta array is refused")
    func wrongLengthDeltasAreRefused() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = PlaySegmentHeatRepository(database)

        await #expect(throws: PlaySegmentHeatError.self) {
            try await repository.mergeSegmentHeat(
                profileId: ProfileRecord.guestID,
                trackId: Self.trackId,
                identity: identity(),
                deltas: [1, 2, 3],
                updatedAt: 1
            )
        }
    }

    @Test("a merge after the track row is gone keeps the stored snapshot")
    func mergePreservesTheSnapshotWhenTheTrackIsGone() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = PlaySegmentHeatRepository(database)
        try await repository.mergeSegmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: Self.trackId,
            identity: identity(),
            deltas: deltas(0 ... 9),
            updatedAt: 1
        )

        try await repository.mergeSegmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: Self.trackId,
            identity: PlaySegmentIdentity(durationSeconds: 100),
            deltas: deltas(0 ... 9),
            updatedAt: 2
        )

        let row = try #require(try await repository.segmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: Self.trackId
        ))
        #expect(row.artistName == "Pink Floyd")
        #expect(row.albumTitle == "The Wall")
        #expect(row.genre == "Progressive Rock")
    }

    @Test("keyset pages cover every heatmap of a profile exactly once")
    func keysetPagesCoverEveryRow() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = PlaySegmentHeatRepository(database)
        let otherProfile = try StatsFixtures.seedProfile(database, name: "Other")
        for trackId in Int64(1) ... 7 {
            try await repository.mergeSegmentHeat(
                profileId: ProfileRecord.guestID,
                trackId: trackId,
                identity: identity(),
                deltas: deltas(0 ... 0),
                updatedAt: 1
            )
        }
        try await repository.mergeSegmentHeat(
            profileId: otherProfile,
            trackId: 99,
            identity: identity(),
            deltas: deltas(0 ... 0),
            updatedAt: 1
        )

        var seen: [Int64] = []
        var cursor: PageCursor<Int64>?
        repeat {
            let page = try await repository.allSegmentHeat(
                profileId: ProfileRecord.guestID,
                after: cursor,
                limit: 3
            )
            seen.append(contentsOf: page.items.map(\.trackId))
            cursor = page.nextCursor
        } while cursor != nil

        #expect(seen == Array(Int64(1) ... 7))
    }

    @Test("a heatmap outlives the track it describes")
    func heatmapSurvivesTrackDeletion() async throws {
        let database = try AppDatabase.makeEmpty()
        let repository = PlaySegmentHeatRepository(database)
        let trackId = try StatsFixtures.seedTrack(database, path: "/music/wall.flac")
        try await repository.mergeSegmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: trackId,
            identity: identity(),
            deltas: deltas(0 ... 9),
            updatedAt: 1
        )

        try await database.writer.write { db in
            _ = try TrackRecord.deleteOne(db, key: trackId)
        }

        let row = try #require(try await repository.segmentHeat(
            profileId: ProfileRecord.guestID,
            trackId: trackId
        ))
        #expect(row.artistName == "Pink Floyd")
        #expect(row.title == "Comfortably Numb")
        #expect(try row.decodedBuckets()[0 ... 9].allSatisfy { $0 == 1 })
    }

    @Test("bucket blobs round-trip and reject any other length")
    func blobRoundTripAndValidation() throws {
        let buckets = (0 ..< PlaySegmentHeatRecord.bucketCount).map { UInt32($0) * 7 }
        let encoded = try PlaySegmentHeatRecord.encodeBuckets(buckets)

        #expect(encoded.count == PlaySegmentHeatRecord.bucketCountsByteCount)
        #expect(try PlaySegmentHeatRecord.decodeBuckets(encoded) == buckets)
        #expect(throws: PlaySegmentHeatError.self) {
            try PlaySegmentHeatRecord.validateBucketCounts(Data(count: 399))
        }
    }
}
