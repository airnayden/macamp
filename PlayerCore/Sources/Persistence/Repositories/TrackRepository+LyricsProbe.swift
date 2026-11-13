import Foundation
import GRDB

// TrackRepository+LyricsProbe — the anti-join feeding the offline lyrics sweep.
//
// The sweep must be idempotent and incremental across launches: a track is a
// candidate only while `lyricsCache` holds NO row for its path — of any source,
// including a negative-result sentinel. So a probed-and-empty track is skipped
// exactly like a resolved one, and a 100k library is walked once, not once per
// launch.
//
// `Persistence` cannot import `Lyrics` (that is the dependency direction), so the
// join is expressed against the `lyricsCache` table this module's "v4" migration
// created rather than through ``LyricsCacheRecord``.

/// One `present` library track that has never been probed for lyrics.
public struct UnprobedLyricsTrack: Sendable, Equatable {
    /// The track's rowid — also the keyset cursor for the next page.
    public let id: Int64
    /// The absolute file path, which doubles as the lyrics cache key.
    public let filePath: String

    public init(id: Int64, filePath: String) {
        self.id = id
        self.filePath = filePath
    }
}

public extension TrackRepository {
    /// One bounded `id`-keyset page of present tracks with no `lyricsCache` row.
    ///
    /// Deliberately **not** profile-scoped: `lyricsCache` is keyed by file path and
    /// shared by every profile, exactly like the enrichment walk.
    func filePathsWithoutLyricsProbe(
        after lastID: Int64? = nil,
        limit: Int = 50
    ) async throws -> [UnprobedLyricsTrack] {
        let pageLimit = max(1, limit)
        let anchor = lastID ?? 0
        return try await dbWriter.read { db in
            let arguments: StatementArguments = [Availability.present.rawValue, anchor, pageLimit]
            return try Row
                .fetchAll(db, sql: Self.unprobedTracksSQL, arguments: arguments)
                .map { UnprobedLyricsTrack(id: $0["id"], filePath: $0["filePath"]) }
        }
    }

    /// `track.id` is a rowid alias starting at 1, so a `0` anchor selects the whole
    /// table and the cursor needs no conditional SQL.
    private static var unprobedTracksSQL: String {
        """
        SELECT track.id AS id, track.filePath AS filePath
        FROM track
        LEFT JOIN lyricsCache ON lyricsCache.cacheKey = track.filePath
        WHERE track.availability = ? AND lyricsCache.id IS NULL AND track.id > ?
        ORDER BY track.id ASC
        LIMIT ?
        """
    }
}
