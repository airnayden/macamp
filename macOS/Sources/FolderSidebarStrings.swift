// FolderSidebarStrings — user-facing copy for the dynamic per-folder sidebar
// nodes (Task 13), centralized as `LocalizedStringResource` keys with an English
// `defaultValue`, exactly like `MacAMPStrings` / `FileAccessStrings`. Folder
// NAMES are non-translatable and rendered with `Text(verbatim:)` at the call
// site; only the section header and the "missing" badge live here.
import Foundation

/// Localized copy for the dynamic "Folders" sidebar section.
enum FolderSidebarStrings {
    static let section = LocalizedStringResource(
        "app.sidebar.section.folders",
        defaultValue: "Folders",
        comment: "Sidebar section header grouping the per-folder library roots"
    )
    static let missingBadge = LocalizedStringResource(
        "app.sidebar.folder.missing",
        defaultValue: "Missing",
        comment: "Badge on a folder root whose tracks can no longer be found on disk"
    )
    /// Scopes the folder tree ONLY — never the global search field or another section.
    static let filterPrompt = LocalizedStringResource(
        "sidebar.folderFilter.prompt",
        defaultValue: "Filter Folders",
        comment: "Placeholder in the sidebar field that filters the folder tree by folder name"
    )
    static let filterAccessibilityLabel = LocalizedStringResource(
        "sidebar.folderFilter.label",
        defaultValue: "Filter folders",
        comment: "VoiceOver label for the sidebar field that filters the folder tree by folder name"
    )
    static let sortMenu = LocalizedStringResource(
        "sidebar.folderSort.menu",
        defaultValue: "Sort Folders",
        comment: "Tooltip and VoiceOver label for the icon-only menu that orders the sidebar folder tree"
    )
    static let sortByName = LocalizedStringResource(
        "sidebar.folderSort.name",
        defaultValue: "Name",
        comment: "Sort the sidebar folder tree alphabetically by folder name"
    )
    static let sortByDateAdded = LocalizedStringResource(
        "sidebar.folderSort.dateAdded",
        defaultValue: "Date Added",
        comment: "Sort the sidebar folder tree by when the newest track under each folder was added"
    )
    static let sortAscending = LocalizedStringResource(
        "sidebar.folderSort.ascending",
        defaultValue: "Ascending",
        comment: "Sort direction: A to Z, or oldest first"
    )
    static let sortDescending = LocalizedStringResource(
        "sidebar.folderSort.descending",
        defaultValue: "Descending",
        comment: "Sort direction: Z to A, or newest first"
    )
}
