import Foundation
import GRDB
import Lyrics
import Persistence

// LyricsBrowseRepository — the keyset window over "tracks whose lyrics are
// already in the database", backing the Lyrics sidebar browser.
//
// It lives in `Lyrics` rather than `Persistence` because a row's `isSynced` flag
// is derived from the cached ``Lyrics`` document itself: `Persistence` cannot
// import `Lyrics` (that is the dependency direction), so hosting the query here
// keeps ``Lyrics/isSynced`` the single definition of "synced" instead of
// re-encoding the payload schema in a second module.
//
// The query is READ-ONLY: it never resolves, fetches, or writes lyrics.
//
// This file MUST NOT import AppKit or UIKit (PlayerCore portability invariant).

/// One row of the lyrics browser: a track that already has cached lyrics.
///
/// Deliberately narrower than ``TrackRecord`` — it carries what the browser list
/// renders plus what a preview/playback request is built from (``filePath``,
/// ``duration``), so the list never holds whole track rows.
public struct LyricsRowDTO: Sendable, Equatable, Hashable, Identifiable {
    /// The backing `track.id`.
    public var trackId: Int64
    /// Absolute file path — also the `lyricsCache.cacheKey` these lyrics are under.
    public var filePath: String
    /// Display title, if the track has one.
    public var title: String?
    /// Display artist, if the track has one.
    public var artist: String?
    /// Duration in seconds, if known.
    public var duration: TimeInterval?
    /// Whether the cached document carries timestamps (drives the synced badge).
    public var isSynced: Bool

    public var id: Int64 {
        trackId
    }

    public init(
        trackId: Int64,
        filePath: String,
        title: String? = nil,
        artist: String? = nil,
        duration: TimeInterval? = nil,
        isSynced: Bool = false
    ) {
        self.trackId = trackId
        self.filePath = filePath
        self.title = title
        self.artist = artist
        self.duration = duration
        self.isSynced = isSynced
    }
}

/// The bounded read seam the lyrics browser pages through.
///
/// Both members are profile-scoped: the browser shows only tracks visible to the
/// active profile, exactly as the library browse queries do.
public protocol LyricsBrowsing: Sendable {
    /// One keyset page of the profile's present tracks that have cached lyrics,
    /// ordered by `(sortTitle, id)`. Resume with the returned cursor; a `nil`
    /// cursor means the page was the last one.
    func tracksWithLyrics(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<LyricsRowDTO, String>

    /// How many tracks the profile's browse list holds in total — the empty-state
    /// signal. An aggregate, never a row fetch.
    func tracksWithLyricsCount(profileId: Int64) throws -> Int
}

/// The GRDB-backed ``LyricsBrowsing`` over the `track` ⋈ `lyricsCache` join.
public struct LyricsBrowseRepository: LyricsBrowsing {
    private let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) {
        self.writer = writer
    }

    public init(_ appDatabase: AppDatabase) {
        writer = appDatabase.writer
    }

    public func tracksWithLyrics(
        profileId: Int64 = ProfileRecord.guestID,
        after cursor: PageCursor<String>? = nil,
        limit: Int = 100
    ) throws -> Page<LyricsRowDTO, String> {
        let pageLimit = max(1, limit)
        return try writer.read { db in
            let query = try lyricsBrowseQuery(db, profileId: profileId)
            var sql = "SELECT \(lyricsBrowseSelectList)\n\(query.sql)"
            var arguments = query.arguments
            if let cursor {
                sql += "\n  AND (\(lyricsBrowseSortKeySQL), track.id) > (?, ?)"
                arguments.append(cursor.key)
                arguments.append(cursor.id)
            }
            sql += "\nORDER BY \(lyricsBrowseSortKeySQL) ASC, track.id ASC\nLIMIT ?"
            arguments.append(pageLimit + 1)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return makeLyricsPage(from: rows.map(decodeLyricsBrowseRow), limit: pageLimit)
        }
    }

    public func tracksWithLyricsCount(profileId: Int64 = ProfileRecord.guestID) throws -> Int {
        try writer.read { db in
            let query = try lyricsBrowseQuery(db, profileId: profileId)
            let sql = "SELECT COUNT(*)\n\(query.sql)"
            return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(query.arguments)) ?? 0
        }
    }
}

/// A row paired with the `sortTitle` its cursor must be built from.
///
/// The cursor key has to be the **stored** `track.sortTitle` the `ORDER BY` uses;
/// re-deriving it from ``LyricsRowDTO/title`` would drift wherever the scanner's
/// sort key differs from the display title, silently skipping or repeating rows
/// across pages. So the sort key travels beside the DTO instead of inside it.
private struct LyricsBrowseRow {
    let dto: LyricsRowDTO
    let sortKey: String
}

private let lyricsBrowseSelectList = """
track.id AS trackId, track.filePath AS filePath, track.title AS title, \
track.artistName AS artistName, track.duration AS duration, \
COALESCE(track.sortTitle, '') AS sortKey, lc.payloadJson AS payloadJson
"""

