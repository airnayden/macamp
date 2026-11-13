import Foundation
import GRDB

/// Read/write access to the `track` table, windowed for a 100k-row library.
///
/// Every list query is keyset-paginated or otherwise bounded; the repository
/// never fetches a whole table into memory. The browsing surface
/// (`tracksPage`/`tracksByRoot`/`tracksByGenre`/`searchTracks`/`distinctGenres`/
/// `recentlyAddedObservation`/`rootSummary`) is **profile-scoped**: a track is
/// visible when its file lives under the active profile's `libraryRoot` paths or
/// under no configured root at all (see ``LibraryVisibility``). The scoped browse
/// methods live in `TrackRepository+Browse.swift`; the per-profile user-state
/// operations live in `TrackRepository+ProfileState.swift`.
public protocol TrackRepositoryProviding: Sendable {
    func fetchTrack(id: Int64) throws -> TrackRecord?
    func fetchTrack(filePath: String) throws -> TrackRecord?
    @discardableResult func insert(_ track: TrackRecord) throws -> TrackRecord
    func update(_ track: TrackRecord) throws
    @discardableResult func deleteTrack(id: Int64) throws -> Bool
    @discardableResult func insertBatch(_ tracks: [TrackRecord]) throws -> Int
    @_disfavoredOverload
    func tracksPage(profileId: Int64, after cursor: PageCursor<String>?, limit: Int) throws
        -> Page<TrackRecord, String>
    /// Off-main async keyset page: suspends rather than blocking the caller's thread.
    func tracksPage(profileId: Int64, after cursor: PageCursor<String>?, limit: Int) async throws
        -> Page<TrackRecord, String>
    /// One keyset page of the tracks beneath a library-root folder, ordered by this
    /// profile's manual order for that root (`folderTrackOrder`) when it has
    /// drag-reordered the folder, else by `id`. The cursor key is that same order
    /// key, so pages stay exact across a reorder.
    func tracksByRoot(profileId: Int64, rootPath: String, after cursor: PageCursor<Int64>?, limit: Int) throws
        -> Page<TrackRecord, Int64>
    /// Persists this profile's manual order for one library root, backfilling the
    /// whole root on its first reorder so rows outside the dragged window keep a
    /// defined place. Never touches Favourites' `customPosition`.
    func updateFolderPositions(profileId: Int64, rootPath: String, _ updates: [(trackId: Int64, position: Int)])
        async throws
    /// A bounded availability tally for the tracks beneath a library-root folder.
    func rootSummary(rootPath: String) throws -> RootTrackSummary
    /// The distinct, non-empty genres present in the library, plus whether any
    /// track is untagged. Bounded (returns only the small set of distinct genre
    /// strings, never rows) and read off the calling actor so the genre-filter
    /// picker never blocks the main thread.
    func distinctGenres() async throws -> LibraryGenreFacets
    /// One keyset page (by `id`) of tracks matching a genre filter:
    /// `nil` returns every track (unfiltered); the empty string returns the
    /// "(no genre)" bucket (`genre IS NULL OR genre = ''`); any other value
    /// matches `genre = ? COLLATE NOCASE`.
    func tracksByGenre(profileId: Int64, genre: String?, after cursor: PageCursor<Int64>?, limit: Int) throws
        -> Page<TrackRecord, Int64>
    /// One keyset page of an album's tracks, ordered by `(disc, track, id)` so the
    /// listing reads in physical playing order across multi-disc releases.
    func tracksByAlbum(albumId: Int64, after cursor: PageCursor<Int64>?, limit: Int) throws
        -> Page<TrackRecord, Int64>
    /// One keyset page of an artist's tracks, ordered by `(sortTitle, id)`.
    func tracksByArtist(artistId: Int64, after cursor: PageCursor<String>?, limit: Int) throws
        -> Page<TrackRecord, String>
    func searchTracks(profileId: Int64, query: String, limit: Int) throws -> [TrackRecord]
    func recentlyAddedObservation(profileId: Int64, limit: Int)
        -> ValueObservation<ValueReducers.Fetch<[TrackRecord]>>
}

/// A bounded availability tally for the tracks beneath one library-root folder.
///
/// Computed by a single aggregate query (never a row fetch), so it stays cheap at
/// 100k scale. Drives the per-folder sidebar node and its "all unavailable" badge.
public struct RootTrackSummary: Sendable, Equatable {
    /// Total tracks whose file path is inside the root (any availability).
    public let total: Int
    /// Tracks currently present on a reachable local volume.
    public let present: Int
    /// Tracks whose backing file can no longer be found.
    public let missing: Int
    /// Tracks on an external volume that is not currently mounted.
    public let externalOffline: Int
    /// The newest `track.dateAdded` anywhere under the root, or `nil` when no track
    /// beneath it carries one. Derived per read (`MAX`), never stored.
    public let newestDateAdded: Double?

