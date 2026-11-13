// PlaylistStrings — localized copy for the iOS playlists browser + detail editor.
//
// Defined as an `extension MacAMPStrings` so every playlist-editing string lives
// under the same `ios.*` namespace as the rest of the shell while staying in the
// `Localization/` folder (mirrors `PlayerStrings`). Views reference these
// constants — never a bare literal — so the surface is localization-clean and
// passes `scripts/check-hardcoded-strings.sh`. The `defaultValue` renders real
// English until Task 44 syncs the keys into `iOS/Sources/Localizable.xcstrings`.
import Foundation

extension MacAMPStrings {
    // MARK: Browser actions

    static let playlistsNew = LocalizedStringResource(
        "ios.playlists.new",
        defaultValue: "New Playlist",
        comment: "Title + button that creates a new playlist"
    )
    static let playlistsCreate = LocalizedStringResource(
        "ios.playlists.create",
        defaultValue: "Create",
        comment: "Confirm button that creates the playlist being named"
    )
    static let playlistsCancel = LocalizedStringResource(
        "ios.playlists.cancel",
        defaultValue: "Cancel",
        comment: "Button that dismisses a playlist sheet without saving"
    )
    static let playlistsRename = LocalizedStringResource(
        "ios.playlists.rename",
        defaultValue: "Rename",
        comment: "Title + action that renames a playlist"
    )
    static let playlistsSave = LocalizedStringResource(
        "ios.playlists.save",
        defaultValue: "Save",
        comment: "Confirm button that saves a renamed playlist"
    )
    static let playlistsDelete = LocalizedStringResource(
        "ios.playlists.delete",
        defaultValue: "Delete",
        comment: "Action that deletes a playlist (its tracks stay in the library)"
    )
    static let playlistsNamePlaceholder = LocalizedStringResource(
        "ios.playlists.namePlaceholder",
        defaultValue: "Playlist Name",
        comment: "Placeholder text in the playlist-name field"
    )

    // MARK: Detail

    static let playlistPlayAll = LocalizedStringResource(
        "ios.playlist.playAll",
        defaultValue: "Play All",
        comment: "Button that plays a playlist from its first track"
    )
    static let playlistShuffle = LocalizedStringResource(
        "ios.playlist.shuffle",
        defaultValue: "Shuffle",
        comment: "Button that plays a playlist in shuffled order"
    )
    static let playlistRemove = LocalizedStringResource(
        "ios.playlist.remove",
        defaultValue: "Remove",
        comment: "Swipe action that removes a track from a playlist (keeps it in the library)"
    )
    static let playlistTracksEmptyTitle = LocalizedStringResource(
        "ios.playlist.empty.title",
        defaultValue: "No Songs",
        comment: "Title shown when a playlist has no tracks"
    )
    static let playlistTracksEmptyMessage = LocalizedStringResource(
        "ios.playlist.empty.message",
        defaultValue: "Songs you add to this playlist will appear here.",
        comment: "Body shown when a playlist has no tracks"
    )

    // MARK: Add to playlist

    static let playlistAddTo = LocalizedStringResource(
        "ios.playlist.addTo",
        defaultValue: "Add to Playlist…",
        comment: "Context-menu action that adds a track to an existing playlist"
    )
    static let playlistAddToTitle = LocalizedStringResource(
        "ios.playlist.addTo.title",
        defaultValue: "Add to Playlist",
        comment: "Title of the sheet that picks a playlist to add a track to"
    )
    static let playlistAddToNew = LocalizedStringResource(
        "ios.playlist.addTo.new",
        defaultValue: "New Playlist…",
        comment: "Row that creates a new playlist to add the track to"
    )
}
