import Foundation
import GRDB
import Persistence
import Testing

/// Deterministic seeds for the `v16` playlist-intelligence tables. Every timestamp is
/// fixed so a failure never depends on when the suite ran.
enum AIFixtures {
    static let computedAt: TimeInterval = 1_700_000_000
    static let analysedMtime: TimeInterval = 1_699_000_000

    static func feature(trackId: Int64) -> TrackAudioFeatureRecord {
        TrackAudioFeatureRecord(
            trackId: trackId,
            fileSize: 41_000_000,
            mtime: analysedMtime,
            bpm: 122.5,
            energy: 0.72,
            brightness: 0.41,
            analysisVersion: 1,
            computedAt: computedAt
        )
    }

    static func generated(
        playlistId: Int64,
        kind: String = "daypartMix"
    ) -> GeneratedPlaylistRecord {
        GeneratedPlaylistRecord(
            playlistId: playlistId,
            generatorKind: kind,
            specJson: #"{"daypart":"morning"}"#,
            specVersion: 1
        )
    }

    static func seedPlaylist(_ appDB: AppDatabase, name: String) throws -> Int64 {
        var playlist = PlaylistRecord(name: name, profileId: ProfileRecord.guestID)
        try appDB.writer.write { db in try playlist.insert(db) }
        return try #require(playlist.id)
    }
}
