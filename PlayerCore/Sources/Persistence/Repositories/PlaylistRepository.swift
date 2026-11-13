import Foundation
import GRDB

/// One ordered membership row of a playlist, joined to its track (1 query, no N+1).
///
/// `id`/`position` come from the `playlistTrack` row; `track` is the joined
/// `track` row. `position` is the keyset sort key (unique per playlist).
public struct PlaylistTrackItem: Decodable, FetchableRecord, Sendable {
    public var id: Int64?
    public var position: Int
    public var track: TrackRecord

    /// Memberwise, spelled out because a `public` struct's synthesised one is
    /// `internal` — a Fake or a preview in another module could not build one.
    public init(id: Int64?, position: Int, track: TrackRecord) {
        self.id = id
        self.position = position
        self.track = track
    }
}

/// A playlist annotated with its track count via a single grouped query.
public struct PlaylistWithTrackCount: Decodable, FetchableRecord, Sendable {
    public var playlist: PlaylistRecord
    public var trackCount: Int

    /// Memberwise, spelled out for the same reason as ``PlaylistTrackItem/init(id:position:track:)``.
    public init(playlist: PlaylistRecord, trackCount: Int) {
        self.playlist = playlist
        self.trackCount = trackCount
    }
}

/// Read/write access to `playlist` and its ordered `playlistTrack` memberships.
///
/// The list/membership/mutation methods come in two flavours: a synchronous form
/// (used by importers, tests and other off-actor callers) and an `async` form
/// that runs on a GRDB reader/writer OFF the calling actor. The `@MainActor`
/// `PlaylistViewModel` uses the `async` form so it never parks the main thread on
/// a pooled connection (the priority-inversion / "hang risk" Task 3 removed from
/// `LibraryViewModel`). The sync overloads carry `@_disfavoredOverload` so an
/// `await` call site resolves to the async twin.
///
/// Membership lookup and preview-checked reordering are async-only, so their
/// main-actor consumers never block on a pooled connection.
public protocol PlaylistRepositoryProviding: Sendable {
    func fetchPlaylist(id: Int64) throws -> PlaylistRecord?
    @_disfavoredOverload
    @discardableResult func insert(_ playlist: PlaylistRecord) throws -> PlaylistRecord
    @discardableResult func insert(_ playlist: PlaylistRecord) async throws -> PlaylistRecord
    @_disfavoredOverload
    @discardableResult func create(named name: String, profileId: Int64) throws -> PlaylistRecord
    @discardableResult func create(named name: String, profileId: Int64) async throws -> PlaylistRecord
    @_disfavoredOverload
    func update(_ playlist: PlaylistRecord) throws
    func update(_ playlist: PlaylistRecord) async throws
    @_disfavoredOverload
    @discardableResult func deletePlaylist(id: Int64) throws -> Bool
    @discardableResult func deletePlaylist(id: Int64) async throws -> Bool
    func playlistsPage(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<PlaylistRecord, String>
    @_disfavoredOverload
    func playlistsWithTrackCounts(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<PlaylistWithTrackCount, String>
    func playlistsWithTrackCounts(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) async throws -> Page<PlaylistWithTrackCount, String>
    @_disfavoredOverload
    func playlistTracksPage(
        playlistId: Int64,
        after cursor: PageCursor<Int>?,
        limit: Int
    ) throws -> Page<PlaylistTrackItem, Int>
    func playlistTracksPage(
        playlistId: Int64,
        after cursor: PageCursor<Int>?,
        limit: Int
    ) async throws -> Page<PlaylistTrackItem, Int>
    func containsTrack(playlistId: Int64, trackId: Int64) async throws -> Bool
    @_disfavoredOverload
    @discardableResult func addTrack(trackId: Int64, toPlaylist playlistId: Int64) throws -> PlaylistTrackRecord
    @discardableResult func addTrack(trackId: Int64, toPlaylist playlistId: Int64) async throws -> PlaylistTrackRecord
    @_disfavoredOverload
    @discardableResult func removeTrack(trackId: Int64, fromPlaylist playlistId: Int64) throws -> Int
    @discardableResult func removeTrack(trackId: Int64, fromPlaylist playlistId: Int64) async throws -> Int
    @_disfavoredOverload
    func reorder(playlistId: Int64, orderedTrackIds: [Int64]) throws
    func reorder(playlistId: Int64, orderedTrackIds: [Int64]) async throws
    /// Compares the complete preview and rewrites membership in one transaction.
    func reorder(playlistId: Int64, orderedTrackIds: [Int64], expectedTrackIds: [Int64]) async throws
}

public struct PlaylistRepository: PlaylistRepositoryProviding {
    private let dbWriter: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        dbWriter = appDatabase.writer
    }

    public init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func fetchPlaylist(id: Int64) throws -> PlaylistRecord? {
        try dbWriter.read { db in try PlaylistRecord.fetchOne(db, key: id) }
    }

    @_disfavoredOverload
    @discardableResult
    public func insert(_ playlist: PlaylistRecord) throws -> PlaylistRecord {
        var copy = playlist
        try dbWriter.write { db in try copy.insert(db) }
        return copy
    }

    /// Creates a new playlist owned by `profileId` and returns the inserted record.
    @_disfavoredOverload
    @discardableResult
    public func create(named name: String, profileId: Int64) throws -> PlaylistRecord {
        try insert(PlaylistRecord(name: name, profileId: profileId))
    }

    @_disfavoredOverload
    public func update(_ playlist: PlaylistRecord) throws {
        try dbWriter.write { db in try playlist.update(db) }
    }

    @_disfavoredOverload
    @discardableResult
    public func deletePlaylist(id: Int64) throws -> Bool {
        try dbWriter.write { db in try PlaylistRecord.deleteOne(db, key: id) }
    }

    /// One keyset page of a profile's playlists ordered by `(name, id)` ascending.
    public func playlistsPage(
        profileId: Int64 = ProfileRecord.guestID,
        after cursor: PageCursor<String>? = nil,
        limit: Int = 100
    ) throws -> Page<PlaylistRecord, String> {
        try dbWriter.read { db in
            try PlaylistRecord
                .filter(PlaylistRecord.Columns.profileId == profileId)
                .fetchPage(
                    db,
                    sort: KeysetSort(keyExpressionSQL: "name"),
                    after: cursor,
                    limit: limit,
                    cursorForLast: { PageCursor(key: $0.name, id: $0.id ?? 0) }
                )
        }
    }

    /// One keyset page of a profile's playlists annotated with their track counts (1 grouped query).
    @_disfavoredOverload
    public func playlistsWithTrackCounts(
        profileId: Int64 = ProfileRecord.guestID,
        after cursor: PageCursor<String>? = nil,
        limit: Int = 50
    ) throws -> Page<PlaylistWithTrackCount, String> {
        try dbWriter.read { db in
            try Self.fetchPlaylistsWithTrackCounts(db, profileId: profileId, after: cursor, limit: limit)
        }
    }

    /// One keyset page of a playlist's tracks in `position` order, each joined to
    /// its `track` row. Keyset columns are table-qualified because the join brings
    /// in `track`, which also defines an `id`.
    @_disfavoredOverload
    public func playlistTracksPage(
        playlistId: Int64,
        after cursor: PageCursor<Int>? = nil,
        limit: Int = 200
    ) throws -> Page<PlaylistTrackItem, Int> {
        try dbWriter.read { db in
            try Self.fetchPlaylistTracksPage(db, playlistId: playlistId, after: cursor, limit: limit)
        }
    }

    /// Appends a track to the end of a playlist (`position = max + 1`).
    @_disfavoredOverload
    @discardableResult
    public func addTrack(trackId: Int64, toPlaylist playlistId: Int64) throws -> PlaylistTrackRecord {
        try dbWriter.write { db in try Self.appendTrack(db, trackId: trackId, playlistId: playlistId) }
    }

    /// Removes every membership of `trackId` from a playlist; returns rows deleted.
    @_disfavoredOverload
    @discardableResult
    public func removeTrack(trackId: Int64, fromPlaylist playlistId: Int64) throws -> Int {
        try dbWriter.write { db in try Self.deleteTrack(db, trackId: trackId, playlistId: playlistId) }
    }

    /// Atomically rewrites a playlist's order to `orderedTrackIds`.
    ///
    /// Clears existing memberships then re-inserts at positions `0..<count` in one
    /// transaction, so the `UNIQUE(playlistId, position)` constraint is never
    /// transiently violated.
    @_disfavoredOverload
    public func reorder(playlistId: Int64, orderedTrackIds: [Int64]) throws {
        try dbWriter.write { db in try Self.rewriteOrder(db, playlistId: playlistId, orderedTrackIds: orderedTrackIds) }
    }
}

// MARK: - Off-actor async overloads

public extension PlaylistRepository {
    /// Inserts a playlist on a writer OFF the calling actor.
    @discardableResult
    func insert(_ playlist: PlaylistRecord) async throws -> PlaylistRecord {
        try await dbWriter.write { db in
            var copy = playlist
            try copy.insert(db)
            return copy
        }
    }

