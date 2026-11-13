// Karaoke sidebar + ready-list copy, kept out of `MacAMPStrings.swift` so that
// file stays within the SwiftLint type-body-length / file-length budgets. These
// remain `MacAMPStrings` members (referenced as `MacAMPStrings.sidebarKaraoke`
// etc.) via this extension.
import Foundation

extension MacAMPStrings {
    static let sidebarKaraokeSection = LocalizedStringResource(
        "app.sidebar.section.karaoke",
        defaultValue: "Karaoke",
        comment: "Sidebar section header grouping the karaoke ready-tracks destination"
    )
    static let sidebarKaraoke = LocalizedStringResource(
        "app.sidebar.karaoke",
        defaultValue: "Karaoke",
        comment: "Sidebar item showing tracks with a rendered karaoke instrumental"
    )
    static let karaokeReadyEmptyTitle = LocalizedStringResource(
        "app.karaoke.ready.emptyTitle",
        defaultValue: "No Karaoke Tracks",
        comment: "Empty-state title on the karaoke list before any instrumental is rendered"
    )
    static let karaokeReadyEmptyMessage = LocalizedStringResource(
        "app.karaoke.ready.emptyMessage",
        defaultValue: "Render a song to see it here",
        comment: "Empty-state message on the karaoke list before any instrumental is rendered"
    )
    static let karaokeReadySearchPrompt = LocalizedStringResource(
        "app.karaoke.ready.searchPrompt",
        defaultValue: "Search karaoke tracks",
        comment: "Placeholder text in the karaoke ready-list search field"
    )
    static let karaokeReadyNoResultsTitle = LocalizedStringResource(
        "app.karaoke.ready.noResultsTitle",
        defaultValue: "No Results",
        comment: "Title shown when a karaoke ready-list search matches no tracks"
    )
    static let karaokeReadyNoResultsMessage = LocalizedStringResource(
        "app.karaoke.ready.noResultsMessage",
        defaultValue: "No karaoke tracks match your search",
        comment: "Message shown when a karaoke ready-list search matches no tracks"
    )

    static func karaokeReadyRemove(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.karaoke.ready.remove",
            defaultValue: "Remove ^[\(count) Karaoke Version](inflect: true)",
            comment: "Destructive context-menu item deleting the cached karaoke instrumental for the selected tracks"
        )
    }

    /// The all-removed toast. `String(localized:)` would return the raw `^[…](inflect:)`
    /// markup, so counted copy resolves through `AttributedString` (see ``resolvedKaraokeInflection(_:)``).
    static func karaokeReadyRemovedToast(_ count: Int) -> String {
        resolvedKaraokeInflection(LocalizedStringResource(
            "app.karaoke.ready.removedToast",
            defaultValue: "Removed ^[\(count) karaoke version](inflect: true)",
            comment: "Toast shown after cached karaoke instrumentals are deleted"
        ))
    }

    /// The partial-removal toast: some selected instrumentals were skipped because they
    /// are pinned (playing or pre-scheduled), so the user is told they were kept.
    static func karaokeReadyRemovedKeptInUseToast(_ count: Int) -> String {
        resolvedKaraokeInflection(LocalizedStringResource(
            "app.karaoke.ready.removedKeptInUseToast",
            defaultValue: "Removed ^[\(count) karaoke version](inflect: true); the one in use was kept",
            comment: "Toast after deleting karaoke instrumentals when an in-use one was skipped"
        ))
    }

    static let karaokeReadyKeptInUseToast = LocalizedStringResource(
        "app.karaoke.ready.keptInUseToast",
        defaultValue: "Kept — this karaoke version is in use",
        comment: "Toast when every selected karaoke instrumental was skipped because it is playing"
    )

    /// `String(localized:)` does NOT run `^[…](inflect: true)` morphology on an inline
    /// `defaultValue` (it returns raw markup); `AttributedString` does.
    private static func resolvedKaraokeInflection(_ resource: LocalizedStringResource) -> String {
        String(AttributedString(localized: resource).characters)
    }
}
