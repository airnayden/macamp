// Lyrics sidebar + browser copy, kept out of
// `MacAMPStrings.swift` so that file stays within the SwiftLint
// type-body-length / file-length budgets. These remain `MacAMPStrings` members
// (referenced as `MacAMPStrings.sidebarLyrics` etc.) via this extension.
import Foundation

extension MacAMPStrings {
    static let sidebarLyrics = LocalizedStringResource(
        "app.sidebar.lyrics",
        defaultValue: "Lyrics",
        comment: "Sidebar item listing every track whose lyrics are already cached"
    )
    static let lyricsBrowserEmptyTitle = LocalizedStringResource(
        "app.lyrics.browser.emptyTitle",
        defaultValue: "No Lyrics Yet",
        comment: "Empty-state title on the Lyrics browser before any lyrics are cached"
    )
    static let lyricsBrowserEmptyMessage = LocalizedStringResource(
        "app.lyrics.browser.emptyMessage",
        defaultValue: "MacAMP is still scanning your library for embedded and .lrc lyrics. Run Enrichment to look them up online.",
        comment: "Empty-state message on the Lyrics browser explaining how lyrics get cached"
    )
    static let lyricsBrowserSyncedBadge = LocalizedStringResource(
        "app.lyrics.browser.syncedBadge",
        defaultValue: "Synced lyrics",
        comment: "Accessibility label for the badge marking a track whose cached lyrics are time-synced"
    )
}
