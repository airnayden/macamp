// PlaylistBrowserStrings — localized chrome for the macOS playlists browser +
// detail (Task 18).
//
// Defined as an `extension MacAMPStrings` so the playlist browser/detail copy lives
// under the same `app.*` namespace as the rest of the shell while keeping the main
// `MacAMPStrings` enum body under the SwiftLint type-body limit. The `defaultValue`
// renders real English until Task 44 syncs the keys into
// `macOS/Sources/Localizable.xcstrings`.
import Foundation

extension MacAMPStrings {
    // MARK: Playlists CRUD (create / rename / delete)

    static let playlistsNew = LocalizedStringResource(
        "app.playlists.new",
        defaultValue: "New Playlist",
        comment: "Toolbar button + title that creates a new playlist"
    )
    static let playlistsCreate = LocalizedStringResource(
        "app.playlists.create",
        defaultValue: "Create",
        comment: "Confirm button that creates the playlist being named"
    )
    static let playlistsRename = LocalizedStringResource(
        "app.playlists.rename",
        defaultValue: "Rename",
        comment: "Context-menu action + sheet title that renames a playlist"
    )
    static let playlistsSave = LocalizedStringResource(
        "app.playlists.save",
        defaultValue: "Save",
        comment: "Confirm button that saves a renamed playlist"
    )
    static let playlistsDelete = LocalizedStringResource(
        "app.playlists.delete",
        defaultValue: "Delete",
        comment: "Context-menu action that deletes a playlist (its tracks stay in the library)"
    )
    static let playlistsNamePlaceholder = LocalizedStringResource(
        "app.playlists.namePlaceholder",
        defaultValue: "Playlist Name",
        comment: "Placeholder text in the playlist-name field"
    )

    // MARK: Playlist detail

    static let playlistPlayAll = LocalizedStringResource(
        "app.playlist.playAll",
        defaultValue: "Play All",
        comment: "Button that plays a playlist from its first track"
    )
    static let playlistShuffle = LocalizedStringResource(
        "app.playlist.shuffle",
        defaultValue: "Shuffle",
        comment: "Button that plays a playlist in shuffled order"
    )
    static let playlistRemove = LocalizedStringResource(
        "app.playlist.remove",
        defaultValue: "Remove from Playlist",
        comment: "Context-menu action that removes a track from a playlist (keeps it in the library)"
    )
    static let playlistAddTo = LocalizedStringResource(
        "app.playlist.addTo",
        defaultValue: "Add to Playlist",
        comment: "Context-menu submenu that adds the selected tracks to another playlist"
    )
    static let playlistEditOrder = LocalizedStringResource(
        "app.playlist.editOrder",
        defaultValue: "Edit Order",
        comment: "Toolbar toggle that enables drag-to-reorder of a playlist's tracks"
    )
    static let playlistDoneEditing = LocalizedStringResource(
        "app.playlist.doneEditing",
        defaultValue: "Done",
        comment: "Toolbar toggle that leaves drag-to-reorder mode"
    )
    static let playlistTracksEmptyTitle = LocalizedStringResource(
        "app.playlist.empty.title",
        defaultValue: "No Songs",
        comment: "Title shown when a playlist has no tracks"
    )
    static let playlistTracksEmptyMessage = LocalizedStringResource(
        "app.playlist.empty.message",
        defaultValue: "Songs you add to this playlist appear here.",
        comment: "Body shown when a playlist has no tracks"
    )

    // MARK: Playlist export outcome

    static let playlistExportFailedTitle = LocalizedStringResource(
        "app.playlists.export.failed.title",
        defaultValue: "Export Failed",
        comment: "Title of the alert shown when a playlist could not be written to the chosen file"
    )
    static let playlistExportFailedMessage = LocalizedStringResource(
        "app.playlists.export.failed",
        defaultValue: "The playlist couldn't be saved. Check that you can write to the chosen location, then try again.",
        comment: "Message shown when writing an exported playlist file fails"
    )
    static let playlistExportSucceeded = LocalizedStringResource(
        "app.playlists.export.succeeded",
        defaultValue: "Playlist exported",
        comment: "Toast confirming an exported playlist file was written"
    )
}
