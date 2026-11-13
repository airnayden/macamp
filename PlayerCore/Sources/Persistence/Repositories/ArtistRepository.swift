import Foundation
import GRDB

/// An artist annotated with its album count via a single grouped query.
public struct ArtistWithAlbumCount: Decodable, FetchableRecord, Sendable {
    public var artist: ArtistRecord
    public var albumCount: Int
}

/// Read/write access to the `artist` table and its album associations.
public protocol ArtistRepositoryProviding: Sendable {
    func fetchArtist(id: Int64) throws -> ArtistRecord?
    @discardableResult func insert(_ artist: ArtistRecord) throws -> ArtistRecord
    func update(_ artist: ArtistRecord) throws
    @discardableResult func deleteArtist(id: Int64) throws -> Bool
    @_disfavoredOverload
    func artistsPage(after cursor: PageCursor<String>?, limit: Int) throws -> Page<ArtistRecord, String>
    /// Off-main async keyset page: suspends rather than blocking the caller's thread.
    func artistsPage(after cursor: PageCursor<String>?, limit: Int) async throws -> Page<ArtistRecord, String>
    func artistsWithAlbumCounts(
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<ArtistWithAlbumCount, String>
}

public struct ArtistRepository: ArtistRepositoryProviding {
    private let dbWriter: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        dbWriter = appDatabase.writer
    }

    public init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func fetchArtist(id: Int64) throws -> ArtistRecord? {
        try dbWriter.read { db in try ArtistRecord.fetchOne(db, key: id) }
    }

    @discardableResult
    public func insert(_ artist: ArtistRecord) throws -> ArtistRecord {
        var copy = artist
        try dbWriter.write { db in try copy.insert(db) }
        return copy
    }

    public func update(_ artist: ArtistRecord) throws {
        try dbWriter.write { db in try artist.update(db) }
    }

    @discardableResult
    public func deleteArtist(id: Int64) throws -> Bool {
        try dbWriter.write { db in try ArtistRecord.deleteOne(db, key: id) }
    }

    /// One keyset page of artists ordered by `(sortName, id)` ascending.
    @_disfavoredOverload
    public func artistsPage(
        after cursor: PageCursor<String>? = nil,
        limit: Int = 100
    ) throws -> Page<ArtistRecord, String> {
        try dbWriter.read { db in try Self.fetchArtistsPage(db, after: cursor, limit: limit) }
    }

    /// One keyset page of artists, read on a GRDB reader off the calling actor.
    public func artistsPage(
        after cursor: PageCursor<String>? = nil,
        limit: Int = 100
    ) async throws -> Page<ArtistRecord, String> {
        try await dbWriter.read { db in try Self.fetchArtistsPage(db, after: cursor, limit: limit) }
    }

    private static func fetchArtistsPage(
        _ db: Database,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<ArtistRecord, String> {
        try ArtistRecord.all().fetchPage(
            db,
            sort: KeysetSort(keyExpressionSQL: "sortName"),
            after: cursor,
            limit: limit,
            cursorForLast: { PageCursor(key: $0.sortName, id: $0.id ?? 0) }
        )
    }

    /// One keyset page of artists annotated with their album counts (1 grouped query).
    ///
    /// The keyset columns are table-qualified because the count annotation
    /// `LEFT JOIN`s `album`, which also defines an `id`.
    public func artistsWithAlbumCounts(
        after cursor: PageCursor<String>? = nil,
        limit: Int = 50
    ) throws -> Page<ArtistWithAlbumCount, String> {
        let pageLimit = max(1, limit)
        return try dbWriter.read { db in
            let anchor = cursor.map { (key: $0.key as any DatabaseValueConvertible, id: $0.id) }
            let rows = try ArtistRecord.all()
                .keyset(
                    KeysetSort(
                        keyExpressionSQL: "\"artist\".\"sortName\"",
                        idColumnSQL: "\"artist\".\"id\""
                    ),
                    after: anchor,
                    limit: pageLimit + 1
                )
                .annotated(with: ArtistRecord.albums.count.forKey("albumCount"))
                .asRequest(of: ArtistWithAlbumCount.self)
                .fetchAll(db)
            return makePage(from: rows, limit: pageLimit) {
                PageCursor(key: $0.artist.sortName, id: $0.artist.id ?? 0)
            }
        }
    }
}

public extension ArtistRepository {
    /// One keyset page of artists with album counts, scoped to artists owning at
    /// least one track visible to `profileId` (Task 7). An artist is visible iff
    /// one of its tracks is; the album count itself stays unscoped.
    func artistsWithAlbumCounts(
        profileId: Int64,
        after cursor: PageCursor<String>? = nil,
        limit: Int = 50
    ) throws -> Page<ArtistWithAlbumCount, String> {
        let pageLimit = max(1, limit)
        return try dbWriter.read { db in
            let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "vt.filePath")
            let anchor = cursor.map { (key: $0.key as any DatabaseValueConvertible, id: $0.id) }
            let rows = try ArtistRecord.all()
                .filter(
                    sql: "EXISTS (SELECT 1 FROM track vt WHERE vt.artistId = artist.id AND \(visibility.sql))",
                    arguments: StatementArguments(visibility.arguments)
                )
                .keyset(
                    KeysetSort(
                        keyExpressionSQL: "\"artist\".\"sortName\"",
                        idColumnSQL: "\"artist\".\"id\""
                    ),
                    after: anchor,
                    limit: pageLimit + 1
                )
                .annotated(with: ArtistRecord.albums.count.forKey("albumCount"))
                .asRequest(of: ArtistWithAlbumCount.self)
                .fetchAll(db)
            return makePage(from: rows, limit: pageLimit) {
                PageCursor(key: $0.artist.sortName, id: $0.artist.id ?? 0)
            }
        }
    }
}
