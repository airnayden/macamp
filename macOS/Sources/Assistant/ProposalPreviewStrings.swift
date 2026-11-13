// Localized chrome for the proposal preview sheet and its tag-batch confirmation.
//
// The `app.assistant.preview.*` namespace follows `AssistantPaneStrings`' reasoning:
// PlayerCore owns `assistant.*`, so shell-only copy keeps the shell's `app.*` prefix
// and the two sets can never be confused by the key-sync checker.
//
// WHAT IS NOT HERE: the proposal's own content. A generated playlist name, a summary,
// a file name and a new tag value are all DATA — produced in the listener's language
// at generation time, or read verbatim off disk — and the sheet renders every one of
// them `Text(verbatim:)`. Only the words MacAMP itself wrote live in this file.
//
// ONE INTERPOLATED RESOURCE, DELIBERATELY. ``confirmMessage(count:)`` carries the
// number of files a tag batch would rewrite, because "this rewrites files on disk"
// without saying how many is the weaker warning. Interpolated resources are NOT
// hand-synced into the String Catalog — the shipped convention
// (`app.preferences.enrichment.count` / `.summary` are absent for the same reason):
// a hand-written entry would need `%@` placeholders plus substitution metadata that
// only Xcode's extraction gets right. The sync script skips and reports it.
import Foundation

enum ProposalPreviewStrings {
    // MARK: Sheet chrome

    static let title = LocalizedStringResource(
        "app.assistant.preview.title",
        defaultValue: "Review Before Saving",
        comment: "Title of the sheet that previews an AI proposal before it is applied"
    )
    static let apply = LocalizedStringResource(
        "app.assistant.preview.apply",
        defaultValue: "Apply",
        comment: "Button that commits the previewed proposal"
    )
    static let applyHelp = LocalizedStringResource(
        "app.assistant.preview.applyHelp",
        defaultValue: "Save these changes to your library",
        comment: "Tooltip on the button that commits the previewed proposal"
    )
    static let discard = LocalizedStringResource(
        "app.assistant.preview.discard",
        defaultValue: "Discard",
        comment: "Button that throws the previewed proposal away without applying it"
    )
    static let discardHelp = LocalizedStringResource(
        "app.assistant.preview.discardHelp",
        defaultValue: "Throw this suggestion away — nothing is changed",
        comment: "Tooltip on the button that dismisses a proposal without applying it"
    )
    static let loading = LocalizedStringResource(
        "app.assistant.preview.loading",
        defaultValue: "Looking up the tracks…",
        comment: "Progress caption while the preview resolves track titles"
    )
    static let affectedLabel = LocalizedStringResource(
        "app.assistant.preview.affectedLabel",
        defaultValue: "Tracks affected",
        comment: "Label beside the count of rows or files a proposal would touch"
    )
    static let unknownTrack = LocalizedStringResource(
        "app.assistant.preview.unknownTrack",
        defaultValue: "No longer in your library",
        comment: "Placeholder for a proposed track whose library row could not be resolved"
    )
    static let truncated = LocalizedStringResource(
        "app.assistant.preview.truncated",
        defaultValue: "Only the first tracks are listed here. Applying uses the whole list.",
        comment: "Caption shown when a proposal is longer than the preview window"
    )
    /// The second half of the truncation caption.
    ///
    /// A separate key rather than a longer ``truncated``: that string is already
    /// translated into six languages, and rewriting it would strand every one of them
    /// on a sentence that no longer says what the checkboxes made true.
    static let truncatedAlwaysIncluded = LocalizedStringResource(
        "app.assistant.preview.truncatedAlwaysIncluded",
        defaultValue: "Tracks past the end of this list can't be unticked — they are always included.",
        comment: "Caption explaining that tracks beyond the preview window cannot be deselected"
    )

    // MARK: Selection

    static let selectedLabel = LocalizedStringResource(
        "app.assistant.preview.selectedLabel",
        defaultValue: "Tracks selected",
        comment: "Label beside the ticked-of-total count in the preview header"
    )
    static let selectAll = LocalizedStringResource(
        "app.assistant.preview.selectAll",
        defaultValue: "Select All",
        comment: "Button that ticks every track in one section of the proposal preview"
    )
    static let deselectAll = LocalizedStringResource(
        "app.assistant.preview.deselectAll",
        defaultValue: "Deselect All",
        comment: "Button that unticks every track in one section of the proposal preview"
    )
    static let includeTrack = LocalizedStringResource(
        "app.assistant.preview.includeTrack",
        defaultValue: "Include this track",
        comment: "Accessibility label and tooltip for the per-track checkbox in the proposal preview"
    )
    static let nothingSelected = LocalizedStringResource(
        "app.assistant.preview.nothingSelected",
        defaultValue: "Tick at least one track before applying.",
        comment: "Caption explaining why Apply is unavailable once every track has been unticked"
    )

    // MARK: Create

    static let newPlaylistLabel = LocalizedStringResource(
        "app.assistant.preview.newPlaylistLabel",
        defaultValue: "New playlist",
        comment: "Label above the generated name of a playlist the assistant would create"
    )
    static let tracksSection = LocalizedStringResource(
        "app.assistant.preview.tracksSection",
        defaultValue: "Tracks",
        comment: "Header above the proposed track list"
    )
    static let lowConfidence = LocalizedStringResource(
        "app.assistant.preview.lowConfidence",
        defaultValue: "Here's a starting point — MacAMP wasn't sure what you meant, so try rewording the request if this isn't it.",
        comment: "Caption shown when the request could not be parsed and a default mix was produced instead"
    )

