// MacAMPStrings — every user-facing string in the macOS shell, centralized as
// `LocalizedStringResource` keys with an English `defaultValue`.
//
// Views reference these constants — never a bare literal — so the shell is
// localization-clean by construction (and passes the no-hardcoded-strings
// guard). Until Task 44 syncs the keys into `macOS/Sources/Localizable.xcstrings`,
// the `defaultValue` renders, so the running app and previews show real copy.
// The dotted keys (`app.<area>.<element>`) are the single handoff list for the
// translator. The "MacAMP" brand is NEVER localized — it is rendered with
// `Text(verbatim: "MacAMP")` at its call sites, not from here.
import Foundation
import ViewModels

/// Localized copy for the macOS app shell.
enum MacAMPStrings {
    // MARK: Sidebar

    static let sidebarLibrarySection = LocalizedStringResource(
        "app.sidebar.section.library",
        defaultValue: "Library",
        comment: "Sidebar section header grouping the library destinations"
    )
    static let sidebarPlaylistsSection = LocalizedStringResource(
        "app.sidebar.section.playlists",
        defaultValue: "Playlists",
        comment: "Sidebar section header grouping playlist destinations"
    )
    static let sidebarAllTracks = LocalizedStringResource(
        "app.sidebar.allTracks",
        defaultValue: "All Tracks",
        comment: "Sidebar item showing every track in the library"
    )
    static let sidebarAlbums = LocalizedStringResource(
        "app.sidebar.albums",
        defaultValue: "Albums",
        comment: "Sidebar item showing the album grid"
    )
    static let sidebarArtists = LocalizedStringResource(
        "app.sidebar.artists",
        defaultValue: "Artists",
        comment: "Sidebar item showing the artist list"
    )
    static let sidebarPlaylists = LocalizedStringResource(
        "app.sidebar.playlists",
        defaultValue: "Playlists",
        comment: "Sidebar item showing user playlists"
    )
    static let sidebarFolderFallback = LocalizedStringResource(
        "app.sidebar.folder.fallback",
        defaultValue: "Folder",
        comment: "Fallback label for a per-folder sidebar root before its name resolves"
    )

    // MARK: Library browser

    static let libraryTitle = LocalizedStringResource(
        "app.library.title",
        defaultValue: "All Tracks",
        comment: "Navigation title of the library track browser"
    )
    static let searchPrompt = LocalizedStringResource(
        "app.search.prompt",
        defaultValue: "Search your library",
        comment: "Placeholder text in the library search field"
    )
    static let columnNumber = LocalizedStringResource(
        "app.column.number",
        defaultValue: "#",
        comment: "Track-number column header (ordinal position on a disc)"
    )
    static let columnTitle = LocalizedStringResource(
        "app.column.title",
        defaultValue: "Title",
        comment: "Track-title column header"
    )
    static let columnArtist = LocalizedStringResource(
        "app.column.artist",
        defaultValue: "Artist",
        comment: "Artist column header"
    )
    static let columnAlbum = LocalizedStringResource(
        "app.column.album",
        defaultValue: "Album",
        comment: "Album column header"
    )
    static let columnDuration = LocalizedStringResource(
        "app.column.duration",
        defaultValue: "Duration",
        comment: "Track-duration column header"
    )

    // MARK: Drag-and-drop import

    static let dropImportHint = LocalizedStringResource(
        "app.library.drop.hint",
        defaultValue: "Drop folders or audio files to import",
        comment: "Overlay shown while dragging folders or audio files over the library to import them"
    )

    // MARK: Availability badges (accessibility)

    static let badgeMissing = LocalizedStringResource(
        "app.badge.missing",
        defaultValue: "Missing",
        comment: "Accessibility label for a track whose file can no longer be found"
    )
    static let badgeOffline = LocalizedStringResource(
        "app.badge.offline",
        defaultValue: "Offline",
        comment: "Accessibility label for a track on an unmounted external volume"
    )

    // MARK: Track context menu

    static let menuPlay = LocalizedStringResource(
        "app.menu.play",
        defaultValue: "Play",
        comment: "Context-menu command that plays the selected tracks now"
    )
    static let menuPlayNext = LocalizedStringResource(
        "app.menu.playNext",
        defaultValue: "Play Next",
        comment: "Context-menu command that inserts the selection after the current track"
    )
    static let menuAddToQueue = LocalizedStringResource(
        "app.menu.addToQueue",
        defaultValue: "Add to Queue",
        comment: "Context-menu command that appends the selection to the play queue"
    )

    // MARK: Transport / now playing

