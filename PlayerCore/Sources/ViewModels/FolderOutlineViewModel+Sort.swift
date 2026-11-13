// FolderOutlineViewModel+Sort — which comparator the outline's subfolders use, and
// what a sort change costs.
//
// Split out of `FolderOutlineViewModel.swift` for SwiftLint's file budget, exactly
// as `FolderSidebarViewModel+Sort.swift` was split out of the sidebar tree — and
// with the same division of labour, for a reason that is specific to this screen:
// a subfolder row already carries the `newestDateAdded` the comparator needs, so
// re-ordering folders is pure in-memory work, while a file's order is the
// database's (`folderTrackOrder.position`, `sortTitle`, `dateAdded` — all resolved
// inside one keyset key) and can only change by re-paging.
import Foundation
import Models
import Persistence

extension FolderOutlineViewModel {
    /// The comparator ``filesSort`` implies for SUBFOLDERS.
    ///
    /// ``FolderFilesSort/manual`` is a FILE order — `folderTrackOrder` positions key
    /// on tracks, and a folder has no position of its own — so under it subfolders
    /// keep the name-ascending order `childFolders` already returns, which is why
    /// the default ordering is unchanged from before sorting existed.
    var subfolderSort: FolderSort {
        switch filesSort {
        case .manual: .default
        case let .sorted(sort): sort
        }
    }

    func sortedSubfolders(_ level: [FolderChildSummary]) -> [FolderChildSummary] {
        Self.sortedSubfolders(level, by: subfolderSort)
    }

    static func sortedSubfolders(
        _ level: [FolderChildSummary],
        by sort: FolderSort
    ) -> [FolderChildSummary] {
        level.sorted {
            FolderSort.compare(
                (name: $0.name, newestDateAdded: $0.newestDateAdded),
                (name: $1.name, newestDateAdded: $1.newestDateAdded),
                by: sort
            )
        }
    }

    /// Re-orders the whole outline after ``filesSort`` changed.
    ///
    /// Subfolders are re-sorted IN PLACE and issue no query. Files are re-paged,
    /// because a keyset window ordered by the old key cannot be reinterpreted under
    /// the new one — its cursor names a row in a sequence that no longer exists.
    ///
    /// Expansion is cleared deliberately. Only the browsed root is re-paged, so a
    /// level left open would draw its folder row expanded above zero files; and the
    /// rows it held have moved elsewhere in the outline anyway. Re-expanding loads
    /// that level again under the new sort.
    func reloadForSort() async {
        expandedPaths.removeAll()
        var reordered: [String: FolderOutlineLevel] = [:]
        for (path, level) in levels {
            var reset = FolderOutlineLevel()
            reset.subfolders = sortedSubfolders(level.subfolders)
            reordered[path] = reset
        }
        levels = reordered
        rebuildRows()
        await reloadRootFiles()
        await fillRootViewport()
        rebuildRows()
    }

    private func reloadRootFiles() async {
        let page = await fetchFiles(in: rootPath, after: nil)
        var level = levels[rootPath] ?? FolderOutlineLevel()
        level.files = page.items
        level.cursor = page.nextCursor
        level.hasMore = page.nextCursor != nil
        level.isLoading = false
        level.isLoaded = true
        levels[rootPath] = level
    }
}
