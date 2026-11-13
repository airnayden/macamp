// MacAMPStrings — every user-facing string in the iOS / iPadOS shell, centralized
// as `LocalizedStringResource` keys with an English `defaultValue`.
//
// Mirrors the macOS shell's convention (Task 25): views reference these constants
// — never a bare literal — so the shell is localization-clean by construction and
// passes `scripts/check-hardcoded-strings.sh`. Until Task 44 syncs the keys into
// `iOS/Sources/Localizable.xcstrings`, the `defaultValue` renders, so the running
// app and previews show real copy. The dotted keys (`ios.<area>.<element>`) are
// the single handoff list for the translator. The "MacAMP" brand is NEVER
// localized — it is rendered with `Text(verbatim: "MacAMP")` at its call sites.
import Foundation

/// Localized copy for the iOS / iPadOS app shell.
enum MacAMPStrings {
    // MARK: Tabs

    static let tabLibrary = LocalizedStringResource(
        "ios.tab.library",
        defaultValue: "Library",
        comment: "Tab-bar item for the music library browser"
    )
    static let tabPlaylists = LocalizedStringResource(
        "ios.tab.playlists",
        defaultValue: "Playlists",
        comment: "Tab-bar item for the playlists browser"
    )
    static let tabNowPlaying = LocalizedStringResource(
        "ios.tab.nowPlaying",
        defaultValue: "Now Playing",
        comment: "Tab-bar item for the now-playing screen"
    )
    static let tabSearch = LocalizedStringResource(
        "ios.tab.search",
        defaultValue: "Search",
        comment: "Tab-bar item for full-text search"
    )
    static let tabSettings = LocalizedStringResource(
        "ios.tab.settings",
        defaultValue: "Settings",
        comment: "Tab-bar item for app settings"
    )

    // MARK: Library

    static let libraryTitle = LocalizedStringResource(
        "ios.library.title",
        defaultValue: "Library",
        comment: "Navigation title of the library browser"
    )
    static let libraryScopeSongs = LocalizedStringResource(
        "ios.library.scope.songs",
        defaultValue: "Songs",
        comment: "Library browser scope showing every track"
    )
    static let libraryScopeAlbums = LocalizedStringResource(
        "ios.library.scope.albums",
        defaultValue: "Albums",
        comment: "Library browser scope showing albums"
    )
    static let libraryScopeArtists = LocalizedStringResource(
        "ios.library.scope.artists",
        defaultValue: "Artists",
        comment: "Library browser scope showing artists"
    )
    static let librarySearchPrompt = LocalizedStringResource(
        "ios.library.search.prompt",
        defaultValue: "Search your library",
        comment: "Placeholder text in the library search field"
    )
    static let badgeMissing = LocalizedStringResource(
        "ios.badge.missing",
        defaultValue: "Missing",
        comment: "Accessibility label for a track whose file can no longer be found"
    )
    static let badgeOffline = LocalizedStringResource(
        "ios.badge.offline",
        defaultValue: "Offline",
        comment: "Accessibility label for a track on an unmounted external volume"
    )
    static let unknownArtist = LocalizedStringResource(
        "ios.library.unknownArtist",
        defaultValue: "Unknown Artist",
        comment: "Subtitle shown for an album or track with no artist"
    )
    static let unknownTitle = LocalizedStringResource(
        "ios.library.unknownTitle",
        defaultValue: "Untitled",
        comment: "Title shown for an album or track with no title"
    )

    // MARK: Search

    static let searchTitle = LocalizedStringResource(
        "ios.search.title",
        defaultValue: "Search",
        comment: "Navigation title of the search screen"
    )
    static let searchPrompt = LocalizedStringResource(
        "ios.search.prompt",
        defaultValue: "Songs, albums and artists",
        comment: "Placeholder text in the search field"
    )
    static let searchIdleTitle = LocalizedStringResource(
        "ios.search.idle.title",
        defaultValue: "Search Your Library",
        comment: "Title shown before the user types a search query"
    )
    static let searchIdleMessage = LocalizedStringResource(
        "ios.search.idle.message",
        defaultValue: "Find songs, albums and artists across your collection.",
        comment: "Body shown before the user types a search query"
    )
    static let searchEmptyTitle = LocalizedStringResource(
        "ios.search.empty.title",
        defaultValue: "No Results",
        comment: "Title shown when a search returns nothing"
    )
    static let searchEmptyMessage = LocalizedStringResource(
        "ios.search.empty.message",
        defaultValue: "Try a different word or check your spelling.",
        comment: "Body shown when a search returns nothing"
    )
    static let searchResultsHeader = LocalizedStringResource(
        "ios.search.results.header",
        defaultValue: "Results",
        comment: "Header label above the ranked search results list"
    )