    static let notPlaying = LocalizedStringResource(
        "app.player.notPlaying",
        defaultValue: "Not Playing",
        comment: "Shown in the transport bar when no track is loaded"
    )

    // MARK: Settings

    static let preferencesTitle = LocalizedStringResource(
        "app.preferences.title",
        defaultValue: "Preferences",
        comment: "Title of the Settings / Preferences window"
    )

    // MARK: Pending destinations (sidebar items implemented in later tasks)

    static let featurePendingTitle = LocalizedStringResource(
        "app.pending.title",
        defaultValue: "Coming Soon",
        comment: "Title of the placeholder shown for a sidebar destination not yet built"
    )
    static let featurePendingMessage = LocalizedStringResource(
        "app.pending.message",
        defaultValue: "This view arrives in a future update.",
        comment: "Body of the placeholder shown for a sidebar destination not yet built"
    )

    // MARK: Playlists browser + import / export

    static let playlistsEmptyTitle = LocalizedStringResource(
        "app.playlists.empty.title",
        defaultValue: "No Playlists",
        comment: "Title shown in the playlists pane when there are no playlists"
    )
    static let playlistsEmptyMessage = LocalizedStringResource(
        "app.playlists.empty.message",
        defaultValue: "Imported and created playlists appear here.",
        comment: "Body shown in the playlists pane when there are no playlists"
    )
    static let playlistImport = LocalizedStringResource(
        "app.playlists.import",
        defaultValue: "Import…",
        comment: "Toolbar command that imports a playlist file (m3u/pls/JSPF) into the library"
    )
    static let playlistExport = LocalizedStringResource(
        "app.playlists.export",
        defaultValue: "Export…",
        comment: "Command that exports the selected playlist to a file"
    )
    static let playlistExportTitle = LocalizedStringResource(
        "app.playlists.export.title",
        defaultValue: "Export Playlist",
        comment: "Title of the export options sheet"
    )
    static let playlistExportFormat = LocalizedStringResource(
        "app.playlists.export.format",
        defaultValue: "Format",
        comment: "Label for the playlist file-format picker"
    )
    static let playlistExportRelativePaths = LocalizedStringResource(
        "app.playlists.export.relativePaths",
        defaultValue: "Relative paths",
        comment: "Toggle: write track paths relative to the saved file's folder"
    )
    static let playlistExportAction = LocalizedStringResource(
        "app.playlists.export.action",
        defaultValue: "Export",
        comment: "Primary button that performs the export"
    )
    static let playlistCancel = LocalizedStringResource(
        "app.playlists.cancel",
        defaultValue: "Cancel",
        comment: "Button that dismisses the export sheet without exporting"
    )
    static let playlistImportDone = LocalizedStringResource(
        "app.playlists.import.done",
        defaultValue: "Done",
        comment: "Button that dismisses the unresolved-entries summary"
    )
    static let playlistUnresolvedTitle = LocalizedStringResource(
        "app.playlists.import.unresolved.title",
        defaultValue: "Some Tracks Weren't Found",
        comment: "Title of the sheet listing imported entries that matched no library track"
    )
    static let playlistUnresolvedMessage = LocalizedStringResource(
        "app.playlists.import.unresolved.message",
        defaultValue: "These playlist entries couldn't be matched to a track in your library:",
        comment: "Body explaining the list of unresolved playlist entries after an import"
    )
    static let playlistImportFailedTitle = LocalizedStringResource(
        "app.playlists.import.failed.title",
        defaultValue: "Import Failed",
        comment: "Title of the alert shown when an imported playlist file can't be read"
    )
    static let playlistImportFailed = LocalizedStringResource(
        "app.playlists.import.failed",
        defaultValue: "The playlist couldn't be imported.",
        comment: "Message shown when reading or parsing an imported playlist file fails"
    )

    // MARK: Queue

    static let sidebarQueue = LocalizedStringResource(
        "app.sidebar.queue",
        defaultValue: "Queue",
        comment: "Sidebar item showing the manually queued tracks"
    )
    static let queueEmptyTitle = LocalizedStringResource(
        "app.queue.empty.title",
        defaultValue: "Queue Empty",
        comment: "Title shown in the queue panel when no tracks are queued"
    )
    static let queueEmptyMessage = LocalizedStringResource(
        "app.queue.empty.message",
        defaultValue: "Add tracks to see them here.",
        comment: "Body shown in the queue panel when no tracks are queued"
    )
    static let queueRemove = LocalizedStringResource(
        "app.queue.remove",
        defaultValue: "Remove from Queue",
        comment: "Context-menu command that removes a track from the play queue"
    )

