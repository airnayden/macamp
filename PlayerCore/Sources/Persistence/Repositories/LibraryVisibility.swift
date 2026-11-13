import GRDB

/// Builds the "visible to profile *P*" `WHERE` fragment for a track's `filePath`.
///
/// A track is visible to a profile when its file lives under one of **that
/// profile's** `libraryRoot` paths, **OR** under **no** configured root at all
/// (an "ownerless" / loose-imported file stays visible to every profile so
/// nothing seems to disappear). The second clause is a *global* check across
/// **every** `libraryRoot` row — not just the active profile's — so a file
/// dropped outside all configured roots anywhere remains visible.
///
/// Both clauses test the **same** prefix predicate against the same root paths,
/// so the "owned by this profile" and "owned by no one" branches can never
/// disagree about whether a given root contains a track.
///
/// The root set is small (a handful of folders across a few profiles), so the
/// fragment is an OR-chain of **bound** `filePath LIKE ? ESCAPE '\'` prefix
/// patterns — each able to seek the v10 `filePath COLLATE NOCASE` index — rather
/// than a correlated subquery over `libraryRoot` (whose pattern prefix would be a
/// column value, defeating the index). The patterns come from
/// ``TrackRepository/likePrefixPattern(forRoot:)`` so trailing-slash
/// normalisation and `LIKE` metacharacter escaping match the folder queries.
/// It is `public` so sibling modules that own their own table (currently
/// `Lyrics`, whose lyrics-browse query joins `lyricsCache` to `track`) can apply
/// the **same** predicate instance rather than re-deriving an equivalent one — a
/// second copy of this rule would be free to drift out of agreement with the
/// browse queries about what a profile can see.
public enum LibraryVisibility {
    /// A compiled visibility predicate: a `WHERE` fragment and its bound arguments.
    public struct Predicate {
        /// A parenthesised boolean SQL fragment (e.g. `"1"` when everything is
        /// visible), safe to `AND`/`OR` into a larger clause.
        public let sql: String
        /// The bound `LIKE` patterns, in the order the `?` placeholders appear.
        public let arguments: [any DatabaseValueConvertible]
    }

    /// The "visible to `profileId`" predicate over `column` — a trusted `filePath`
    /// SQL expression (`"filePath"`, `"track.filePath"`, `"vt.filePath"`, …), never
    /// user input.
    ///
    /// Returns `Predicate(sql: "1", …)` — everything visible — when no roots are
    /// configured anywhere (every track is ownerless).
    public static func predicate(
        _ db: Database,
        profileId: Int64,
        column: String = "filePath"
    ) throws -> Predicate {
        let rows = try Row.fetchAll(db, sql: "SELECT profileId, path FROM libraryRoot")
        var activePatterns: [String] = []
        var allPatterns: [String] = []
        for row in rows {
            let ownerID: Int64 = row["profileId"]
            let path: String = row["path"]
            let pattern = TrackRepository.likePrefixPattern(forRoot: path)
            allPatterns.append(pattern)
            if ownerID == profileId {
                activePatterns.append(pattern)
            }
        }
        guard !allPatterns.isEmpty else { return Predicate(sql: "1", arguments: []) }

        var clauses: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if !activePatterns.isEmpty {
            clauses.append("(\(orChain(column, count: activePatterns.count)))")
            arguments.append(contentsOf: activePatterns)
        }
        // Ownerless: the file is under NONE of the configured roots (any profile's).
        clauses.append("NOT (\(orChain(column, count: allPatterns.count)))")
        arguments.append(contentsOf: allPatterns)
        return Predicate(sql: "(\(clauses.joined(separator: " OR ")))", arguments: arguments)
    }

    /// `<column> LIKE ? ESCAPE '\' OR …` repeated `count` times.
    private static func orChain(_ column: String, count: Int) -> String {
        Array(repeating: "\(column) LIKE ? ESCAPE '\\'", count: count)
            .joined(separator: " OR ")
    }
}