    /// Creates a playlist owned by `profileId` on a writer OFF the calling actor.
    @discardableResult
    func create(named name: String, profileId: Int64) async throws -> PlaylistRecord {
        try await dbWriter.write { db in
            var copy = PlaylistRecord(name: name, profileId: profileId)
            try copy.insert(db)
            return copy
        }
    }

    /// Updates a playlist on a writer OFF the calling actor.
    func update(_ playlist: PlaylistRecord) async throws {
        try await dbWriter.write { db in try playlist.update(db) }
    }

    /// Deletes a playlist on a writer OFF the calling actor.
    @discardableResult
    func deletePlaylist(id: Int64) async throws -> Bool {
        try await dbWriter.write { db in try PlaylistRecord.deleteOne(db, key: id) }
    }

    /// One keyset page of a profile's playlists + track counts, read OFF the calling actor.
    func playlistsWithTrackCounts(
        profileId: Int64 = ProfileRecord.guestID,
        after cursor: PageCursor<String>? = nil,
        limit: Int = 50
    ) async throws -> Page<PlaylistWithTrackCount, String> {
        try await dbWriter.read { db in
            try Self.fetchPlaylistsWithTrackCounts(db, profileId: profileId, after: cursor, limit: limit)
        }
    }

    /// One keyset page of a playlist's tracks, read OFF the calling actor.
    func playlistTracksPage(
        playlistId: Int64,
        after cursor: PageCursor<Int>? = nil,
        limit: Int = 200
    ) async throws -> Page<PlaylistTrackItem, Int> {
        try await dbWriter.read { db in
            try Self.fetchPlaylistTracksPage(db, playlistId: playlistId, after: cursor, limit: limit)
        }
    }

