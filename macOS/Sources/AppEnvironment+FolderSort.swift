// AppEnvironment+FolderSort — pushing the persisted folder sort into the sidebar's
// folder tree, and keeping it there.
//
// A file of its own rather than a few lines in `AppEnvironment+Composition.swift`
// (384/400) for that file's `swiftlint --strict` budget. The shape is
// `observeDownloadPreferences(settings:boxes:)`' verbatim: read inside
// `withObservationTracking`, hop to the main actor because `onChange` fires BEFORE
// the write lands, apply, then re-arm — so the Sort menu needs no `.onChange`.
//
// The push is one-directional: the MENU writes `AppSettings.folderSort`, and this is
// the only thing that writes `FolderSidebarViewModel.sort`. The view model's own
// setter is equality-guarded, so a settings change that leaves the tree sort alone
// (todo 7 rewrites `browser` through the same stored property) re-sorts nothing.
import Foundation
import Observation

public extension AppEnvironment {
    /// Applies the stored tree sort to the folder sidebar and re-applies it on change.
    func connectFolderSort(settings: AppSettings) {
        libraryFolders.sidebar.sort = settings.folderSort.tree
        observeFolderSort(settings: settings)
    }

    private func observeFolderSort(settings: AppSettings) {
        withObservationTracking {
            _ = settings.folderSort
        } onChange: { [weak self, weak settings] in
            Task { @MainActor in
                guard let self, let settings else { return }
                self.libraryFolders.sidebar.sort = settings.folderSort.tree
                self.observeFolderSort(settings: settings)
            }
        }
    }
}
