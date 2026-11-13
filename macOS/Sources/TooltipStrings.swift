// TooltipStrings — localized hover-tooltip (`.help`) copy for the macOS shell's
// interactive controls (Task 10). Kept in its own file (an `extension
// MacAMPStrings`) so it never bloats the shared MacAMPStrings.swift body, which
// already sits at the SwiftLint `type_body_length` limit. Views reference these
// constants — never a bare literal — so the shell stays localization-clean and
// passes `scripts/check-hardcoded-strings.sh`.
import Foundation

extension MacAMPStrings {
    static let helpPlay = LocalizedStringResource(
        "app.tooltip.play",
        defaultValue: "Play",
        comment: "Hover tooltip for the play button in the transport bar"
    )
    static let helpPause = LocalizedStringResource(
        "app.tooltip.pause",
        defaultValue: "Pause",
        comment: "Hover tooltip for the pause button in the transport bar"
    )
    static let helpNext = LocalizedStringResource(
        "app.tooltip.next",
        defaultValue: "Next Track",
        comment: "Hover tooltip for the skip-forward button in the transport bar"
    )
    static let helpPrevious = LocalizedStringResource(
        "app.tooltip.previous",
        defaultValue: "Previous Track",
        comment: "Hover tooltip for the skip-back button in the transport bar"
    )
    static let helpShuffle = LocalizedStringResource(
        "app.tooltip.shuffle",
        defaultValue: "Shuffle",
        comment: "Hover tooltip for the shuffle toggle in the transport bar"
    )
    static let helpRepeat = LocalizedStringResource(
        "app.tooltip.repeat",
        defaultValue: "Repeat",
        comment: "Hover tooltip for the repeat-mode toggle in the transport bar"
    )
    static let helpAddFolder = LocalizedStringResource(
        "app.tooltip.addFolder",
        defaultValue: "Add Folder to Library",
        comment: "Hover tooltip for the toolbar button that adds a music folder"
    )
    static let helpRightPanel = LocalizedStringResource(
        "app.tooltip.rightPanel",
        defaultValue: "Toggle Right Panel",
        comment: "Hover tooltip for the toolbar button that shows or hides the right panel"
    )
    static let helpEqualizer = LocalizedStringResource(
        "app.tooltip.equalizer",
        defaultValue: "Equalizer",
        comment: "Hover tooltip for the player-bar button that opens the equalizer overlay"
    )
    static let helpToggleSidebar = LocalizedStringResource(
        "app.tooltip.toggleSidebar",
        defaultValue: "Toggle Sidebar",
        comment: "Hover tooltip for the toolbar button that shows or hides the left sidebar"
    )
    static let helpNewPlaylist = LocalizedStringResource(
        "app.tooltip.newPlaylist",
        defaultValue: "New Playlist",
        comment: "Hover tooltip for the toolbar button that creates a new playlist"
    )
    static let helpExportPlaylist = LocalizedStringResource(
        "app.tooltip.exportPlaylist",
        defaultValue: "Export Playlist",
        comment: "Hover tooltip for the toolbar button that exports the current playlist"
    )
    static let cancelButton = LocalizedStringResource(
        "app.action.cancel",
        defaultValue: "Cancel",
        comment: "Cancel button label in dialogs"
    )
    static let createButton = LocalizedStringResource(
        "app.action.create",
        defaultValue: "Create",
        comment: "Create button label in the new playlist dialog"
    )
    static let okButton = LocalizedStringResource(
        "app.action.ok",
        defaultValue: "OK",
        comment: "Confirmation button that dismisses an alert"
    )
    static let helpImportPlaylist = LocalizedStringResource(
        "app.tooltip.importPlaylist",
        defaultValue: "Import Playlist",
        comment: "Hover tooltip for the toolbar button that imports a playlist file"
    )
    static let helpExportPlaylistFile = LocalizedStringResource(
        "app.tooltip.exportPlaylistFile",
        defaultValue: "Export Playlist",
        comment: "Hover tooltip for the toolbar button that exports the current playlist"
    )
    static let helpClearSearch = LocalizedStringResource(
        "app.tooltip.clearSearch",
        defaultValue: "Clear Search",
        comment: "Hover tooltip for the button that clears the search or filter text field"
    )
    static let helpBack = LocalizedStringResource(
        "app.tooltip.back",
        defaultValue: "Back",
        comment: "Hover tooltip for the back button that returns from a detail view to its list"
    )
    static let playlistDeletedToast = LocalizedStringResource(
        "app.toast.playlistDeleted",
        defaultValue: "Deleted",
        comment: "Toast message shown after a playlist is deleted"
    )

    static let menuDeleteTracksTitle = LocalizedStringResource(
        "app.menu.deleteTracksTitle",
        defaultValue: "Remove from Library",
        comment: "Title for the delete tracks confirmation dialog"
    )

    static func menuDeleteTracks(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.menu.deleteTracks",
            defaultValue: "Remove ^[\(count) track](inflect: true) from library?",
            comment: "Context menu item to delete selected tracks"
        )
    }

    static func tracksDeletedToast(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.toast.tracksDeleted",
            defaultValue: "Removed ^[\(count) track](inflect: true)",
            comment: "Toast shown after tracks are deleted from the library"
        )
    }
}
