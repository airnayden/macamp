// AccessibilityStrings — VoiceOver hints for the iOS shell's interactive controls.
//
// Defined as an `extension MacAMPStrings` so every hint lives under the same
// `ios.*` namespace as the rest of the shell. These are the iOS analog of the
// macOS `.help()` tooltips: `.accessibilityHint` describes what a control *does*
// after VoiceOver has read its label. Views reference these constants — never a
// bare literal — so the surface stays localization-clean and passes
// `scripts/check-hardcoded-strings.sh`. Keys follow the `ios.a11y.<element>`
// namespace; the `defaultValue` renders real English until Task 44 syncs them
// into `iOS/Sources/Localizable.xcstrings`.
import Foundation

extension MacAMPStrings {
    // MARK: Library + search hints

    /// Hint on a playable track row — read after the track's title/artist.
    static let a11yHintPlayTrack = LocalizedStringResource(
        "ios.a11y.hint.playTrack",
        defaultValue: "Plays this track and continues through the list.",
        comment: "VoiceOver hint for a library or search track row that starts playback"
    )

    /// Hint on the library import toolbar button.
    static let a11yHintImport = LocalizedStringResource(
        "ios.a11y.hint.import",
        defaultValue: "Imports songs or folders into your library.",
        comment: "VoiceOver hint for the toolbar button that adds music to the library"
    )

    /// Hint on the segmented library-scope selector.
    static let a11yHintLibraryScope = LocalizedStringResource(
        "ios.a11y.hint.libraryScope",
        defaultValue: "Switches the library between songs, albums and artists.",
        comment: "VoiceOver hint for the segmented control that changes the library browse scope"
    )

    /// Hint on a genre-filter chip.
    static let a11yHintGenreFilter = LocalizedStringResource(
        "ios.a11y.hint.genreFilter",
        defaultValue: "Filters the songs list to this genre.",
        comment: "VoiceOver hint for a genre-filter chip under the Songs scope"
    )

    // MARK: Playlists hints

    /// Hint on the New-playlist toolbar button.
    static let a11yHintNewPlaylist = LocalizedStringResource(
        "ios.a11y.hint.newPlaylist",
        defaultValue: "Creates a new playlist.",
        comment: "VoiceOver hint for the toolbar button that creates a playlist"
    )
}
