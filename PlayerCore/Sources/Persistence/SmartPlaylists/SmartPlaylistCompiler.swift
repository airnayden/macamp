import Foundation
import GRDB

/// A rule set lowered to one bounded, fully-parameterised SQL statement.
///
/// Mirrors ``LibraryVisibility/Predicate``: a SQL string plus the values its `?`
/// placeholders bind, in order. No rule value is ever interpolated into the string —
/// rules can originate from the assistant or the user, so every literal travels as a
/// bound argument.
public struct CompiledSmartPlaylistQuery {
    /// The complete `SELECT track.id …` statement, including `ORDER BY` and `LIMIT`.
    public let sql: String
    /// The bound values, in the order the `?` placeholders appear.
    public let arguments: [any DatabaseValueConvertible]

    /// The statement as a fetchable request for track ids.
    public var request: SQLRequest<Int64> {
        SQLRequest(sql: sql, arguments: StatementArguments(arguments))
    }
}

/// Lowers a ``SmartPlaylistRules`` value into a bounded SQL query over the tracks a
/// profile can see.
///
/// The shape is fixed; only the `WHERE`, `ORDER BY` and `LIMIT` vary:
///
/// ```sql
/// SELECT track.id FROM track
/// LEFT JOIN profileTrackState AS pts ON pts.trackId = track.id AND pts.profileId = ?
/// LEFT JOIN trackAudioFeature  AS taf ON taf.trackId = track.id
/// WHERE <visibility> AND <predicates>
/// ORDER BY <sort>, track.id ASC
/// LIMIT ?
/// ```
///
/// Both joins are always present rather than emitted on demand. They are `LEFT` joins
/// onto each table's own integer primary key — an index seek per row — so the cost of
/// carrying an unused one is far below the cost of two divergent SQL shapes.
///
/// `<visibility>` is ``LibraryVisibility/predicate(_:profileId:column:)`` verbatim,
/// `AND`-composed at the top level so it can never be weakened by an `any`-mode rule
/// set: a profile's smart playlist sees exactly the tracks it could browse.
///
/// `LIMIT` is mandatory and comes from ``SmartPlaylistRules/effectiveLimit``, which is
/// clamped to ``SmartPlaylistRules/maximumLimit``. There is no code path that emits an
/// unbounded query.
public enum SmartPlaylistCompiler {
    /// SQL alias for this profile's `profileTrackState` rows.
    static let stateAlias = "pts"
    /// SQL alias for the `trackAudioFeature` row.
    static let featureAlias = "taf"

    /// Compiles `rules` into a query over the tracks visible to `profileId`.
    ///
    /// - Parameters:
    ///   - rules: The rule set to lower.
    ///   - profileId: The owning playlist's profile. Scopes visibility, the
    ///     `profileTrackState` join and every `playEvent` sub-query.
    ///   - now: The evaluation instant, from an injected clock — recency windows are
    ///     measured back from it so a test can place `now` on a boundary.
    ///   - db: Read connection, needed to resolve the profile's library roots.
    public static func compile(
        _ rules: SmartPlaylistRules,
        profileId: Int64,
        now: Date,
        in db: Database
    ) throws -> CompiledSmartPlaylistQuery {
        let visibility = try LibraryVisibility.predicate(db, profileId: profileId, column: "track.filePath")
        let predicates = compose(
            rules.predicates.map { clause(for: $0, profileId: profileId, now: now) },
            mode: rules.match
        )
        var arguments: [any DatabaseValueConvertible] = [profileId]
        arguments.append(contentsOf: visibility.arguments)
        arguments.append(contentsOf: predicates.arguments)
        arguments.append(rules.effectiveLimit)
        let sql = """
        SELECT track.id FROM track
        LEFT JOIN profileTrackState AS \(stateAlias) ON \(stateAlias).trackId = track.id \
        AND \(stateAlias).profileId = ?
        LEFT JOIN trackAudioFeature AS \(featureAlias) ON \(featureAlias).trackId = track.id
        WHERE \(visibility.sql) AND \(predicates.sql)
        ORDER BY \(orderSQL(rules.sort))
        LIMIT ?
        """
        return CompiledSmartPlaylistQuery(sql: sql, arguments: arguments)
    }

    /// Joins the per-predicate clauses with `AND` or `OR`.
    ///
    /// An empty rule set compiles to the tautology, so it materialises the whole
    /// visible library (bounded by `LIMIT`) under either mode rather than emptying
    /// the playlist under `any`.
    static func compose(_ clauses: [SmartPlaylistClause], mode: SmartPlaylistMatchMode) -> SmartPlaylistClause {
        guard !clauses.isEmpty else { return SmartPlaylistClause.unconstrained }
        let separator = mode == .all ? " AND " : " OR "
        return SmartPlaylistClause(
            sql: "(" + clauses.map(\.sql).joined(separator: separator) + ")",
            arguments: clauses.flatMap(\.arguments)
        )
    }

    /// `<expression> ASC|DESC, track.id ASC` — the trailing id makes ties, and
    /// therefore the materialised order, deterministic.
    static func orderSQL(_ sort: SmartPlaylistSort) -> String {
        let direction = sort.direction == .ascending ? "ASC" : "DESC"
        return "\(sortExpression(sort.field)) \(direction), track.id ASC"
    }

    static func sortExpression(_ field: SmartPlaylistSortField) -> String {
        switch field {
        case .title: "track.sortTitle"
        case .artistName: "track.artistName"
        case .albumTitle: "track.albumTitle"
        case .year: "track.year"
        case .duration: "track.duration"
        case .dateAdded: "track.dateAdded"
        case .playCount: "COALESCE(\(stateAlias).playCount, 0)"
        case .listenedCount: "COALESCE(\(stateAlias).listenedCount, 0)"
        }
    }
}
