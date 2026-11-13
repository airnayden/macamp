import GRDB

/// A playlist preview can only replace the complete membership it was based on.
public enum PlaylistMembershipError: Error, Sendable, Equatable {
    case playlistNotFound(id: Int64)
    case changed(id: Int64)
}

extension PlaylistRepository {
    /// Called inside the same writer transaction as the replacement.
    static func requireMembership(_ db: Database, playlistId: Int64, expectedTrackIds: [Int64]) throws {
        guard try PlaylistRecord.fetchOne(db, key: playlistId) != nil else {
            throw PlaylistMembershipError.playlistNotFound(id: playlistId)
        }
        // The extra row detects an unseen tail without loading an unbounded playlist.
        let current = try PlaylistTrackRecord
            .filter(PlaylistTrackRecord.Columns.playlistId == playlistId)
            .order(PlaylistTrackRecord.Columns.position, PlaylistTrackRecord.Columns.id)
            .limit(expectedTrackIds.count + 1)
            .select(PlaylistTrackRecord.Columns.trackId, as: Int64.self)
            .fetchAll(db)
        guard current == expectedTrackIds else {
            throw PlaylistMembershipError.changed(id: playlistId)
        }
    }
}
