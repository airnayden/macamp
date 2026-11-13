// FolderOutlineViewModel+Rows — the flattening pass that turns the per-level state
// into the rows the outline renders, and the per-level genre narrowing.
//
// A separate file from `FolderOutlineViewModel.swift` purely to keep both sources
// inside SwiftLint's file- and type-length budgets — the
// `FolderSidebarViewModel+Tree.swift` precedent.
import Foundation
import Persistence

public extension FolderOutlineViewModel {
    /// The whole outline in render order.
    ///
    /// The shell renders ``subtreeRows`` and ``rootFileRows`` as two `ForEach`es so
    /// only the second carries `.onMove`; this composition is the same list and is
    /// what the tests read.
    var rows: [FolderOutlineRow] {
        subtreeRows + rootFileRows.map(FolderOutlineRow.file)
    }

    /// The level a rendered file row belongs to — what a double-click needs in order
    /// to queue the clicked track's OWN folder rather than the whole subtree.
    func levelPath(forTrack trackId: Int64) -> String? {
        if let match = rootFileRows.first(where: { $0.trackId == trackId }) {
            return match.levelPath
        }
        for row in subtreeRows {
            guard case let .file(file) = row, file.trackId == trackId else { continue }
            return file.levelPath
        }
        return nil
    }

    /// The files of one level after the genre chip.
    ///
    /// Applied CLIENT-SIDE, over that level's LOADED pages only — see
    /// ``genreFilter``. A genre with no loaded match at this level yields `[]` even
    /// when an unfetched page holds one; the chip narrows what is on screen, it does
    /// not re-query the folder.
    func visibleFiles(in levelPath: String) -> [TrackRecord] {
        let files = levels[levelPath]?.files ?? []
        guard !genreFilter.isAll else { return files }
        return files.filter { matches(genreOf: $0) }
    }
}

extension FolderOutlineViewModel {
    /// Rebuilds both published row arrays from the current levels + expansion.
    ///
    /// Order within a level is subfolders first (each immediately followed by its
    /// own expanded contents), then that level's direct files — applied recursively,
    /// which is what makes the root's own files the contiguous trailing block.
    func rebuildRows() {
        var rows: [FolderOutlineRow] = []
        appendSubfolders(of: rootPath, depth: 0, into: &rows)
        subtreeRows = rows
        rootFileRows = fileRows(in: rootPath, depth: 0)
    }

    private func appendSubfolders(of path: String, depth: Int, into rows: inout [FolderOutlineRow]) {
        guard let level = levels[path] else { return }
        for child in level.subfolders {
            rows.append(.folder(FolderOutlineFolder(
                path: child.path,
                name: child.name,
                trackCount: child.trackCount,
                hasChildren: child.hasChildren,
                depth: depth,
                isExpanded: expandedPaths.contains(child.path)
            )))
            guard expandedPaths.contains(child.path) else { continue }
            appendSubfolders(of: child.path, depth: depth + 1, into: &rows)
            rows.append(contentsOf: fileRows(in: child.path, depth: depth + 1).map(FolderOutlineRow.file))
        }
    }

    private func fileRows(in levelPath: String, depth: Int) -> [FolderOutlineFile] {
        let files = visibleFiles(in: levelPath)
        return files.enumerated().map { index, track in
            FolderOutlineFile(
                track: track,
                levelPath: levelPath,
                depth: depth,
                indexInLevel: index,
                levelFileCount: files.count
            )
        }
    }

    private func matches(genreOf track: TrackRecord) -> Bool {
        switch genreFilter {
        case .all: true
        case .untagged: (track.genre ?? "").isEmpty
        case let .genre(name): track.genre == name
        }
    }
}