    /// Whether `trackId` already holds a membership row in `playlistId`, read OFF the
    /// calling actor.
    ///
    /// One `SELECT EXISTS` that stops at the first matching row, served by the
    /// `playlistTrack_on_trackId` index. The alternative available before this existed
    /// was paging ``playlistTracksPage(playlistId:after:limit:)`` until the id turned up
    /// or the pages ran out — O(playlist) async round-trips per question, against a
    /// documented 50k-entry ceiling.
    func containsTrack(playlistId: Int64, trackId: Int64) async throws -> Bool {
        try await dbWriter.read { db in
            try PlaylistTrackRecord
                .filter(PlaylistTrackRecord.Columns.playlistId == playlistId)
                .filter(PlaylistTrackRecord.Columns.trackId == trackId)
                .isEmpty(db) == false
        }
    }

    /// Appends a track to the end of a playlist on a writer OFF the calling actor.
    @discardableResult
    func addTrack(trackId: Int64, toPlaylist playlistId: Int64) async throws -> PlaylistTrackRecord {
        try await dbWriter.write { db in try Self.appendTrack(db, trackId: trackId, playlistId: playlistId) }
    }

    /// Removes a track from a playlist on a writer OFF the calling actor.
    @discardableResult
    func removeTrack(trackId: Int64, fromPlaylist playlistId: Int64) async throws -> Int {
        try await dbWriter.write { db in try Self.deleteTrack(db, trackId: trackId, playlistId: playlistId) }
    }