    public init(
        total: Int,
        present: Int,
        missing: Int,
        externalOffline: Int,
        newestDateAdded: Double? = nil
    ) {
        self.total = total
        self.present = present
        self.missing = missing
        self.externalOffline = externalOffline
        self.newestDateAdded = newestDateAdded
    }

    /// Whether the root still owns any tracks.
    public var hasTracks: Bool {
        total > 0
    }

    /// Whether the root has tracks but none are currently reachable — a removed
    /// or offline root whose rows survive. Drives the sidebar "Missing" badge.
    public var isFullyUnavailable: Bool {
        total > 0 && present == 0
    }
}

/// The genre vocabulary backing the library's genre-filter picker.
///
/// `genres` is the sorted set of distinct, non-empty genres; `includesUntagged`
/// reports whether any track has a `NULL`/empty genre, which decides whether the
/// "(no genre)" bucket appears in the picker.
public struct LibraryGenreFacets: Sendable, Equatable {
    public let genres: [String]
    public let includesUntagged: Bool

    public init(genres: [String], includesUntagged: Bool) {
        self.genres = genres
        self.includesUntagged = includesUntagged
    }
}

/// The concrete ``TrackRepositoryProviding`` over a GRDB writer.
///
/// Holds `any DatabaseWriter`; reads use `read { }` (a writer is also a reader),
/// writes use `write { }`. Nothing outside a closure ever touches a raw connection.
public struct TrackRepository: TrackRepositoryProviding {
    /// Internal (not `private`): the `TrackRepository+ProfileState.swift` and
    /// `TrackRepository+Browse.swift` sibling-file extensions need it.
    let dbWriter: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        dbWriter = appDatabase.writer
    }

    public init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func fetchTrack(id: Int64) throws -> TrackRecord? {
        try dbWriter.read { db in try TrackRecord.fetchOne(db, key: id) }
    }

    /// The track row backing `filePath` — the whole-file row when one exists, else
    /// the earliest `.cue` segment of that file.
    ///
    /// Since v20 a `filePath` can back N rows (one per cue segment), so a bare
    /// `filePath ==` `fetchOne` would return an arbitrary segment. Ordering by
    /// `cueStartFrame` makes the choice deterministic: the whole-file row's `-1`
    /// sentinel sorts below every real frame, so this is byte-for-byte the pre-v20
    /// answer for any file no sheet covers. Callers needing every segment use
    /// ``fetchTracks(filePath:)``; callers holding a segment's start frame use
    /// ``fetchTrack(_:)``.
    public func fetchTrack(filePath: String) throws -> TrackRecord? {
        try dbWriter.read { db in
            try TrackRecord.requestForAllRows(filePath: filePath).fetchOne(db)
        }
    }

    /// Every row backed by `filePath`, whole-file row first then each cue segment
    /// in playing order. Empty when the library holds no row for the file.
    public func fetchTracks(filePath: String) throws -> [TrackRecord] {
        try dbWriter.read { db in
            try TrackRecord.requestForAllRows(filePath: filePath).fetchAll(db)
        }
    }

    /// The one row `identity` names, resolving the full v20 `(filePath,
    /// cueStartFrame)` key rather than the path alone.
    public func fetchTrack(_ identity: TrackRecord.Identity) throws -> TrackRecord? {
        try dbWriter.read { db in
            try TrackRecord.request(for: identity).fetchOne(db)
        }
    }

    @discardableResult
    public func insert(_ track: TrackRecord) throws -> TrackRecord {
        var copy = track
        try dbWriter.write { db in try copy.insert(db) }
        return copy
    }

    public func update(_ track: TrackRecord) throws {
        try dbWriter.write { db in try track.update(db) }
    }

    @discardableResult
    public func deleteTrack(id: Int64) throws -> Bool {
        try dbWriter.write { db in try TrackRecord.deleteOne(db, key: id) }
    }

    /// Inserts many tracks in a single transaction (the seed/import fast path).
    @discardableResult
    public func insertBatch(_ tracks: [TrackRecord]) throws -> Int {
        try dbWriter.write { db in
            for var track in tracks {
                try track.insert(db)
            }
            return tracks.count
        }
    }
}
