// The sort keys behind ``TrackRepository/tracksDirectlyIn(profileId:dirPath:after:limit:sort:)``.
//
// A folder's direct files page by a `PageCursor<String>`, so every ordering the
// browser offers has to collapse into ONE lexicographically monotone `String` —
// the same expression the page selects, orders by, and resumes from. That is why
// the date ordering is a composed string rather than a numeric column: a cursor
// cannot carry two keys, and ordering by one expression while resuming from
// another is exactly what skips and duplicates rows.
//
// Its own file rather than more of `TrackRepository+Folders.swift`, which is
// already near SwiftLint's 400-line ceiling.
import GRDB
import Models

/// How one page of a folder's direct files is ordered.
struct FolderFilesKeyset {
    /// The expression selected as ``TrackRepository/folderTreeOrderKeyColumn``,
    /// ordered by, and compared against the cursor — one expression for all three.
    let keySQL: String
    let direction: SortDirection

    /// The keyset comparison against `(key, track.id)`.
    var comparison: String {
        direction == .ascending ? ">" : "<"
    }

    /// The suffix every `ORDER BY` term carries. Empty when ascending, so the
    /// manual order's statement stays byte-identical to the one that shipped
    /// before sorting existed.
    var orderSuffix: String {
        direction == .ascending ? "" : " DESC"
    }
}

extension TrackRepository {
    /// The key and direction a folder's direct files page by under `sort`.
    static func folderFilesKeyset(for sort: FolderFilesSort) -> FolderFilesKeyset {
        switch sort {
        case .manual:
            FolderFilesKeyset(keySQL: folderTreeOrderKeySQL, direction: .ascending)
        case let .sorted(folderSort):
            FolderFilesKeyset(
                keySQL: sortedFolderFilesKeySQL(folderSort),
                direction: folderSort.direction == .ascending ? .ascending : .descending
            )
        }
    }

    /// The `String` a keyset cursor carries for `track` under `sort` — the Swift
    /// mirror of the SQL key the page selects as ``folderTreeOrderKeyColumn``.
    ///
    /// Paging never needs this: ``tracksDirectlyIn(profileId:dirPath:after:limit:sort:)``
    /// reads the key back out of the very row it ordered by. It exists so a caller
    /// re-anchoring a window it mutated locally — and the query tests that lock the
    /// two sides together — can produce the string the database would.
    ///
    /// ``FolderFilesSort/manual`` is mirrored at its UN-POSITIONED key. A row the
    /// profile dragged carries a `folderTrackOrder.position` that lives in a joined
    /// table no `TrackRecord` can see; `FolderOutlineViewModel.orderKey(position:sortTitle:)`
    /// is the mirror for those.
    ///
    /// `public` so a test double standing in for this repository can order its rows
    /// by the very key the database would, rather than by a second comparator that
    /// could drift from it silently.
    public static func sortCursorKey(for track: TrackRecord, sort: FolderFilesSort) -> String {
        switch sort {
        case .manual:
            String(format: "%020lld", unpositionedFolderOrderKey) + (track.sortTitle ?? "")
        case let .sorted(folderSort):
            sortedCursorKey(for: track, sort: folderSort)
        }
    }
}

private extension TrackRepository {
    static func sortedFolderFilesKeySQL(_ sort: FolderSort) -> String {
        switch sort.key {
        case .name:
            // `sortTitle` is `Metadata.SortKey`'s NFC/transliterated/case-folded
            // output, which is the closest SQL has to the `localizedStandardCompare`
            // the in-memory folder comparator uses. The two order different things
            // (folder names vs track sort titles) and are not required to agree.
            "COALESCE(track.sortTitle, '')"
        case .dateAdded:
            dateAddedKeySQL(direction: sort.direction)
        }
    }

    /// A zero-padded `dateAdded` behind a one-character bucket prefix, so `NULL`
    /// lands LAST in BOTH directions — the epic's single nil policy, matching
    /// ``FolderSort/compare(_:_:by:)``.
    ///
    /// Ascending buckets values under `'0'` and `NULL` under `'9'`; descending
    /// buckets values under `'1'` and `NULL` under `'0'`, so each direction's own
    /// `ORDER BY` parks the undated rows at its tail.
    ///
    /// **Assumes `track.dateAdded` is a non-negative Unix timestamp.** Integer
    /// padding is what makes the concatenation lexicographically monotone;
    /// `printf('%f', …)` would not be (a sign or a shorter mantissa reorders the
    /// string), and a negative seconds value would sort above every positive one.
    static func dateAddedKeySQL(direction: FolderSortDirection) -> String {
        let valuePrefix = direction == .ascending ? "0" : "1"
        let nullPrefix = direction == .ascending ? "9" : "0"
        return "CASE WHEN track.dateAdded IS NULL THEN '\(nullPrefix)' ELSE '\(valuePrefix)' END"
            + " || printf('%016d', CAST(COALESCE(track.dateAdded, 0) AS INTEGER))"
    }

    static func sortedCursorKey(for track: TrackRecord, sort: FolderSort) -> String {
        switch sort.key {
        case .name:
            track.sortTitle ?? ""
        case .dateAdded:
            dateAddedCursorKey(track.dateAdded, direction: sort.direction)
        }
    }

    /// The Swift mirror of ``dateAddedKeySQL(direction:)``. `CAST(… AS INTEGER)`
    /// truncates toward zero, which is what `rounded(.towardZero)` reproduces.
    static func dateAddedCursorKey(_ dateAdded: Double?, direction: FolderSortDirection) -> String {
        let prefix: String = if dateAdded == nil {
            direction == .ascending ? "9" : "0"
        } else {
            direction == .ascending ? "0" : "1"
        }
        let seconds = Int64(exactly: (dateAdded ?? 0).rounded(.towardZero)) ?? 0
        return prefix + String(format: "%016lld", seconds)
    }
}
