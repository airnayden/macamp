import Foundation
import GRDB

/// The bounded reads the `.macampprofile` archive needs from the `track` side of the
/// schema.
///
/// Two windows, both keyset-paginated on a rowid so a 100k-track library is walked
/// one capped page at a time:
///
/// * ``archivedTrackStates(profileId:after:limit:)`` — EXPORT. `profileTrackState`
///   stores only ids and counters, so each row is joined to its track's identity
///   snapshot here, at export time. That is what lets import re-resolve the row on
///   another machine instead of trusting a foreign rowid. The join takes the four
///   identity columns and **never `filePath`**.
/// * ``archiveTrackIdentities(after:limit:)`` — IMPORT. The local library's identity
///   projection, offered to ``ProfileArchiveTrackMatcher``. Deliberately NOT
///   profile-scoped: a freshly imported profile owns no library roots, so a
///   visibility-filtered scan would match nothing.
public extension TrackRepository {
    /// The hard ceiling on one archive page.
    static let archiveFetchLimit = 500

    /// One keyset page of a profile's counter rows, each carrying its track's
    /// identity snapshot, ordered by `trackId`.
    func archivedTrackStates(
        profileId: Int64,
        after cursor: PageCursor<Int64>? = nil,
        limit: Int = TrackRepository.archiveFetchLimit
    ) async throws -> Page<ProfileArchiveTrackStateRow, Int64> {
        let capped = min(max(1, limit), Self.archiveFetchLimit)
        let anchor = cursor?.key ?? Int64.min
        return try await dbWriter.read { db in
            let rows = try ProfileArchiveTrackStateRow.fetchAll(
                db,
                sql: ProfileArchiveTrackStateRow.selectSQL,
                arguments: [profileId, anchor, capped + 1]
            )
            return makePage(from: rows, limit: capped) {
                PageCursor(key: $0.trackId, id: $0.trackId)
            }
        }
    }

    /// One keyset page of the WHOLE local library's identity projection, ordered by
    /// rowid. Selects no path column.
    func archiveTrackIdentities(
        after cursor: PageCursor<Int64>? = nil,
        limit: Int = TrackRepository.archiveFetchLimit
    ) async throws -> Page<ProfileArchiveLocalTrack, Int64> {
        let capped = min(max(1, limit), Self.archiveFetchLimit)
        let anchor = cursor?.key ?? Int64.min
        return try await dbWriter.read { db in
            let rows = try ProfileArchiveLocalTrack.fetchAll(
                db,
                sql: ProfileArchiveLocalTrack.selectSQL,
                arguments: [anchor, capped + 1]
            )
            return makePage(from: rows, limit: capped) {
                PageCursor(key: $0.trackId, id: $0.trackId)
            }
        }
    }
}

// MARK: - The joined counter row

/// A `profileTrackState` row paired with its track's identity snapshot.
///
/// The `trackId` is kept ONLY as the keyset cursor for the export scan; it is not
/// part of ``ProfileArchiveTrackState`` and never reaches the archive payload.
public struct ProfileArchiveTrackStateRow: Sendable, Equatable, FetchableRecord, Decodable {
    /// The LOCAL rowid this row was read at. Export-scan bookkeeping only.
    public var trackId: Int64
    public var isFavourite: Bool
    public var playCount: Int
    public var listenedCount: Int
    public var customPosition: Int?
    public var title: String?
    public var artistName: String?
    public var albumTitle: String?
    public var durationSeconds: Double?

    /// The archive payload for this row — identity snapshot plus counters, no ids.
    public var archived: ProfileArchiveTrackState {
        ProfileArchiveTrackState(
            track: ProfileArchiveTrackIdentity(
                artistName: artistName,
                title: title,
                albumTitle: albumTitle,
                durationSeconds: durationSeconds
            ),
            isFavourite: isFavourite,
            playCount: playCount,
            listenedCount: listenedCount,
            customPosition: customPosition
        )
    }

    /// Keyset-paginated on `(profileId, trackId)` — the table's own primary key, so
    /// the window is index-backed and the order is total.
    static let selectSQL = """
    SELECT pts.trackId AS trackId,
           pts.isFavourite AS isFavourite,
           pts.playCount AS playCount,
           pts.listenedCount AS listenedCount,
           pts.customPosition AS customPosition,
           track.title AS title,
           track.artistName AS artistName,
           track.albumTitle AS albumTitle,
           track.duration AS durationSeconds
    FROM profileTrackState pts
    LEFT JOIN track ON track.id = pts.trackId
    WHERE pts.profileId = ? AND pts.trackId > ?
    ORDER BY pts.trackId
    LIMIT ?
    """
}
