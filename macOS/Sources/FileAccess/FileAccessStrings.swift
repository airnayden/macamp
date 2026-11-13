// FileAccessStrings — every user-facing string in the library-folders UI,
// centralized as `LocalizedStringResource` keys with an English `defaultValue`.
//
// Mirrors `MacAMPStrings` (and DesignSystem's centralized resources): the
// ``LibraryFoldersView`` references these constants — never a bare literal — so it
// is localization-clean by construction and passes the no-hardcoded-strings guard.
// The dotted keys (`app.fileAccess.<element>`) are the single handoff list for the
// translator (Task 44). No copy embeds the "MacAMP" brand, so nothing here needs a
// verbatim brand token.
import Foundation

/// Localized copy for the library-folders preferences pane.
enum FileAccessStrings {
    // MARK: Header

    static let title = LocalizedStringResource(
        "app.fileAccess.title",
        defaultValue: "Music Folders",
        comment: "Header of the pane listing the folders MacAMP imports music from"
    )
    static let description = LocalizedStringResource(
        "app.fileAccess.description",
        defaultValue: "These folders are watched for changes and kept in sync with your library.",
        comment: "Explains that chosen folders are monitored and auto-imported"
    )

    // MARK: Actions

    static let addFolder = LocalizedStringResource(
        "app.fileAccess.addFolder",
        defaultValue: "Add Folder…",
        comment: "Button that opens the folder picker to add a library root"
    )
    static let removeFolder = LocalizedStringResource(
        "app.fileAccess.removeFolder",
        defaultValue: "Remove Folder",
        comment: "Accessibility label for the button that removes a library root"
    )
    static let refresh = LocalizedStringResource(
        "app.fileAccess.refresh",
        defaultValue: "Refresh",
        comment: "Button that re-checks access to the chosen folders"
    )

    static func folderAdded(_ folderName: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.fileAccess.toast.added",
            defaultValue: "Added \(folderName)",
            comment: "Toast shown after adding and scanning a music folder; argument is the folder name"
        )
    }

    static func folderRemoved(_ folderName: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.fileAccess.toast.removed",
            defaultValue: "Removed \(folderName)",
            comment: "Toast shown after removing a music folder; argument is the folder name"
        )
    }

    static let libraryRefreshed = LocalizedStringResource(
        "app.fileAccess.toast.refreshed",
        defaultValue: "Library refreshed",
        comment: "Toast shown after all configured music folders finish rescanning"
    )

    // MARK: Empty state

    static let emptyTitle = LocalizedStringResource(
        "app.fileAccess.empty.title",
        defaultValue: "No Music Folders",
        comment: "Title shown when the user has not added any library folders yet"
    )
    static let emptyMessage = LocalizedStringResource(
        "app.fileAccess.empty.message",
        defaultValue: "Add a folder to start building your library. New and changed files are imported automatically.",
        comment: "Body shown when no library folders have been added"
    )

    // MARK: Per-folder access status

    static let statusAccessible = LocalizedStringResource(
        "app.fileAccess.status.accessible",
        defaultValue: "Accessible",
        comment: "Accessibility label for a folder that can be read"
    )
    static let statusDenied = LocalizedStringResource(
        "app.fileAccess.status.denied",
        defaultValue: "No Access",
        comment: "Accessibility label for a folder the app is not permitted to read"
    )
    static let statusMissing = LocalizedStringResource(
        "app.fileAccess.status.missing",
        defaultValue: "Unavailable",
        comment: "Accessibility label for a folder that no longer exists or is on an unmounted drive"
    )

    // MARK: Denial recovery

    static let deniedTitle = LocalizedStringResource(
        "app.fileAccess.denied.title",
        defaultValue: "Some folders can’t be read",
        comment: "Title of the banner shown when one or more folders are access-denied"
    )
    static let deniedMessage = LocalizedStringResource(
        "app.fileAccess.denied.message",
        defaultValue: "Grant access in System Settings, then refresh.",
        comment: "Guidance for recovering from a denied-access folder"
    )
    static let openSettings = LocalizedStringResource(
        "app.fileAccess.openSettings",
        defaultValue: "Open System Settings",
        comment: "Button that opens the Privacy ▸ Files and Folders settings pane"
    )

    // MARK: Rejected folders

    static let rejectedAppInternal = LocalizedStringResource(
        "app.fileAccess.rejected.appInternal",
        defaultValue: "That folder is used by MacAMP and can’t be added as a music folder.",
        comment: "Shown when the user tries to add MacAMP's own Application Support or Caches directory as a library root"
    )
    static let rejectedKaraokeCache = LocalizedStringResource(
        "app.fileAccess.rejected.karaokeCache",
        defaultValue: "That folder overlaps the karaoke cache folder and can’t be added as a music folder.",
        comment: "Shown when the user tries to add a folder that is equal to, inside, or contains the karaoke instrumental cache directory"
    )
}
