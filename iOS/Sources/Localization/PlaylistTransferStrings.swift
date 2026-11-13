// PlaylistTransferStrings — localized copy for iOS playlist import / export
// (Task 21), kept separate from the playlist-editor strings so the two surfaces
// stay independently owned. Defined as an `extension MacAMPStrings` under the
// shared `ios.*` namespace; the `defaultValue` renders English until Task 44
// syncs the keys into `iOS/Sources/Localizable.xcstrings`.
import Foundation

extension MacAMPStrings {
    static let playlistImport = LocalizedStringResource(
        "ios.playlists.import",
        defaultValue: "Import…",
        comment: "Toolbar button that imports a playlist file (m3u/pls/JSPF)"
    )
    static let playlistExport = LocalizedStringResource(
        "ios.playlists.export",
        defaultValue: "Export…",
        comment: "Context-menu action that exports a playlist to a shareable file"
    )
    static let playlistExportTitle = LocalizedStringResource(
        "ios.playlists.export.title",
        defaultValue: "Export Playlist",
        comment: "Title of the export options sheet"
    )
    static let playlistExportFormat = LocalizedStringResource(
        "ios.playlists.export.format",
        defaultValue: "Format",
        comment: "Label for the playlist file-format picker"
    )
    static let playlistExportRelative = LocalizedStringResource(
        "ios.playlists.export.relativePaths",
        defaultValue: "Relative paths",
        comment: "Toggle: write track paths relative to a common folder"
    )
    static let playlistShareAction = LocalizedStringResource(
        "ios.playlists.export.share",
        defaultValue: "Share",
        comment: "Button that opens the share sheet for the exported playlist file"
    )
    static let playlistPreparing = LocalizedStringResource(
        "ios.playlists.export.preparing",
        defaultValue: "Preparing…",
        comment: "Shown while the playlist file is being rendered for sharing"
    )
    static let playlistUnresolvedTitle = LocalizedStringResource(
        "ios.playlists.import.unresolved.title",
        defaultValue: "Some Tracks Weren't Found",
        comment: "Title of the sheet listing imported entries that matched no library track"
    )
    static let playlistUnresolvedMessage = LocalizedStringResource(
        "ios.playlists.import.unresolved.message",
        defaultValue: "These playlist entries couldn't be matched to a track in your library:",
        comment: "Body explaining the list of unresolved playlist entries after an import"
    )
    static let playlistImportFailedTitle = LocalizedStringResource(
        "ios.playlists.import.failed.title",
        defaultValue: "Import Failed",
        comment: "Title of the alert shown when an imported playlist file can't be read"
    )
    static let playlistImportFailed = LocalizedStringResource(
        "ios.playlists.import.failed",
        defaultValue: "The playlist couldn't be imported.",
        comment: "Message shown when reading or parsing an imported playlist file fails"
    )
}
