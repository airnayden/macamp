import Foundation
import GRDB

/// Off-actor, windowed access to the v17 `downloadHistory` log.
///
/// Reads are keyset-paginated and `LIMIT`-capped and the batch lookup is a single
/// bounded `IN (…)`, so a listener with years of downloads never materialises more
/// than one page at a time — the library-memory invariant applies to history too.
///
/// Nothing here touches the filesystem. ``delete(id:)`` and ``deleteAll()`` remove
/// **rows**; the downloaded files they name are the listener's and are never opened,
/// moved or deleted by this type.
public protocol DownloadHistoryRepositoryProviding: Sendable {
    /// Appends one finished download.
    func insert(_ entry: DownloadHistoryRecord) async throws

    /// One page of history, newest first.
    ///
    /// - Parameter cursor: The anchor returned by the previous page; `nil` starts at
    ///   the newest entry. The cursor is opaque — see the implementation note on why
    ///   its integer half is the rowid rather than the TEXT primary key.
    func entries(
        before cursor: PageCursor<Double>?,
        limit: Int
    ) async throws -> Page<DownloadHistoryRecord, Double>

    /// Removes one entry, returning whether a row actually matched. The file the row
    /// named is left untouched.
    @discardableResult
    func delete(id: String) async throws -> Bool

    /// Removes every entry, returning how many rows went. No file is touched.
    @discardableResult
    func deleteAll() async throws -> Int

    /// The most recent entry for a video, or `nil` when it has never been downloaded.
    ///
    /// Newest wins: re-downloading a video appends a row rather than replacing one,
    /// so this is the answer to "when did I last take this".
    func latestEntry(canonicalVideoID: String) async throws -> DownloadHistoryRecord?

    /// Which of `ids` have EVER been downloaded, resolved in ONE statement.
    ///
    /// Advisory only — the caller uses it to say "you have had some of these before",
    /// never to skip work. At most ``DownloadHistoryRepository/videoIDLookupLimit``
    /// distinct ids are looked up, in caller order.
    func knownVideoIDs(in ids: [String]) async throws -> Set<String>
}

/// The concrete ``DownloadHistoryRepositoryProviding`` over a GRDB writer.
///
/// Uses GRDB's async reader/writer overloads throughout so a main-actor caller never
/// blocks on a database connection.
public struct DownloadHistoryRepository: DownloadHistoryRepositoryProviding {
    /// The hard ceiling on any single page, applied even when a caller asks for more.
    public static let fetchLimit = 500

    /// The hard ceiling on one ``knownVideoIDs(in:)`` batch.
    ///
    /// The whole point of that method is that it costs exactly one statement, so the
    /// bound exists to keep a single `IN (…)` list well inside SQLite's bound-variable
    /// ceiling rather than to page. Callers hand over far fewer (the paste hint asks
    /// about 50).
    public static let videoIDLookupLimit = 500

    /// The keyset window: newest first, tie-broken on the implicit rowid.
    ///
    /// **The tie-breaker is `rowid`, NOT the TEXT `id`, and that is load-bearing.**
    /// ``Pagination`` binds a cursor's second component as an `Int64`, and SQLite
    /// orders every INTEGER before every TEXT regardless of content — so binding an
    /// integer against the TEXT primary key would make the tuple comparison
    /// `(downloadedAt, id) < (?, ?)` answer on the timestamp alone and silently
    /// return a wrong page whenever two entries share one. The implicit rowid is an
    /// INTEGER, is assigned in insert order (so it tie-breaks newest-first correctly),
    /// and is never renumbered — nothing in this app runs `VACUUM`. It stays inside
    /// the opaque ``PageCursor`` and is never part of the public row shape.
    private static let keysetSort = KeysetSort(
        keyExpressionSQL: "\"downloadedAt\"",
        idColumnSQL: "\"rowid\"",
        direction: .descending
    )

    private let dbWriter: any DatabaseWriter

    public init(_ appDatabase: AppDatabase) {
        dbWriter = appDatabase.writer
    }

