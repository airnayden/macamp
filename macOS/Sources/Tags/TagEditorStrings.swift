// TagEditorStrings — localized copy for the macOS tag editor.
//
// Extends the shell's ``MacAMPStrings`` enum so every user-facing string in the
// tag editor is a `LocalizedStringResource` key with an English `defaultValue` —
// never a bare literal — keeping the editor localization-clean and
// `check-hardcoded-strings` safe. Keys follow the shell's `app.tags.<element>`
// namespace (the iOS shell uses `ios.tags.*`; the two catalogs are separate).
import Foundation

extension MacAMPStrings {
    // MARK: Context-menu entry points

    /// Row context-menu item that opens the editor for a single track.
    static let tagsMenuSingle = LocalizedStringResource(
        "app.tags.menu.single",
        defaultValue: "Edit Tags…",
        comment: "Context-menu item that opens the tag editor for one track"
    )

    /// Row context-menu item that opens the editor for the multi-selection.
    static func tagsMenuMulti(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.tags.menu.multi",
            defaultValue: "Edit Tags for \(count) Items…",
            comment: "Context-menu item that opens the batch tag editor for N selected tracks"
        )
    }

    // MARK: Editor titles

    /// Sheet title when editing one track.
    static let tagsEditorTitleSingle = LocalizedStringResource(
        "app.tags.title.single",
        defaultValue: "Edit Tags",
        comment: "Title of the single-track tag editor sheet"
    )

    /// Sheet title when editing several tracks at once.
    static func tagsEditorTitleMulti(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.tags.title.multi",
            defaultValue: "Edit \(count) Tracks",
            comment: "Title of the batch tag editor sheet"
        )
    }

    // MARK: Sections

    static let tagsSectionDetails = LocalizedStringResource(
        "app.tags.section.details",
        defaultValue: "Details",
        comment: "Editor section grouping the textual tag fields"
    )
    static let tagsSectionNumbering = LocalizedStringResource(
        "app.tags.section.numbering",
        defaultValue: "Numbering",
        comment: "Editor section grouping year, track and disc numbers"
    )
    static let tagsSectionArtwork = LocalizedStringResource(
        "app.tags.section.artwork",
        defaultValue: "Artwork",
        comment: "Editor section for the embedded cover art"
    )

    // MARK: Field labels

    static let tagsFieldTitle = LocalizedStringResource(
        "app.tags.field.title",
        defaultValue: "Title",
        comment: "Tag editor field label for the track title"
    )
    static let tagsFieldArtist = LocalizedStringResource(
        "app.tags.field.artist",
        defaultValue: "Artist",
        comment: "Tag editor field label for the track artist"
    )
    static let tagsFieldAlbum = LocalizedStringResource(
        "app.tags.field.album",
        defaultValue: "Album",
        comment: "Tag editor field label for the album title"
    )
    static let tagsFieldAlbumArtist = LocalizedStringResource(
        "app.tags.field.albumArtist",
        defaultValue: "Album Artist",
        comment: "Tag editor field label for the album artist"
    )
    static let tagsFieldGenre = LocalizedStringResource(
        "app.tags.field.genre",
        defaultValue: "Genre",
        comment: "Tag editor field label for the genre"
    )
    static let tagsFieldComposer = LocalizedStringResource(
        "app.tags.field.composer",
        defaultValue: "Composer",
        comment: "Tag editor field label for the composer"
    )
    static let tagsFieldYear = LocalizedStringResource(
        "app.tags.field.year",
        defaultValue: "Year",
        comment: "Tag editor field label for the release year"
    )
    static let tagsFieldTrackNumber = LocalizedStringResource(
        "app.tags.field.trackNumber",
        defaultValue: "Track Number",
        comment: "Tag editor field label for the track number"
    )
    static let tagsFieldDiscNumber = LocalizedStringResource(
        "app.tags.field.discNumber",
        defaultValue: "Disc Number",
        comment: "Tag editor field label for the disc number"
    )

    /// Placeholder shown for a batch field whose tracks disagree.
    static let tagsMultipleValues = LocalizedStringResource(
        "app.tags.multipleValues",
        defaultValue: "(Multiple Values)",
        comment: "Placeholder for a batch tag field whose selected tracks hold different values"
    )

    // MARK: Artwork controls

    static let tagsArtworkReplace = LocalizedStringResource(
        "app.tags.artwork.replace",
        defaultValue: "Replace…",
        comment: "Button that picks a new cover image"
    )
    static let tagsArtworkRemove = LocalizedStringResource(
        "app.tags.artwork.remove",
        defaultValue: "Remove",
        comment: "Button that clears the embedded cover art"
    )
    static let tagsArtworkNone = LocalizedStringResource(
        "app.tags.artwork.none",
        defaultValue: "No Artwork",
        comment: "Caption shown when a track carries no embedded cover art"
    )
    static let tagsArtworkDropHint = LocalizedStringResource(
        "app.tags.artwork.dropHint",
        defaultValue: "Drag an image here, or click Replace.",
        comment: "Hint explaining how to set cover art"
    )
    static let tagsArtworkBatchNote = LocalizedStringResource(
        "app.tags.artwork.batchNote",
        defaultValue: "Replacing or removing artwork applies to every selected track.",
        comment: "Note clarifying that batch artwork edits affect all selected tracks"
    )

    // MARK: Read-only gating

    static let tagsReadOnlyBadge = LocalizedStringResource(
        "app.tags.readOnly.badge",
        defaultValue: "Read-only source",
        comment: "Badge marking a file whose tags cannot be written"
    )
    static let tagsReadOnlyMessage = LocalizedStringResource(
        "app.tags.readOnly.message",
        defaultValue: "These files can’t be written — they may be missing, locked, or in a format MacAMP can’t tag.",
        comment: "Explanation shown when the selected file(s) cannot be written on macOS"
    )

    // MARK: Toolbar + results

    static let tagsSave = LocalizedStringResource(
        "app.tags.action.save",
        defaultValue: "Save",
        comment: "Button that writes the edited tags"
    )
    static let tagsCancel = LocalizedStringResource(
        "app.tags.action.cancel",
        defaultValue: "Cancel",
        comment: "Button that dismisses the editor without saving"
    )
    static let tagsResultTitle = LocalizedStringResource(
        "app.tags.result.title",
        defaultValue: "Couldn’t Save Some Tracks",
        comment: "Alert title shown when one or more tracks failed to write"
    )
    static let tagsResultDismiss = LocalizedStringResource(
        "app.tags.result.dismiss",
        defaultValue: "OK",
        comment: "Button that dismisses the batch-write result alert"
    )

    /// Summary of a batch write: how many succeeded and how many failed.
    static func tagsResultMessage(succeeded: Int, failed: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.tags.result.message",
            defaultValue: "\(succeeded) updated, \(failed) failed.",
            comment: "Alert body summarizing a batch tag write outcome"
        )
    }

    // MARK: Online auto-fill

    static let tagsAutoFill = LocalizedStringResource(
        "app.tags.autoFill.button",
        defaultValue: "Auto-fill from MusicBrainz",
        comment: "Button that fetches missing tag fields from the MusicBrainz online database"
    )
    static let tagsAutoFillHelp = LocalizedStringResource(
        "app.tags.autoFill.help",
        defaultValue: "Look up this track on MusicBrainz and fill in any empty fields.",
        comment: "Tooltip explaining the Auto-fill button"
    )
    static let tagsAutoFillNoMatch = LocalizedStringResource(
        "app.tags.autoFill.noMatch",
        defaultValue: "No match found",
        comment: "Toast shown when MusicBrainz has no match for the track"
    )
}