/// `COALESCE` keeps the keyset total across `NULL` sort titles, matching
/// ``TrackRepository``'s `(sortTitle, id)` browse ordering.
private let lyricsBrowseSortKeySQL = "COALESCE(track.sortTitle, '')"

/// The `FROM … WHERE …` shared by the page and the count, plus its bound
/// arguments in placeholder order.
///
/// The `JOIN` expresses exactly the `EXISTS (SELECT 1 FROM lyricsCache WHERE
/// cacheKey = track.filePath AND source != 'none')` predicate: `cacheKey` is
/// `UNIQUE`, so at most one row can match and the join cannot multiply track
/// rows. It is written as a join because the page also needs that row's
/// `payloadJson`, which `EXISTS` would cost a second index seek per row to get.
private func lyricsBrowseQuery(
    _ db: Database,
    profileId: Int64
) throws -> (sql: String, arguments: [any DatabaseValueConvertible]) {
    let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "track.filePath")
    let sql = """
    FROM track
    JOIN lyricsCache lc ON lc.cacheKey = track.filePath
    WHERE track.availability = ?
      AND lc.source <> ?
      AND \(visibility.sql)
    """
    var arguments: [any DatabaseValueConvertible] = [
        Availability.present.rawValue,
        LyricsCacheSentinel.source,
    ]
    arguments.append(contentsOf: visibility.arguments)
    return (sql, arguments)
}

private func decodeLyricsBrowseRow(_ row: Row) -> LyricsBrowseRow {
    LyricsBrowseRow(
        dto: LyricsRowDTO(
            trackId: row["trackId"],
            filePath: row["filePath"],
            title: row["title"],
            artist: row["artistName"],
            duration: row["duration"],
            isSynced: lyricsPayloadIsSynced(row["payloadJson"])
        ),
        sortKey: row["sortKey"]
    )
}

/// A row whose payload will not decode still belongs in the list — the cache says
/// the track has lyrics — so a bad payload degrades to "not synced" rather than
/// dropping the track from the browser.
private func lyricsPayloadIsSynced(_ payloadJson: String?) -> Bool {
    guard let data = payloadJson?.data(using: .utf8),
          let lyrics = try? JSONDecoder().decode(Lyrics.self, from: data)
    else { return false }
    return lyrics.isSynced
}

/// Drops the over-fetched row and derives the resume cursor from the last kept
/// row, mirroring `Persistence`'s `makePage` (which is module-internal).
private func makeLyricsPage(from overFetched: [LyricsBrowseRow], limit: Int) -> Page<LyricsRowDTO, String> {
    guard overFetched.count > limit else {
        return Page(items: overFetched.map(\.dto), nextCursor: nil)
    }
    let kept = Array(overFetched.prefix(limit))
    guard let last = kept.last else { return Page(items: kept.map(\.dto), nextCursor: nil) }
    return Page(
        items: kept.map(\.dto),
        nextCursor: PageCursor(key: last.sortKey, id: last.dto.trackId)
    )
}

/// An in-memory ``LyricsBrowsing`` returning a fixed row set — the test double.
///
/// It applies the same `(sortKey, id)` keyset window as the GRDB conformer, using
/// the lowercased title as its sort key (the convention test fixtures seed
/// `track.sortTitle` with), so view-model paging is exercised without a database.
public final class FakeLyricsBrowser: LyricsBrowsing, @unchecked Sendable {
    private let lock = NSLock()
    private var rowsByProfile: [Int64: [LyricsRowDTO]]

    public init(rowsByProfile: [Int64: [LyricsRowDTO]] = [:]) {
        self.rowsByProfile = rowsByProfile
    }

    public convenience init(rows: [LyricsRowDTO], profileId: Int64 = ProfileRecord.guestID) {
        self.init(rowsByProfile: [profileId: rows])
    }

    public func setRows(_ rows: [LyricsRowDTO], profileId: Int64 = ProfileRecord.guestID) {
        lock.withLock { rowsByProfile[profileId] = rows }
    }

    public func tracksWithLyrics(
        profileId: Int64,
        after cursor: PageCursor<String>?,
        limit: Int
    ) throws -> Page<LyricsRowDTO, String> {
        let pageLimit = max(1, limit)
        let ordered = lock.withLock { rowsByProfile[profileId] ?? [] }
            .map { LyricsBrowseRow(dto: $0, sortKey: ($0.title ?? "").lowercased()) }
            .sorted { ($0.sortKey, $0.dto.trackId) < ($1.sortKey, $1.dto.trackId) }
        let remaining = ordered.drop { row in
            guard let cursor else { return false }
            return (row.sortKey, row.dto.trackId) <= (cursor.key, cursor.id)
        }
        return makeLyricsPage(from: Array(remaining.prefix(pageLimit + 1)), limit: pageLimit)
    }

    public func tracksWithLyricsCount(profileId: Int64) throws -> Int {
        lock.withLock { rowsByProfile[profileId]?.count ?? 0 }
    }
}
