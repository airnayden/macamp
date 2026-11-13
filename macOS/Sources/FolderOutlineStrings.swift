// FolderOutlineStrings — user-facing copy for the main window's hierarchical
// folder browser, centralized as `LocalizedStringResource` keys with an English
// `defaultValue`, exactly like `FolderSidebarStrings`. Folder NAMES are
// non-translatable and render with `Text(verbatim:)` at the call site; the
// recursive track count reuses `LibraryGridStrings.trackCount(_:)` rather than
// minting a second key for the same "N tracks" phrase.
import Foundation

/// Localized copy for the folder outline's disclosure and navigation affordances.
enum FolderOutlineStrings {
    static let expandFolder = LocalizedStringResource(
        "app.library.folderOutline.expand",
        defaultValue: "Show Contents",
        comment: "Tooltip and VoiceOver label for the chevron that expands a subfolder inline"
    )
    static let collapseFolder = LocalizedStringResource(
        "app.library.folderOutline.collapse",
        defaultValue: "Hide Contents",
        comment: "Tooltip and VoiceOver label for the chevron that collapses an expanded subfolder"
    )
    static let openFolder = LocalizedStringResource(
        "app.library.folderOutline.open",
        defaultValue: "Double-click to browse this folder",
        comment: "Tooltip on a subfolder row explaining that a double-click browses into it"
    )
    static let sortMenu = LocalizedStringResource(
        "app.library.folderOutline.sort.menu",
        defaultValue: "Sort Folder Contents",
        comment: "Tooltip and VoiceOver label for the icon-only menu that orders the folder browser"
    )
    static let sortManual = LocalizedStringResource(
        "app.library.folderOutline.sort.manual",
        defaultValue: "Manual Order",
        comment: "Keep the order the listener arranged by dragging rows; the only order a drag may rewrite"
    )
    static let sortByName = LocalizedStringResource(
        "app.library.folderOutline.sort.name",
        defaultValue: "Name",
        comment: "Order the folder browser alphabetically by folder and track name"
    )
    static let sortByDateAdded = LocalizedStringResource(
        "app.library.folderOutline.sort.dateAdded",
        defaultValue: "Date Added",
        comment: "Order the folder browser by when each track, or the newest track under each folder, was added"
    )
    static let sortAscending = LocalizedStringResource(
        "app.library.folderOutline.sort.ascending",
        defaultValue: "Ascending",
        comment: "Sort direction: A to Z, or oldest first"
    )
    static let sortDescending = LocalizedStringResource(
        "app.library.folderOutline.sort.descending",
        defaultValue: "Descending",
        comment: "Sort direction: Z to A, or newest first"
    )
}
