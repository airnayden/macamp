// FolderReorderPolicy — the two rules that make a folder selection behave
// differently from every other library-browse mode.
//
// Both rules are decided by the shell's browser view, which has no unit-test
// target, so they live here where `ViewModelTests` can pin them.
import Foundation
import Models

/// How the library browser treats a folder selection.
///
/// A folder is the only browse mode whose row order is *user-owned*: it comes from
/// the profile's `folderTrackOrder` rows rather than from a query's sort. That one
/// fact drives both rules below.
public enum FolderReorderPolicy {
    /// Whether a drag may reorder the current list.
    ///
    /// All-Tracks and genre-filtered windows are query-ordered and, in the genre
    /// case, show only a subset of the root — a drag there would persist positions
    /// that describe no folder's real order, so those drags must write nothing.
    /// A Name or Date-added sort closes the gate too: under those the row order
    /// comes from the query, so a drag would persist positions the next reload
    /// discards.
    public static func allowsReorder(
        filterRootPath: String?,
        isGenreFilterAll: Bool,
        filesSort: FolderFilesSort
    ) -> Bool {
        filterRootPath != nil && isGenreFilterAll && filesSort == .manual
    }

    /// The gate for a surface that has no sort control — manual order throughout.
    public static func allowsReorder(filterRootPath: String?, isGenreFilterAll: Bool) -> Bool {
        allowsReorder(filterRootPath: filterRootPath, isGenreFilterAll: isGenreFilterAll, filesSort: .manual)
    }

    /// Whether the table's column comparator may re-sort the loaded rows.
    ///
    /// In folder mode the database order *is* the answer, so re-sorting would
    /// silently discard the manual order the user just dragged. Every other mode
    /// keeps its column sorting.
    public static func appliesTableSort(filterRootPath: String?) -> Bool {
        filterRootPath == nil
    }
}
