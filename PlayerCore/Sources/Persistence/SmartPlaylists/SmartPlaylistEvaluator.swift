import Foundation
import GRDB

/// The outcome of materialising one smart playlist.
public struct SmartPlaylistEvaluation: Sendable, Equatable {
    /// The playlist whose membership was rewritten.
    public let playlistId: Int64
    /// The profile the rules were scoped to — read from `playlist.profileId`, never
    /// supplied by the caller.
    public let profileId: Int64
    /// The materialised track ids, in the order they were written to
    /// `playlistTrack.position` (`0..<count`).
    public let trackIds: [Int64]
    /// The instant stamped into `smartPlaylist.lastEvaluatedAt`, as epoch seconds.
    public let evaluatedAt: Double

    public init(playlistId: Int64, profileId: Int64, trackIds: [Int64], evaluatedAt: Double) {
        self.playlistId = playlistId
        self.profileId = profileId
        self.trackIds = trackIds
        self.evaluatedAt = evaluatedAt
    }
}

/// Turns stored rules into `playlistTrack` rows.
///
/// Every function here takes a live `Database` and performs **no** transaction
/// management of its own, so a caller (``SmartPlaylistRepository``) can run the whole
/// evaluation — read rules, run the compiled query, rewrite membership, stamp
/// `lastEvaluatedAt` — inside a single `write {}`. Anything that can fail (missing
/// row, unknown version, malformed payload) fails *before* the first delete, and the
/// enclosing transaction rolls back regardless, so a broken rule set can never leave
/// a half-rewritten playlist.
public enum SmartPlaylistEvaluator {
    /// Evaluates one playlist's rules and rewrites its membership.
    ///
    /// - Returns: The materialised ids and the instant stamped on the row.
    /// - Throws: ``SmartPlaylistError`` when the rules are missing or unreadable.
    @discardableResult
    public static func evaluate(
        _ db: Database,
        playlistId: Int64,
        now: Date
    ) throws -> SmartPlaylistEvaluation {
        guard var record = try SmartPlaylistRecord
            .filter(SmartPlaylistRecord.Columns.playlistId == playlistId)
            .fetchOne(db)
        else {
            throw SmartPlaylistError.rulesNotFound(playlistId: playlistId)
        }
        let rules = try SmartPlaylistRules.decode(json: record.rulesJson, declaredVersion: record.rulesVersion)
        let profileId = try owningProfileId(db, playlistId: playlistId)
        let query = try SmartPlaylistCompiler.compile(rules, profileId: profileId, now: now, in: db)
        let trackIds = try query.request.fetchAll(db)

        try rewriteOrder(db, playlistId: playlistId, orderedTrackIds: trackIds)
        let evaluatedAt = now.timeIntervalSince1970
        record.lastEvaluatedAt = evaluatedAt
        try record.update(db)
        return SmartPlaylistEvaluation(
            playlistId: playlistId,
            profileId: profileId,
            trackIds: trackIds,
            evaluatedAt: evaluatedAt
        )
    }

    /// The profile a playlist belongs to.
    ///
    /// Derived from the row rather than accepted as a parameter: a caller that could
    /// pass the *wrong* profile could leak another profile's tracks into this
    /// playlist, and there is no legitimate reason to evaluate a playlist's rules
    /// against a profile that does not own it. `playlist.profileId` is nullable only
    /// to mirror the `v12` FK `ADD COLUMN`; a `NULL` reads as Guest, matching that
    /// migration's backfill.
    static func owningProfileId(_ db: Database, playlistId: Int64) throws -> Int64 {
        let playlist = try PlaylistRecord.fetchOne(db, key: playlistId)
        return playlist?.profileId ?? ProfileRecord.guestID
    }

    /// Clears the playlist's memberships and re-inserts `orderedTrackIds` at
    /// positions `0..<count`.
    ///
    /// The same delete-then-insert shape as `PlaylistRepository.reorder`: within one
    /// transaction the `UNIQUE(playlistId, position)` constraint is never
    /// transiently violated, and repeating the evaluation is idempotent because the
    /// previous rows are gone before the new ones land.
    static func rewriteOrder(_ db: Database, playlistId: Int64, orderedTrackIds: [Int64]) throws {
        try PlaylistTrackRecord
            .filter(PlaylistTrackRecord.Columns.playlistId == playlistId)
            .deleteAll(db)
        for (index, trackId) in orderedTrackIds.enumerated() {
            var entry = PlaylistTrackRecord(playlistId: playlistId, trackId: trackId, position: index)
            try entry.insert(db)
        }
    }
}