    public init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public func insert(_ entry: DownloadHistoryRecord) async throws {
        try await dbWriter.write { db in
            try entry.insert(db)
        }
    }

    public func entries(
        before cursor: PageCursor<Double>? = nil,
        limit: Int = DownloadHistoryRepository.fetchLimit
    ) async throws -> Page<DownloadHistoryRecord, Double> {
        let capped = min(max(1, limit), Self.fetchLimit)
        let windowed = try await dbWriter.read { db in
            // Built inside the read: the erased tuple `keyset` takes is not `Sendable`,
            // whereas the `PageCursor` it is derived from is.
            let anchor = cursor.map { (key: $0.key as any DatabaseValueConvertible, id: $0.id) }
            return try DownloadHistoryRecord
                .select(AllColumns(), Column.rowID)
                .keyset(Self.keysetSort, after: anchor, limit: capped + 1)
                .asRequest(of: DownloadHistoryPageRow.self)
                .fetchAll(db)
        }
        let page = makePage(from: windowed, limit: capped) {
            PageCursor(key: $0.record.downloadedAt, id: $0.rowID)
        }
        return Page(items: page.items.map(\.record), nextCursor: page.nextCursor)
    }

    @discardableResult
    public func delete(id: String) async throws -> Bool {
        try await dbWriter.write { db in
            try DownloadHistoryRecord.deleteOne(db, key: id)
        }
    }

    @discardableResult
    public func deleteAll() async throws -> Int {
        try await dbWriter.write { db in
            try DownloadHistoryRecord.deleteAll(db)
        }
    }

    public func latestEntry(canonicalVideoID: String) async throws -> DownloadHistoryRecord? {
        try await dbWriter.read { db in
            try DownloadHistoryRecord
                .filter(DownloadHistoryRecord.Columns.canonicalVideoID == canonicalVideoID)
                .filter(DownloadHistoryRecord.Columns.failureReason == nil)
                .order(DownloadHistoryRecord.Columns.downloadedAt.desc, Column.rowID.desc)
                .fetchOne(db)
        }
    }

    /// One `SELECT DISTINCT … IN (…)`, never a lookup per id.
    ///
    /// The list is deduplicated in caller order before it is bound, so both the
    /// statement's size and — when a caller exceeds the ceiling — *which* ids are
    /// asked about are deterministic.
    public func knownVideoIDs(in ids: [String]) async throws -> Set<String> {
        let wanted = Self.boundedDistinct(ids)
        guard !wanted.isEmpty else { return [] }
        return try await dbWriter.read { db in
            let sql = """
            SELECT DISTINCT canonicalVideoID
            FROM \(DownloadHistoryRecord.databaseTableName)
            WHERE failureReason IS NULL AND canonicalVideoID IN (\(databaseQuestionMarks(count: wanted.count)))
            """
            return try Set(String.fetchAll(db, sql: sql, arguments: StatementArguments(wanted)))
        }
    }
}

// MARK: - Internals

private extension DownloadHistoryRepository {
    /// The first ``videoIDLookupLimit`` distinct ids, in the order the caller listed
    /// them. `Set(ids).prefix(n)` would drop an arbitrary subset instead.
    static func boundedDistinct(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var kept: [String] = []
        kept.reserveCapacity(min(ids.count, videoIDLookupLimit))
        for id in ids where seen.insert(id).inserted {
            kept.append(id)
            if kept.count == videoIDLookupLimit { break }
        }
        return kept
    }
}

/// A fetched history row carrying the rowid its keyset page tie-breaks on.
///
/// The rowid is not part of ``DownloadHistoryRecord`` — putting it there would make
/// every insert try to write it — so the paged read selects it alongside and drops it
/// again once the cursor is built.
private struct DownloadHistoryPageRow: FetchableRecord {
    let record: DownloadHistoryRecord
    let rowID: Int64

    init(row: Row) throws {
        record = try DownloadHistoryRecord(row: row)
        rowID = row["rowid"]
    }
}
