// FolderSidebarViewModel+Sort — ordering one level of the folder tree, and
// re-ordering every already-loaded level when the sort changes.
//
// Split out of `FolderSidebarViewModel.swift` for its SwiftLint file budget, the
// same reason `+Tree.swift` exists. Reordering writes `nodes`, which is therefore
// `internal(set)` rather than `private(set)` in the primary declaration.
//
// ``resort()`` NEVER re-queries: `childrenCache` already holds every materialized
// level with its `newestDateAdded`, so a sort change is pure in-memory work and
// costs no `childFolders` call. A call-counting fake locks that.
import Foundation
import Models

extension FolderSidebarViewModel {
    /// Orders one level of folder nodes under the active ``sort``.
    func sorted(_ level: [FolderSidebarNode]) -> [FolderSidebarNode] {
        Self.sorted(level, by: sort)
    }

    /// The pure spelling, so a caller can order a level against an explicit sort.
    static func sorted(_ level: [FolderSidebarNode], by sort: FolderSort) -> [FolderSidebarNode] {
        level.sorted { FolderSort.compare($0.sortFields, $1.sortFields, by: sort) }
    }

    /// Re-orders the roots and every cached child level in place, then republishes
    /// the flattened render list.
    func resort() {
        nodes = sorted(nodes)
        for (parent, level) in childrenCache {
            childrenCache[parent] = sorted(level)
        }
        rebuildVisibleNodes()
    }
}
