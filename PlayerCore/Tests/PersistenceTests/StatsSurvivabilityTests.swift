import Foundation
import GRDB
import Persistence
import Testing

/// The load-bearing guarantees of the `v15` statistics schema: history outlives the
/// tracks it describes, dies with its profile, and never stores a malformed heatmap.
@Suite("StatsSurvivabilityTests")
struct StatsSurvivabilityTests {
    @Test("deleting a track leaves its play event and heatmap intact")
    func deletingTrackKeepsHistory() throws {
        let appDB = try AppDatabase.makeEmpty()
        let trackId = try StatsFixtures.seedTrack(appDB, path: "/music/doomed.flac")
        var event = StatsFixtures.event(trackId: trackId)
        var heat = StatsFixtures.heat(trackId: trackId)
        try appDB.writer.write { db in
            try event.insert(db)
            try heat.insert(db)
        }

        let eventId = try #require(event.id)
        let heatId = try #require(heat.id)

        try appDB.writer.write { db in
            try db.execute(sql: "DELETE FROM track WHERE id = ?", arguments: [trackId])
        }

        try appDB.writer.read { db in
            let fetchedEvent = try PlayEventRecord.fetchOne(db, key: eventId)
            let storedEvent = try #require(fetchedEvent)
            #expect(storedEvent.trackId == trackId)
            #expect(storedEvent.artistName == "Pink Floyd")
            #expect(storedEvent.title == "Comfortably Numb")
            #expect(storedEvent.albumTitle == "The Wall")
            #expect(storedEvent.genre == "Progressive Rock")

            let fetchedHeat = try PlaySegmentHeatRecord.fetchOne(db, key: heatId)
            let storedHeat = try #require(fetchedHeat)
            #expect(storedHeat.trackId == trackId)
            #expect(storedHeat.artistName == "Pink Floyd")
            #expect(storedHeat.durationSeconds == 382)
            #expect(storedHeat.totalPasses == 3)

            let tracks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") ?? -1
            #expect(tracks == 0)
        }
    }

    @Test("deleting a track drops its folder order rows")
    func deletingTrackDropsFolderOrder() throws {
        let appDB = try AppDatabase.makeEmpty()
        let trackId = try StatsFixtures.seedTrack(appDB, path: "/music/ordered.flac")
        try appDB.writer.write { db in
            try FolderTrackOrderRecord(
                profileId: ProfileRecord.guestID, rootPath: "/music", trackId: trackId, position: 0
            ).insert(db)
            try db.execute(sql: "DELETE FROM track WHERE id = ?", arguments: [trackId])
        }

        let remaining = try appDB.writer.read { db in try FolderTrackOrderRecord.fetchCount(db) }
        #expect(remaining == 0)
    }

    @Test("deleting a profile cascades its events, rollups and heatmaps")
    func deletingProfileCascadesStats() throws {
        let appDB = try AppDatabase.makeEmpty()
        let profileId = try StatsFixtures.seedProfile(appDB, name: "Departing")
        var event = StatsFixtures.event(profileId: profileId, trackId: nil)
        var heat = StatsFixtures.heat(profileId: profileId, trackId: 99)
        var rollup = PlayEventRollupRecord(profileId: profileId, yearMonth: "2026-07", plays: 4)
        try appDB.writer.write { db in
            try event.insert(db)
            try heat.insert(db)
            try rollup.insert(db)
        }

        try ProfileRepository(appDB).delete(id: profileId)

        try appDB.writer.read { db in
            try #expect(PlayEventRecord.fetchCount(db) == 0)
            try #expect(PlaySegmentHeatRecord.fetchCount(db) == 0)
            try #expect(PlayEventRollupRecord.fetchCount(db) == 0)
        }
    }

    @Test("unknown artist and genre collapse to one sentinel bucket")
    func rollupSentinelGroupsUnknowns() throws {
        let appDB = try AppDatabase.makeEmpty()
        try appDB.writer.write { db in
            for (month, plays) in [("2026-06", 3), ("2026-07", 5)] {
                var unknown = PlayEventRollupRecord(
                    profileId: ProfileRecord.guestID, yearMonth: month, plays: plays
                )
                try unknown.insert(db)
            }
            var named = PlayEventRollupRecord(
                profileId: ProfileRecord.guestID, yearMonth: "2026-07", artistKey: "Pink Floyd", plays: 2
            )
            try named.insert(db)
        }

        let grouped = try appDB.writer.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT artistKey, SUM(plays) AS total FROM playEventRollup GROUP BY artistKey ORDER BY artistKey"
            )
            .map { (row: Row) in (row["artistKey"] as String, row["total"] as Int) }
        }
        #expect(grouped.count == 2)
        #expect(grouped[0].0 == PlayEventRollupRecord.unknownKey)
        #expect(grouped[0].1 == 8)
        #expect(grouped[1].0 == "Pink Floyd")
    }

    @Test("the sentinel makes the rollup unique key reject a duplicate month")
    func rollupSentinelEnforcesUniqueness() throws {
        let appDB = try AppDatabase.makeEmpty()
        var first = PlayEventRollupRecord(profileId: ProfileRecord.guestID, yearMonth: "2026-07")
        try appDB.writer.write { db in try first.insert(db) }

        #expect(throws: (any Error).self) {
            try appDB.writer.write { db in
                var duplicate = PlayEventRollupRecord(profileId: ProfileRecord.guestID, yearMonth: "2026-07")
                try duplicate.insert(db)
            }
        }
    }

    @Test("a bucketCounts blob of the wrong length is refused on save")
    func malformedBucketBlobIsRejected() throws {
        let appDB = try AppDatabase.makeEmpty()

        #expect(throws: PlaySegmentHeatError.invalidBucketCountsSize(expected: 400, actual: 8)) {
            try appDB.writer.write { db in
                var heat = StatsFixtures.heat(trackId: 1, bucketCounts: Data(count: 8))
                try heat.insert(db)
            }
        }

        let stored = try appDB.writer.read { db in try PlaySegmentHeatRecord.fetchCount(db) }
        #expect(stored == 0)
    }

    @Test("bucket counts round-trip through the little-endian blob")
    func bucketCountsRoundTrip() throws {
        var buckets = [UInt32](repeating: 0, count: PlaySegmentHeatRecord.bucketCount)
        buckets[0] = 1
        buckets[42] = 0x0102_0304
        buckets[99] = .max

        let blob = try PlaySegmentHeatRecord.encodeBuckets(buckets)
        #expect(blob.count == PlaySegmentHeatRecord.bucketCountsByteCount)
        #expect(Array(blob[168 ..< 172]) == [0x04, 0x03, 0x02, 0x01])
        try #expect(PlaySegmentHeatRecord.decodeBuckets(blob) == buckets)
    }

    @Test("encoding the wrong number of buckets throws instead of truncating")
    func encodingWrongBucketCountThrows() {
        #expect(throws: PlaySegmentHeatError.invalidBucketCountsSize(expected: 400, actual: 8)) {
            _ = try PlaySegmentHeatRecord.encodeBuckets([1, 2])
        }
    }
}
