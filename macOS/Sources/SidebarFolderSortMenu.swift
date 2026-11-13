// SidebarFolderSortMenu — the icon-only Sort control in the Folders section header.
//
// Lives here rather than in `SidebarView.swift`, which sits close to SwiftLint's
// `file_length` budget; that file keeps only the header row that hosts it.
//
// The menu writes `AppSettings.folderSort.tree` and NOTHING else. The composition
// root's `connectFolderSort(settings:)` is the single writer of
// `FolderSidebarViewModel.sort`, so the order the tree renders in and the order that
// is remembered across launches can never disagree.
import DesignSystem
import Models
import SwiftUI

/// Orders the sidebar folder tree: Name or Date Added, ascending or descending.
struct SidebarFolderSortMenu: View {
    let settings: AppSettings

    var body: some View {
        Menu {
            Picker(selection: keyBinding) {
                Text(FolderSidebarStrings.sortByName).tag(FolderSortKey.name)
                Text(FolderSidebarStrings.sortByDateAdded).tag(FolderSortKey.dateAdded)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            Divider()
            Picker(selection: directionBinding) {
                Text(FolderSidebarStrings.sortAscending).tag(FolderSortDirection.ascending)
                Text(FolderSidebarStrings.sortDescending).tag(FolderSortDirection.descending)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandCursor()
        .help(Text(FolderSidebarStrings.sortMenu))
        .accessibilityLabel(Text(FolderSidebarStrings.sortMenu))
        .accessibilityIdentifier(Self.identifier)
    }

    static let identifier = "sidebar.folders.sort"

    private var keyBinding: Binding<FolderSortKey> {
        Binding(
            get: { settings.folderSort.tree.key },
            set: { settings.folderSort.tree.key = $0 }
        )
    }

    private var directionBinding: Binding<FolderSortDirection> {
        Binding(
            get: { settings.folderSort.tree.direction },
            set: { settings.folderSort.tree.direction = $0 }
        )
    }
}
