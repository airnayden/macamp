import Foundation
import GRDB
import Persistence
import Testing

/// Deterministic seeds for the `v15` statistics tables. Every timestamp is fixed so a
/// failure never depends on when the suite ran.
enum StatsFixtures {
    static let startedAt: TimeInterval = 1_700_000_000
    static let utcOffsetSeconds = 7200

    static func event(
        profileId: Int64 = ProfileRecord.guestID,
        trackId: Int64?,
        artistName: String? = "Pink Floyd",
        title: String? = "Comfortably Numb",
        albumTitle: String? = "The Wall",
        genre: String? = "Progressive Rock"
    ) -> PlayEventRecord {
        PlayEventRecord(
            profileId: profileId,
            trackId: trackId,
            artistName: artistName,
            title: title,
            albumTitle: albumTitle,
            genre: genre,
            durationSeconds: 382,
            startedAt: startedAt,
            utcOffsetSeconds: utcOffsetSeconds,
            secondsListened: 300,
            completionFraction: 0.785,
            skipped: true,
            sourceSurface: "library",
            shuffle: true
        )
    }

    static func heat(
        profileId: Int64 = ProfileRecord.guestID,
        trackId: Int64,
        bucketCounts: Data = PlaySegmentHeatRecord.emptyBucketCounts
    ) -> PlaySegmentHeatRecord {
        PlaySegmentHeatRecord(
            profileId: profileId,
            trackId: trackId,
            artistName: "Pink Floyd",
            title: "Comfortably Numb",
            albumTitle: "The Wall",
            genre: "Progressive Rock",
            durationSeconds: 382,
            bucketCounts: bucketCounts,
            totalPasses: 3,
            updatedAt: startedAt
        )
    }

    static func seedTrack(_ appDB: AppDatabase, path: String) throws -> Int64 {
        var track = TrackRecord(filePath: path)
        try appDB.writer.write { db in try track.insert(db) }
        return try #require(track.id)
    }

    static func seedProfile(_ appDB: AppDatabase, name: String) throws -> Int64 {
        let profile = try ProfileRepository(appDB).create(ProfileRecord(name: name))
        return try #require(profile.id)
    }
}
