import Foundation
import GRDB
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

/// A migrated in-memory database, three scripted pools, and the seeding
/// vocabulary the suite writes in.
struct MixGeneratorFixture {
    let appDB: AppDatabase
    let similarity = FakeSimilarityService()
    let rediscovery = FakeRediscoveryService()
    let dayparts: FakeDaypartService

    init(current: Daypart = .evening) throws {
        appDB = try AppDatabase.makeEmpty()
        dayparts = FakeDaypartService(current: current)
    }

    var service: MixGeneratorService {
        MixGeneratorService(
            similarity: similarity,
            rediscovery: rediscovery,
            dayparts: dayparts,
            resolver: MixCandidateResolver(appDB)
        )
    }

    /// Inserts one track per id at an EXPLICIT rowid, spreading `artistCount`
    /// artists over the ids in contiguous BLOCKS.
    ///
    /// Blocked rather than cycling on purpose: a cycling library already arrives
    /// perfectly spaced, so the de-clump would be a no-op and every ordering
    /// assertion would silently test nothing.
    func library(
        ids: [Int64],
        duration: Double = 200,
        artistCount: Int = 10,
        availability: Availability = .present
    ) throws {
        let artists = max(1, artistCount)
        try appDB.writer.write { db in
            for (index, trackId) in ids.enumerated() {
                var record = TrackRecord(
                    id: trackId,
                    filePath: "/Music/\(trackId).flac",
                    title: "Track \(trackId)",
                    artistName: "Artist \(index * artists / max(1, ids.count))",
                    duration: duration,
                    availability: availability
                )
                try record.insert(db)
            }
        }
    }

    func feature(trackId: Int64, energy: Double) throws {
        let record = TrackAudioFeatureRecord(
            trackId: trackId,
            fileSize: 1,
            mtime: 0,
            energy: energy,
            brightness: 0.5,
            analysisVersion: 1,
            computedAt: 0
        )
        try appDB.writer.write { db in try record.insert(db) }
    }

    /// Descending co-session scores, so the pool arrives ranked exactly as the
    /// production service would rank it.
    static func neighbours(ids: [Int64]) -> [SimilarTrack] {
        ids.enumerated().map { index, trackId in
            SimilarTrack(trackId: trackId, score: Double(ids.count - index), basis: .coSession)
        }
    }

    /// Unscored rediscovery rows in the alphabetical order the library walk
    /// produces.
    static func rediscovered(ids: [Int64]) -> [RediscoveryCandidate] {
        ids.map { trackId in
            RediscoveryCandidate(
                trackId: trackId,
                title: "Track \(trackId)",
                artistName: "Artist",
                reason: .neverPlayed(dateAdded: nil)
            )
        }
    }

    static func daypartTracks(ids: [Int64]) -> [DaypartTrack] {
        ids.enumerated().map { index, trackId in
            DaypartTrack(
                daypart: .night,
                trackId: trackId,
                title: "Track \(trackId)",
                artistName: "Artist",
                plays: ids.count - index
            )
        }
    }

    /// A total, printable rendering of a draft — what the evidence file records
    /// and what "byte-identical" is asserted on.
    static func signature(_ draft: PlaylistDraft) -> String {
        draft.entries.map { "\($0.trackId):\($0.score)" }.joined(separator: ",")
    }

    /// The order `{similarity seed 42, count 25, seed 7}` produces over the
    /// three-artist forty-track fixture. Captured from a real run and pinned.
    static let goldenSimilarityOrder: [Int64] = [
        100, 114, 127, 101, 115, 128, 102, 116, 129, 103, 117, 130, 104,
        118, 131, 105, 119, 132, 106, 120, 133, 107, 121, 134, 108,
    ]
}