    // MARK: Organize

    static let additionsSection = LocalizedStringResource(
        "app.assistant.preview.additionsSection",
        defaultValue: "Adding",
        comment: "Header above the tracks a playlist reorganisation would add"
    )
    static let removalsSection = LocalizedStringResource(
        "app.assistant.preview.removalsSection",
        defaultValue: "Removing",
        comment: "Header above the tracks a playlist reorganisation would drop"
    )
    static let movesSection = LocalizedStringResource(
        "app.assistant.preview.movesSection",
        defaultValue: "Moving",
        comment: "Header above the tracks a playlist reorganisation would reposition"
    )
    static let noChanges = LocalizedStringResource(
        "app.assistant.preview.noChanges",
        defaultValue: "This would change nothing.",
        comment: "Shown when a reorganisation proposal turns out to be a no-op"
    )

    // MARK: Rename

    static let renameCurrentLabel = LocalizedStringResource(
        "app.assistant.preview.renameCurrentLabel",
        defaultValue: "Current name",
        comment: "Label beside a playlist's existing name in a rename preview"
    )
    static let renameProposedLabel = LocalizedStringResource(
        "app.assistant.preview.renameProposedLabel",
        defaultValue: "New name",
        comment: "Label beside the name a rename proposal would apply"
    )

    // MARK: Tags

    static let tagsSection = LocalizedStringResource(
        "app.assistant.preview.tagsSection",
        defaultValue: "Tag changes",
        comment: "Header above the table of per-file tag edits a proposal would write"
    )
    static let confirmTitle = LocalizedStringResource(
        "app.assistant.preview.confirmTitle",
        defaultValue: "Write these tags to disk?",
        comment: "Title of the extra confirmation raised before any tag batch is written"
    )
    static let confirmApply = LocalizedStringResource(
        "app.assistant.preview.confirmApply",
        defaultValue: "Write Tags",
        comment: "Confirming button in the tag-batch confirmation; the only path that writes tags"
    )
    static let confirmCancel = LocalizedStringResource(
        "app.assistant.preview.confirmCancel",
        defaultValue: "Cancel",
        comment: "Cancelling button in the tag-batch confirmation; applies nothing"
    )

    /// The tag-batch warning, carrying how many files it covers.
    ///
    /// Interpolated on purpose, and therefore absent from the String Catalog — see
    /// the file header.
    static func confirmMessage(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.preview.confirmMessage",
            defaultValue: "\(count) files will be rewritten where they sit on disk. MacAMP can't undo this for you.",
            comment: "Message in the tag-batch confirmation, warning that files on disk are rewritten"
        )
    }

    // MARK: Tag field labels

    static let fieldTitle = LocalizedStringResource(
        "app.assistant.preview.fieldTitle",
        defaultValue: "Title",
        comment: "Label for a proposed change to a track's title tag"
    )
    static let fieldArtist = LocalizedStringResource(
        "app.assistant.preview.fieldArtist",
        defaultValue: "Artist",
        comment: "Label for a proposed change to a track's artist tag"
    )
    static let fieldAlbum = LocalizedStringResource(
        "app.assistant.preview.fieldAlbum",
        defaultValue: "Album",
        comment: "Label for a proposed change to a track's album tag"
    )
    static let fieldAlbumArtist = LocalizedStringResource(
        "app.assistant.preview.fieldAlbumArtist",
        defaultValue: "Album artist",
        comment: "Label for a proposed change to a track's album-artist tag"
    )
    static let fieldGenre = LocalizedStringResource(
        "app.assistant.preview.fieldGenre",
        defaultValue: "Genre",
        comment: "Label for a proposed change to a track's genre tag"
    )
    static let fieldComposer = LocalizedStringResource(
        "app.assistant.preview.fieldComposer",
        defaultValue: "Composer",
        comment: "Label for a proposed change to a track's composer tag"
    )
    static let fieldYear = LocalizedStringResource(
        "app.assistant.preview.fieldYear",
        defaultValue: "Year",
        comment: "Label for a proposed change to a track's release-year tag"
    )
    static let fieldTrackNumber = LocalizedStringResource(
        "app.assistant.preview.fieldTrackNumber",
        defaultValue: "Track number",
        comment: "Label for a proposed change to a track's track-number tag"
    )
    static let fieldDiscNumber = LocalizedStringResource(
        "app.assistant.preview.fieldDiscNumber",
        defaultValue: "Disc number",
        comment: "Label for a proposed change to a track's disc-number tag"
    )
    static let fieldArtworkReplaced = LocalizedStringResource(
        "app.assistant.preview.fieldArtworkReplaced",
        defaultValue: "Artwork replaced",
        comment: "Row shown when a tag proposal would swap a file's embedded cover art"
    )
    static let fieldArtworkRemoved = LocalizedStringResource(
        "app.assistant.preview.fieldArtworkRemoved",
        defaultValue: "Artwork removed",
        comment: "Row shown when a tag proposal would strip a file's embedded cover art"
    )
    static let fieldsUnchanged = LocalizedStringResource(
        "app.assistant.preview.fieldsUnchanged",
        defaultValue: "No fields would change",
        comment: "Row shown for a tag patch that turns out to be empty"
    )
}
