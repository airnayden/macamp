import Foundation
import GRDB

/// An album together with all of its tracks, fetched without an N+1 storm.
///
/// `including(all:)` issues exactly two `SELECT`s (parents, then their children),
/// invariant to the number of albums — never one query per album.
public struct AlbumWithTracks: Decodable, FetchableRecord, Sendable {
    public var album: AlbumRecord
    public var tracks: [TrackRecord]
}

/// An album annotated with its track count via a single grouped query.
public struct AlbumWithTrackCount: Decodable, FetchableRecord, Sendable {
    public var album: AlbumRecord
    public var trackCount: Int
}

/// Read/write access to the `album` table and its track associations.
public protocol AlbumRepositoryProviding: Sendable {
    func fetchAlbum(id: Int64) throws -> AlbumRecord?
    @discardableResult func insert(_ album: AlbumRecord) throws -> AlbumRecord
    func update(_ album: AlbumRecord) throws
    @discardableResult func deleteAlbum(id: Int64) throws -> Bool
    @_disfavoredOverload
    func albumsPage(after cursor: PageCursor<String>?, limit: Int) throws -> Page<AlbumRecord, String>
    /// Off-main async keyset page: suspends rather than blocking the caller's thread.
    func albumsPage(after cursor: PageCursor<String>?, limit: Int) async throws -> Page<AlbumRecord, String>
    func albumsWithTracksPage(
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<AlbumWithTracks, String>
    func albumsWithTrackCounts(
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<AlbumWithTrackCount, String>
    func albumsByArtist(
        artistId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<AlbumRecord, String>
}

public struct AlbumRepository: AlbumRepositoryProviding {
    private let dbWriter: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        dbWriter = appDatabase.writer
    }

    public init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func fetchAlbum(id: Int64) throws -> AlbumRecord? {
        try dbWriter.read { db in try AlbumRecord.fetchOne(db, key: id) }
    }

    @discardableResult
    public func insert(_ album: AlbumRecord) throws -> AlbumRecord {
        var copy = album
        try dbWriter.write { db in try copy.insert(db) }
        return copy
    }

    public func update(_ album: AlbumRecord) throws {
        try dbWriter.write { db in try album.update(db) }
    }

    @discardableResult
    public func deleteAlbum(id: Int64) throws -> Bool {
        try dbWriter.write { db in try AlbumRecord.deleteOne(db, key: id) }
    }

    /// One keyset page of albums ordered by `(sortTitle, id)` ascending.
    @_disfavoredOverload
    public func albumsPage(
        after cursor: PageCursor<String>? = nil,
        limit: Int = 100
    ) throws -> Page<AlbumRecord, String> {
        try dbWriter.read { db in try Self.fetchAlbumsPage(db, after: cursor, limit: limit) }
    }

    /// One keyset page of albums, read on a GRDB reader off the calling actor.
    public func albumsPage(
        after cursor: PageCursor<String>? = nil,
        limit: Int = 100
    ) async throws -> Page<AlbumRecord, String> {
        try await dbWriter.read { db in try Self.fetchAlbumsPage(db, after: cursor, limit: limit) }
    }

    private static func fetchAlbumsPage(
        _ db: Database,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<AlbumRecord, String> {
        try AlbumRecord.all().fetchPage(
            db,
            sort: KeysetSort(keyExpressionSQL: "COALESCE(sortTitle, '')"),
            after: cursor,
            limit: limit,
            cursorForLast: { PageCursor(key: $0.sortTitle ?? "", id: $0.id ?? 0) }
        )
    }

    /// One keyset page of albums, each eagerly loaded with its tracks (2 queries total).
    public func albumsWithTracksPage(
        after cursor: PageCursor<String>? = nil,
        limit: Int = 50
    ) throws -> Page<AlbumWithTracks, String> {
        let pageLimit = max(1, limit)
        return try dbWriter.read { db in
            let anchor = cursor.map { (key: $0.key as any DatabaseValueConvertible, id: $0.id) }
            let rows = try AlbumRecord.all()
                .keyset(
                    KeysetSort(keyExpressionSQL: "COALESCE(sortTitle, '')"),
                    after: anchor,
                    limit: pageLimit + 1
                )
                .including(all: AlbumRecord.tracks)
                .asRequest(of: AlbumWithTracks.self)
                .fetchAll(db)
            return makePage(from: rows, limit: pageLimit) {
                PageCursor(key: $0.album.sortTitle ?? "", id: $0.album.id ?? 0)
            }
        }
    }

    /// One keyset page of albums annotated with their track counts (1 grouped query).
    ///
    /// The keyset columns are table-qualified (`album.sortTitle` / `album.id`)
    /// because the count annotation `LEFT JOIN`s `track`, and both tables carry
    /// `id` and `sortTitle`.
    public func albumsWithTrackCounts(
        after cursor: PageCursor<String>? = nil,
        limit: Int = 50
    ) throws -> Page<AlbumWithTrackCount, String> {
        let pageLimit = max(1, limit)
        return try dbWriter.read { db in
            let anchor = cursor.map { (key: $0.key as any DatabaseValueConvertible, id: $0.id) }
            let rows = try AlbumRecord.all()
                .keyset(
                    KeysetSort(
                        keyExpressionSQL: "COALESCE(\"album\".\"sortTitle\", '')",
                        idColumnSQL: "\"album\".\"id\""
                    ),
                    after: anchor,
                    limit: pageLimit + 1
                )
                .annotated(with: AlbumRecord.tracks.count.forKey("trackCount"))
                .asRequest(of: AlbumWithTrackCount.self)
                .fetchAll(db)
            return makePage(from: rows, limit: pageLimit) {
                PageCursor(key: $0.album.sortTitle ?? "", id: $0.album.id ?? 0)
            }
        }
    }

    public func albumsByArtist(
        artistId: Int64,
        after cursor: PageCursor<String>? = nil,
        limit: Int = 100
    ) throws -> Page<AlbumRecord, String> {
        try dbWriter.read { db in
            try AlbumRecord
                .filter(AlbumRecord.Columns.artistId == artistId)
                .fetchPage(
                    db,
                    sort: KeysetSort(keyExpressionSQL: "COALESCE(sortTitle, '')"),
                    after: cursor,
                    limit: limit,
                    cursorForLast: { PageCursor(key: $0.sortTitle ?? "", id: $0.id ?? 0) }
                )
        }
    }
}

/// Profile-scoped browse overloads (Task 7).
///
/// An album is visible to a profile when **at least one of its tracks** is
/// visible under ``LibraryVisibility`` — files under the profile's `libraryRoot`
/// paths, or ownerless files under no configured root. There is no album-level
/// root concept: album visibility is derived purely from its tracks. The track
/// *count* still reflects the whole album; only which albums appear is scoped.
public extension AlbumRepository {
    /// One keyset page of albums with track counts, scoped to albums that own at
    /// least one track visible to `profileId`.
    func albumsWithTrackCounts(
        profileId: Int64,
        after cursor: PageCursor<String>? = nil,
        limit: Int = 50
    ) throws -> Page<AlbumWithTrackCount, String> {
        let pageLimit = max(1, limit)
        return try dbWriter.read { db in
            let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "vt.filePath")
            let anchor = cursor.map { (key: $0.key as any DatabaseValueConvertible, id: $0.id) }
            let rows = try AlbumRecord.all()
                .filter(
                    sql: "EXISTS (SELECT 1 FROM track vt WHERE vt.albumId = album.id AND \(visibility.sql))",
                    arguments: StatementArguments(visibility.arguments)
                )
                .keyset(
                    KeysetSort(
                        keyExpressionSQL: "COALESCE(\"album\".\"sortTitle\", '')",
                        idColumnSQL: "\"album\".\"id\""
                    ),
                    after: anchor,
                    limit: pageLimit + 1
                )
                .annotated(with: AlbumRecord.tracks.count.forKey("trackCount"))
                .asRequest(of: AlbumWithTrackCount.self)
                .fetchAll(db)
            return makePage(from: rows, limit: pageLimit) {
                PageCursor(key: $0.album.sortTitle ?? "", id: $0.album.id ?? 0)
            }
        }
    }

    /// One keyset page of an artist's albums, scoped to those owning a track
    /// visible to `profileId`.
    func albumsByArtist(
        profileId: Int64,
        artistId: Int64,
        after cursor: PageCursor<String>? = nil,
        limit: Int = 100
    ) throws -> Page<AlbumRecord, String> {
        try dbWriter.read { db in
            let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "vt.filePath")
            return try AlbumRecord
                .filter(AlbumRecord.Columns.artistId == artistId)
                .filter(
                    sql: "EXISTS (SELECT 1 FROM track vt WHERE vt.albumId = album.id AND \(visibility.sql))",
                    arguments: StatementArguments(visibility.arguments)
                )
                .fetchPage(
                    db,
                    sort: KeysetSort(keyExpressionSQL: "COALESCE(sortTitle, '')"),
                    after: cursor,
                    limit: limit,
                    cursorForLast: { PageCursor(key: $0.sortTitle ?? "", id: $0.id ?? 0) }
                )
        }
    }
}
