import Foundation
import GRDB
import Persistence

/// Shared seeds for the `v18` `trackLoudness` suites.
enum TrackLoudnessFixtures {
    static let seedMtime = 1_700_000_000.0

    static func fingerprint(
        fileSize: Int64 = 1024,
        mtime: Double = TrackLoudnessFixtures.seedMtime,
        cueStartFrame: Int64 = TrackLoudnessFingerprint.wholeFileCueStartFrame,
        cueEndFrame: Int64? = nil
    ) -> TrackLoudnessFingerprint {
        TrackLoudnessFingerprint(
            fileSize: fileSize,
            mtime: mtime,
            cueStartFrame: cueStartFrame,
            cueEndFrame: cueEndFrame
        )
    }

    static func record(
        trackId: Int64,
        integratedLUFS: Double? = -14.5,
        truePeak: Double = 0.98,
        albumLUFS: Double? = nil,
        albumPeak: Double? = nil,
        histogram: Data? = nil,
        analysisVersion: Int = 1,
        fingerprint: TrackLoudnessFingerprint = TrackLoudnessFixtures.fingerprint(),
        computedAt: Double = TrackLoudnessFixtures.seedMtime
    ) -> TrackLoudnessRecord {
        TrackLoudnessRecord(
            trackId: trackId,
            integratedLUFS: integratedLUFS,
            truePeak: truePeak,
            albumLUFS: albumLUFS,
            albumPeak: albumPeak,
            blockPowersHistogram: histogram,
            analysisVersion: analysisVersion,
            fingerprint: fingerprint,
            computedAt: computedAt
        )
    }

    /// A histogram whose only non-zero bin is `bin`, holding `count`.
    static func histogram(bin: Int, count: UInt32 = 1) throws -> Data {
        var counts = [UInt32](repeating: 0, count: BlockLoudnessHistogram.binCount)
        counts[bin] = count
        return try BlockLoudnessHistogram.encode(counts)
    }

    /// Inserts `count` present tracks whose ids are `1...count`, each fingerprinted
    /// by ``seedMtime`` so the staleness clause has something real to compare.
    static func seedTracks(_ db: Database, count: Int) throws {
        for index in 1 ... count {
            try db.execute(
                sql: """
                INSERT INTO track (id, filePath, title, fileSize, mtime)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [index, "/music/track-\(index).flac", "Track \(index)", 1024, seedMtime]
            )
        }
    }

    /// A `v17` database holding one row in each of nine tables spanning v1 → v17.
    ///
    /// Raw SQL keeps the seed decoupled from the current record shapes, matching the
    /// other pre-migration seeds in this target.
    static func seededV17Queue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v17")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO track (id, filePath, title, artistName, albumTitle, fileSize, mtime)
            VALUES (42, '/music/seeded.flac', 'Seeded', 'Pink Floyd', 'Animals', 1024, 1700000000.0)
            """)
            try db.execute(sql: "INSERT INTO playlist (id, name, profileId) VALUES (7, 'Seeded List', 1)")
            try db.execute(sql: """
            INSERT INTO playEvent
                (profileId, trackId, artistName, title, startedAt, utcOffsetSeconds)
            VALUES (1, 42, 'Pink Floyd', 'Seeded', 1700000000.0, 7200)
            """)
            try db.execute(sql: """
            INSERT INTO trackAudioFeature
                (trackId, fileSize, mtime, bpm, energy, brightness, analysisVersion, computedAt)
            VALUES (42, 1024, 1700000000.0, 120.0, 0.5, 0.4, 1, 1700000000.0)
            """)
            try db.execute(sql: """
            INSERT INTO lyricsCache (cacheKey, source, payloadJson, fetchedAt)
            VALUES ('/music/seeded.flac', 'embedded', '{}', 1700000000.0)
            """)
            try db.execute(sql: "INSERT INTO eqPreset (name, bandGainsJson) VALUES ('Rock', '[]')")
            try db.execute(sql: """
                INSERT INTO downloadHistory
                    (id, canonicalVideoID, filePath, audioFormat, audioQuality,
                     sourceURL, downloadedAt, utcOffsetSeconds)
                VALUES ('seeded', 'vid', '/music/seeded.m4a', 'm4a', 'best',
                        'https://www.youtube.com/watch?v=vid', 1700000000.0, 7200)
                """)
        }
        return queue
    }
}
