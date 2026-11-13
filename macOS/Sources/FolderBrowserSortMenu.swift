// FolderBrowserSortMenu — the icon-only Sort control in the folder browser's
// header row, beside the genre chips.
//
// `SidebarFolderSortMenu`'s shape, with the one difference this surface has: a
// folder's direct FILES carry an order the listener owns (`folderTrackOrder`), so
// the key picker offers a third choice above Name and Date added — and the
// Ascending / Descending picker is DISABLED under it, because a hand-dragged order
// has no direction to run in.
//
// The menu writes `AppSettings.folderSort.browser` and NOTHING else. The browser
// reads that same property to build its outline and to decide whether a drag may
// write, so the order on screen and the order that is remembered cannot disagree.
import DesignSystem
import Models
import SwiftUI

/// The three orders the folder browser offers, flattened into one picker so the
/// menu reads as a single list of choices rather than a mode switch beside a key.
enum FolderBrowserSortKey: Hashable, CaseIterable {
    case manual
    case name
    case dateAdded
}

/// Orders the folder browser's subfolders and direct files.
struct FolderBrowserSortMenu: View {
    let settings: AppSettings

    var body: some View {
        Menu {
            Picker(selection: keyBinding) {
                Text(FolderOutlineStrings.sortManual).tag(FolderBrowserSortKey.manual)
                Text(FolderOutlineStrings.sortByName).tag(FolderBrowserSortKey.name)
                Text(FolderOutlineStrings.sortByDateAdded).tag(FolderBrowserSortKey.dateAdded)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            Divider()
            Picker(selection: directionBinding) {
                Text(FolderOutlineStrings.sortAscending).tag(FolderSortDirection.ascending)
                Text(FolderOutlineStrings.sortDescending).tag(FolderSortDirection.descending)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .disabled(!Self.allowsDirection(settings.folderSort.browser))
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .pointingHandCursor()
        .help(Text(FolderOutlineStrings.sortMenu))
        .accessibilityLabel(Text(FolderOutlineStrings.sortMenu))
        .accessibilityIdentifier(Self.identifier)
    }

    static let identifier = "library.folder.sort"

    private var keyBinding: Binding<FolderBrowserSortKey> {
        Binding(
            get: { Self.key(for: settings.folderSort.browser) },
            set: { picked in
                let current = settings.folderSort.browser
                settings.folderSort.browser = Self.sort(for: picked, direction: Self.direction(of: current))
            }
        )
    }

    private var directionBinding: Binding<FolderSortDirection> {
        Binding(
            get: { Self.direction(of: settings.folderSort.browser) },
            set: { picked in
                let current = settings.folderSort.browser
                settings.folderSort.browser = Self.sort(for: Self.key(for: current), direction: picked)
            }
        )
    }
}

// MARK: - Menu ↔ stored order

extension FolderBrowserSortMenu {
    /// Which choice a stored order ticks in the key picker.
    static func key(for sort: FolderFilesSort) -> FolderBrowserSortKey {
        switch sort {
        case .manual: .manual
        case let .sorted(inner): inner.key == .name ? .name : .dateAdded
        }
    }

    /// The order a picked choice means, carrying the direction already chosen — so
    /// switching Name ↓ to Date added leaves it descending rather than silently
    /// resetting a preference the listener did not touch.
    static func sort(for key: FolderBrowserSortKey, direction: FolderSortDirection) -> FolderFilesSort {
        switch key {
        case .manual: .manual
        case .name: .sorted(FolderSort(key: .name, direction: direction))
        case .dateAdded: .sorted(FolderSort(key: .dateAdded, direction: direction))
        }
    }

    /// The direction control's value. Manual order has none, so it reads as
    /// ascending — the value the picker falls back to while it is disabled.
    static func direction(of sort: FolderFilesSort) -> FolderSortDirection {
        guard case let .sorted(inner) = sort else { return .ascending }
        return inner.direction
    }

    static func allowsDirection(_ sort: FolderFilesSort) -> Bool {
        sort != .manual
    }
}
