import Foundation
import GRDB

/// The direction of a windowed/keyset-paginated query.
public enum SortDirection: String, Sendable, CaseIterable {
    case ascending
    case descending
}

/// The sort that drives a keyset window: a SQL sort-key expression, the `id`
/// tie-breaker column, and a direction.
///
/// `keyExpressionSQL` and `idColumnSQL` are trusted, compile-time constants (a
/// column name, a `COALESCE(...)` over one, or a table-qualified column) — never
/// user input — so embedding them in the keyset fragment is injection-safe.
/// Joined queries (e.g. `annotated(with:)`) must use a table-qualified
/// `idColumnSQL` such as `"album"."id"` so `id` is unambiguous.
struct KeysetSort {
    let keyExpressionSQL: String
    let idColumnSQL: String
    let direction: SortDirection

    init(
        keyExpressionSQL: String,
        idColumnSQL: String = "\"id\"",
        direction: SortDirection = .ascending
    ) {
        self.keyExpressionSQL = keyExpressionSQL
        self.idColumnSQL = idColumnSQL
        self.direction = direction
    }
}

/// An opaque keyset-pagination cursor: the `(sortKey, id)` of the last row of a page.
///
/// Keyset (a.k.a. "seek") pagination resumes from this anchor with
/// `WHERE (sortKey, id) > (?, ?)`, which is stable and non-overlapping even when
/// rows are inserted or deleted between page fetches — unlike `OFFSET`, whose
/// pages drift. `id` (the primary key) is the tie-breaker that makes the order total.
public struct PageCursor<Key: DatabaseValueConvertible & Sendable>: Sendable {
    public let key: Key
    public let id: Int64

    public init(key: Key, id: Int64) {
        self.key = key
        self.id = id
    }
}

/// One windowed page of results plus the cursor that resumes the next page.
///
/// `nextCursor` is `nil` exactly when the page is the last one.
public struct Page<Element: Sendable, Key: DatabaseValueConvertible & Sendable>: Sendable {
    public let items: [Element]
    public let nextCursor: PageCursor<Key>?

    public var hasMore: Bool {
        nextCursor != nil
    }

    public init(items: [Element], nextCursor: PageCursor<Key>?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// Assembles a `Page` from a result set that was over-fetched by one row.
///
/// Callers fetch `limit + 1` rows; if the extra row is present there is another
/// page, so the surplus row is dropped and a cursor is derived from the last
/// kept row. This yields a definitive `hasMore` without a trailing empty page.
func makePage<Element: Sendable, Key: DatabaseValueConvertible & Sendable>(
    from overFetched: [Element],
    limit: Int,
    cursorForLast: (Element) -> PageCursor<Key>
) -> Page<Element, Key> {
    guard limit > 0, overFetched.count > limit else {
        return Page(items: overFetched, nextCursor: nil)
    }
    let items = Array(overFetched.prefix(limit))
    guard let last = items.last else {
        return Page(items: items, nextCursor: nil)
    }
    return Page(items: items, nextCursor: cursorForLast(last))
}

extension QueryInterfaceRequest {
    /// Applies a keyset-pagination window:
    /// `[WHERE (keyExpr, id) >|< (?, ?)] ORDER BY keyExpr [DESC], id [DESC] LIMIT n`.
    ///
    /// The cursor *values* are always bound (never interpolated); the SQL fragments
    /// come only from the trusted ``KeysetSort``. A `COALESCE` over nullable sort
    /// columns keeps the order total so the keyset never breaks across a `NULL`.
    func keyset(
        _ sort: KeysetSort,
        after cursor: (key: any DatabaseValueConvertible, id: Int64)?,
        limit: Int
    ) -> Self {
        let order = sort.direction == .ascending ? "ASC" : "DESC"
        let comparison = sort.direction == .ascending ? ">" : "<"
        var request = self
        if let cursor {
            request = request.filter(
                sql: "(\(sort.keyExpressionSQL), \(sort.idColumnSQL)) \(comparison) (?, ?)",
                arguments: [cursor.key, cursor.id]
            )
        }
        return request
            .order(sql: "\(sort.keyExpressionSQL) \(order), \(sort.idColumnSQL) \(order)")
            .limit(limit)
    }
}

extension QueryInterfaceRequest where RowDecoder: FetchableRecord & Sendable {
    /// Fetches one keyset page of records and packages it with its next-page cursor.
    func fetchPage<Key: DatabaseValueConvertible & Sendable>(
        _ db: Database,
        sort: KeysetSort,
        after cursor: PageCursor<Key>?,
        limit: Int,
        cursorForLast: (RowDecoder) -> PageCursor<Key>
    ) throws -> Page<RowDecoder, Key> {
        let pageLimit = max(1, limit)
        let anchor = cursor.map { (key: $0.key as any DatabaseValueConvertible, id: $0.id) }
        let overFetched = try keyset(sort, after: anchor, limit: pageLimit + 1).fetchAll(db)
        return makePage(from: overFetched, limit: pageLimit, cursorForLast: cursorForLast)
    }
}