    // MARK: Right panel

    static let panelLyrics = LocalizedStringResource(
        "app.panel.lyrics",
        defaultValue: "Lyrics",
        comment: "Tab label for the lyrics panel in the right sidebar"
    )
    static let panelEQ = LocalizedStringResource(
        "app.panel.eq",
        defaultValue: "EQ",
        comment: "Tab label for the equalizer panel in the right sidebar"
    )
    static let panelToggle = LocalizedStringResource(
        "app.panel.toggle",
        defaultValue: "Toggle Right Panel",
        comment: "Accessibility label for the button that shows or hides the right panel"
    )

    // MARK: Sidebar context menus

    static let sidebarRenamePlaylist = LocalizedStringResource(
        "app.sidebar.playlist.rename",
        defaultValue: "Rename…",
        comment: "Context-menu command to rename a playlist"
    )
    static let sidebarDeletePlaylist = LocalizedStringResource(
        "app.sidebar.playlist.delete",
        defaultValue: "Delete",
        comment: "Context-menu command to delete a playlist"
    )
    static let sidebarRemoveFolder = LocalizedStringResource(
        "app.sidebar.folder.remove",
        defaultValue: "Remove Folder",
        comment: "Context-menu command to remove a library folder root"
    )

    // MARK: Add to Playlist

    static let menuAddToPlaylist = LocalizedStringResource(
        "app.menu.addToPlaylist",
        defaultValue: "Add to Playlist",
        comment: "Submenu label for adding a track to a playlist"
    )
    static let menuNewPlaylist = LocalizedStringResource(
        "app.menu.newPlaylist",
        defaultValue: "New Playlist…",
        comment: "Menu item to create a new playlist and add the selected track"
    )
}

// MARK: - Library navigation

// `LibrarySection` / `SidebarDestination` live in PlayerCore's ViewModels module so
// their Codable + routing contract is unit-tested by `swift test`; only the
// localized `label` (which needs the shell's String Catalog) stays in the app.

extension LibrarySection {
    var label: LocalizedStringResource {
        switch self {
        case .allTracks: MacAMPStrings.sidebarAllTracks
        case .albums: MacAMPStrings.sidebarAlbums
        case .artists: MacAMPStrings.sidebarArtists
        case .favourites: FavouritesStrings.title
        case .lyrics: MacAMPStrings.sidebarLyrics
        case .playlists: MacAMPStrings.sidebarPlaylists
        case .stats: StatsPanelStrings.title
        case .queue: MacAMPStrings.sidebarQueue
        case .karaoke: MacAMPStrings.sidebarKaraoke
        case .karaokeQueue: MacAMPStrings.sidebarKaraokeQueue
        case .assistant: AssistantPaneStrings.title
        case .downloads: MacAMPStrings.sidebarDownloads
        }
    }
}

extension SidebarDestination {
    var label: LocalizedStringResource {
        switch self {
        case let .fixed(section): section.label
        case .folder: MacAMPStrings.sidebarFolderFallback
        case .playlist: MacAMPStrings.sidebarPlaylists
        }
    }
}

/// A separate extension keeps the main `MacAMPStrings` enum body within the
/// SwiftLint type-body-length budget.
extension MacAMPStrings {
    // MARK: Queue management + now playing

    static let queueClear = LocalizedStringResource(
        "app.queue.clear",
        defaultValue: "Clear Queue",
        comment: "Button that removes every upcoming track from the play queue"
    )
    static let nowPlayingIndicator = LocalizedStringResource(
        "app.nowPlaying.indicator",
        defaultValue: "Now playing",
        comment: "Accessibility label for the icon marking the currently playing track in a track list"
    )

    // MARK: Search

    static let searchClear = LocalizedStringResource(
        "app.search.clear",
        defaultValue: "Clear search",
        comment: "Accessibility label for the button that clears the library search field"
    )
    static let searchFilterPrompt = LocalizedStringResource(
        "app.search.filterPrompt",
        defaultValue: "Filter",
        comment: "Placeholder text in a contextual filter field inside a folder or playlist"
    )
    static let searchResultsTitle = LocalizedStringResource(
        "app.search.results.title",
        defaultValue: "Search Results",
        comment: "Title shown above search results in the content pane"
    )

    // MARK: Folder export

    static let folderExportJSON = LocalizedStringResource(
        "app.folder.export.json",
        defaultValue: "Export as JSON…",
        comment: "Context-menu command to export a folder's track list as a JSON file"
    )
}