    // MARK: Playlists

    static let playlistsTitle = LocalizedStringResource(
        "ios.playlists.title",
        defaultValue: "Playlists",
        comment: "Navigation title of the playlists browser"
    )
    static let playlistsAutoMixesHeader = LocalizedStringResource(
        "ios.playlists.autoMixes.header",
        defaultValue: "Auto Mixes",
        comment: "Header of the playlists section listing automatically generated mixes"
    )
    static let playlistsAutoMixesPreparing = LocalizedStringResource(
        "ios.playlists.autoMixes.preparing",
        defaultValue: "Preparing your mixes…",
        comment: "Progress label shown while the automatic mixes are being generated for the first time"
    )
    static let playlistsEmptyTitle = LocalizedStringResource(
        "ios.playlists.empty.title",
        defaultValue: "No Playlists",
        comment: "Title shown when there are no playlists"
    )
    static let playlistsEmptyMessage = LocalizedStringResource(
        "ios.playlists.empty.message",
        defaultValue: "Playlists you create will appear here.",
        comment: "Body shown when there are no playlists"
    )

    // MARK: Settings

    static let settingsTitle = LocalizedStringResource(
        "ios.settings.title",
        defaultValue: "Settings",
        comment: "Navigation title of the settings screen"
    )
    static let settingsPlayback = LocalizedStringResource(
        "ios.settings.section.playback",
        defaultValue: "Playback",
        comment: "Settings section grouping playback options"
    )
    static let settingsEqualizer = LocalizedStringResource(
        "ios.settings.section.equalizer",
        defaultValue: "Equalizer",
        comment: "Settings section grouping equalizer options"
    )
    static let settingsVisualizer = LocalizedStringResource(
        "ios.settings.section.visualizer",
        defaultValue: "Visualizer",
        comment: "Settings section grouping visualizer options"
    )
    static let settingsAbout = LocalizedStringResource(
        "ios.settings.section.about",
        defaultValue: "About",
        comment: "Settings section showing app information"
    )
    static let settingsReplayGain = LocalizedStringResource(
        "ios.settings.replayGain",
        defaultValue: "ReplayGain",
        comment: "Settings row for the ReplayGain normalization mode"
    )
    static let settingsPlaybackFooter = LocalizedStringResource(
        "ios.settings.section.playback.footer",
        defaultValue: "Normalize loudness so every track plays at a consistent volume.",
        comment: "Explanatory footer under the Playback settings section"
    )
    static let settingsEqualizerFooter = LocalizedStringResource(
        "ios.settings.section.equalizer.footer",
        defaultValue: "Apply this preset automatically when playback begins.",
        comment: "Explanatory footer under the Equalizer settings section"
    )
    static let settingsVisualizerFooter = LocalizedStringResource(
        "ios.settings.section.visualizer.footer",
        defaultValue: "Choose the visualization shown on the Now Playing screen.",
        comment: "Explanatory footer under the Visualizer settings section"
    )
    static let settingsDefaultPreset = LocalizedStringResource(
        "ios.settings.defaultPreset",
        defaultValue: "Default Preset",
        comment: "Settings row for the default EQ preset"
    )
    static let settingsVisualizerMode = LocalizedStringResource(
        "ios.settings.visualizerMode",
        defaultValue: "Default Mode",
        comment: "Settings row for the default visualizer mode"
    )
    static let settingsVersion = LocalizedStringResource(
        "ios.settings.version",
        defaultValue: "Version",
        comment: "Settings row showing the app version number"
    )
    static let settingsAcknowledgments = LocalizedStringResource(
        "ios.settings.acknowledgments",
        defaultValue: "Acknowledgments",
        comment: "Settings row opening the open-source acknowledgments screen"
    )

    // MARK: Import (Task 33 fills the action)

    static let importMusic = LocalizedStringResource(
        "ios.import.music",
        defaultValue: "Add Music",
        comment: "Button that imports audio files into the library"
    )
}
