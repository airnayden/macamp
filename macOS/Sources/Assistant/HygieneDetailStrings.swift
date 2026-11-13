// Localized chrome for the library-health detail sheet.
//
// The `app.assistant.hygiene.*` namespace follows the reasoning in
// ``AssistantPaneStrings``: PlayerCore owns the bare `assistant.*` prefix, so
// shell-only copy keeps the shell's `app.*` prefix and the key-sync checker can
// never confuse the two sets. The four pre-existing summary-card keys
// (`app.assistant.hygieneTitle` and friends) predate this file and stay where they
// are — this sheet is a different surface and gets its own sub-namespace.
//
// WHAT IS NOT HERE: the findings themselves. A track title, an artist, a genre
// spelling and a file name are all DATA — read verbatim off the library — and every
// one of them is rendered `Text(verbatim:)`. Only the words MacAMP itself wrote live
// in this file.
//
// THREE INTERPOLATED RESOURCES, DELIBERATELY. A finding is only legible with its own
// numbers in it ("3 copies in your library" says something "Duplicate" does not), so
// ``duplicateCopies(count:)``, ``duplicatePlaylists(count:)`` and
// ``genreVariants(spellings:tracks:)`` carry them. Interpolated resources are NOT
// hand-synced into the String Catalog — the shipped convention that
// ``ProposalPreviewStrings/confirmMessage(count:)`` documents: a hand-written entry
// would need `%@` placeholders plus substitution metadata that only Xcode's
// extraction gets right. The sync script skips and reports them.
import Foundation

enum HygieneDetailStrings {
    // MARK: Sheet chrome

    static let title = LocalizedStringResource(
        "app.assistant.hygiene.title",
        defaultValue: "Things Worth Reviewing",
        comment: "Title of the sheet listing what the library hygiene pass found"
    )
    static let subtitle = LocalizedStringResource(
        "app.assistant.hygiene.subtitle",
        defaultValue: "Nothing changes until you review a suggestion and apply it.",
        comment: "Caption under the library-health sheet title, stating that the list is read-only"
    )
    static let close = LocalizedStringResource(
        "app.assistant.hygiene.close",
        defaultValue: "Done",
        comment: "Button that closes the library-health sheet"
    )
    static let closeHelp = LocalizedStringResource(
        "app.assistant.hygiene.closeHelp",
        defaultValue: "Close this list — nothing is changed",
        comment: "Tooltip on the button that closes the library-health sheet"
    )
    static let openCard = LocalizedStringResource(
        "app.assistant.hygiene.openCard",
        defaultValue: "See what MacAMP found",
        comment: "Accessibility hint and tooltip on the library-health card that opens the detail sheet"
    )

    // MARK: Sections

    static let duplicatesSection = LocalizedStringResource(
        "app.assistant.hygiene.duplicatesSection",
        defaultValue: "Duplicates",
        comment: "Header above the recordings the library holds more than once"
    )
    static let genresSection = LocalizedStringResource(
        "app.assistant.hygiene.genresSection",
        defaultValue: "Genre spellings",
        comment: "Header above the genres that are spelled more than one way"
    )
    static let gapsSection = LocalizedStringResource(
        "app.assistant.hygiene.gapsSection",
        defaultValue: "Missing tags",
        comment: "Header above the tracks that are missing genre, year or album artist"
    )

    // MARK: Actions

    static let review = LocalizedStringResource(
        "app.assistant.hygiene.review",
        defaultValue: "Review",
        comment: "Button that opens the proposal preview for one library-health finding"
    )
    static let reviewHelp = LocalizedStringResource(
        "app.assistant.hygiene.reviewHelp",
        defaultValue: "See exactly what this would change before anything is saved",
        comment: "Tooltip on the per-finding review button"
    )
    static let reviewAll = LocalizedStringResource(
        "app.assistant.hygiene.reviewAll",
        defaultValue: "Review All",
        comment: "Button that opens the proposal previews for every finding in one section"
    )
    static let reviewAllHelp = LocalizedStringResource(
        "app.assistant.hygiene.reviewAllHelp",
        defaultValue: "Step through every suggestion in this section, one at a time",
        comment: "Tooltip on the per-section review-all button"
    )

    // MARK: States

    static let emptyTitle = LocalizedStringResource(
        "app.assistant.hygiene.emptyTitle",
        defaultValue: "Your Library Looks Tidy",
        comment: "Empty state title on the library-health sheet when the pass found nothing"
    )
    static let emptyMessage = LocalizedStringResource(
        "app.assistant.hygiene.emptyMessage",
        defaultValue: "No duplicates, no mixed genre spellings and no missing tags.",
        comment: "Empty state message on the library-health sheet when the pass found nothing"
    )
    static let nothingToApply = LocalizedStringResource(
        "app.assistant.hygiene.nothingToApply",
        defaultValue: "Worth knowing about — but there is nothing here for MacAMP to change.",
        comment: "Caption on a finding that carries no change the listener could accept"
    )
    static let missingLabel = LocalizedStringResource(
        "app.assistant.hygiene.missingLabel",
        defaultValue: "Missing",
        comment: "Label before the list of tag fields a track has no value for"
    )
    static let duplicateNoPlaylists = LocalizedStringResource(
        "app.assistant.hygiene.duplicateNoPlaylists",
        defaultValue: "No playlist plays it twice, so both copies are left alone.",
        comment: "Detail on a duplicate group that no playlist lists more than once"
    )

    // MARK: Finding detail (interpolated — see the file header)

    /// How many library rows are the same recording.
    static func duplicateCopies(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.hygiene.duplicateCopies",
            defaultValue: "\(count) copies of this recording in your library",
            comment: "Detail line stating how many library rows are the same recording"
        )
    }

    /// How many playlists list the recording more than once.
    static func duplicatePlaylists(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.hygiene.duplicatePlaylists",
            defaultValue: "Played twice in \(count) of your playlists",
            comment: "Detail line stating how many playlists list the same recording more than once"
        )
    }

    /// How many minority spellings a genre cluster carries, and how many tracks
    /// would be retagged onto the canonical one.
    static func genreVariants(spellings: Int, tracks: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.hygiene.genreVariants",
            defaultValue: "\(spellings) other spellings on \(tracks) tracks",
            comment: "Detail line stating how many genre spelling variants exist and how many tracks carry them"
        )
    }
}