    /// Atomically rewrites a playlist's order on a writer OFF the calling actor.
    func reorder(playlistId: Int64, orderedTrackIds: [Int64]) async throws {
        try await dbWriter.write { db in
            try Self.rewriteOrder(db, playlistId: playlistId, orderedTrackIds: orderedTrackIds)
        }
    }

    func reorder(playlistId: Int64, orderedTrackIds: [Int64], expectedTrackIds: [Int64]) async throws {
        try await dbWriter.write { db in
            try Self.requireMembership(db, playlistId: playlistId, expectedTrackIds: expectedTrackIds)
            try Self.rewriteOrder(db, playlistId: playlistId, orderedTrackIds: orderedTrackIds)
        }
    }
}

// MARK: - Shared query bodies (sync + async funnel through these)

private extension PlaylistRepository {
    static func fetchPlaylistsWithTrackCounts(
        _ db: Database,
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<PlaylistWithTrackCount, String> {
        let pageLimit = max(1, limit)
        let anchor = cursor.map { (key: $0.key as any DatabaseValueConvertible, id: $0.id) }
        let rows = try PlaylistRecord
            .filter(PlaylistRecord.Columns.profileId == profileId)
            .keyset(
                KeysetSort(
                    keyExpressionSQL: "\"playlist\".\"name\"",
                    idColumnSQL: "\"playlist\".\"id\""
                ),
                after: anchor,
                limit: pageLimit + 1
            )
            .annotated(with: PlaylistRecord.playlistTracks.count.forKey("trackCount"))
            .asRequest(of: PlaylistWithTrackCount.self)
            .fetchAll(db)
        return makePage(from: rows, limit: pageLimit) {
            PageCursor(key: $0.playlist.name, id: $0.playlist.id ?? 0)
        }
    }

    static func fetchPlaylistTracksPage(
        _ db: Database,
        playlistId: Int64,
        after cursor: PageCursor<Int>?,
        limit: Int
    ) throws -> Page<PlaylistTrackItem, Int> {
        let pageLimit = max(1, limit)
        let anchor = cursor.map { (key: $0.key as any DatabaseValueConvertible, id: $0.id) }
        let rows = try PlaylistTrackRecord
            .filter(PlaylistTrackRecord.Columns.playlistId == playlistId)
            .keyset(
                KeysetSort(
                    keyExpressionSQL: "\"playlistTrack\".\"position\"",
                    idColumnSQL: "\"playlistTrack\".\"id\""
                ),
                after: anchor,
                limit: pageLimit + 1
            )
            .including(required: PlaylistTrackRecord.track)
            .asRequest(of: PlaylistTrackItem.self)
            .fetchAll(db)
        return makePage(from: rows, limit: pageLimit) {
            PageCursor(key: $0.position, id: $0.id ?? 0)
        }
    }

    static func appendTrack(_ db: Database, trackId: Int64, playlistId: Int64) throws -> PlaylistTrackRecord {
        let lastPosition = try PlaylistTrackRecord
            .filter(PlaylistTrackRecord.Columns.playlistId == playlistId)
            .select(max(PlaylistTrackRecord.Columns.position), as: Int.self)
            .fetchOne(db) ?? -1
        var entry = PlaylistTrackRecord(
            playlistId: playlistId,
            trackId: trackId,
            position: lastPosition + 1
        )
        try entry.insert(db)
        return entry
    }

    static func deleteTrack(_ db: Database, trackId: Int64, playlistId: Int64) throws -> Int {
        try PlaylistTrackRecord
            .filter(PlaylistTrackRecord.Columns.playlistId == playlistId)
            .filter(PlaylistTrackRecord.Columns.trackId == trackId)
            .deleteAll(db)
    }

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
