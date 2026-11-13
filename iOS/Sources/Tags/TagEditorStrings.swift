// TagEditorStrings — localized copy for the iOS tag editor (Task 17).
//
// Extends the shell's ``MacAMPStrings`` enum (the convention established in Task
// 25 / `MacAMPStrings.swift`) so every user-facing string in the tag editor is a
// `LocalizedStringResource` key with an English `defaultValue` — never a bare
// literal — keeping the editor localization-clean and `check-hardcoded-strings`
// safe. Keys follow the `ios.tags.<element>` namespace.
import Foundation

extension MacAMPStrings {
    // MARK: Context-menu entry points

    /// Row context-menu item that opens the editor for a single track.
    static let tagsMenuSingle = LocalizedStringResource(
        "ios.tags.menu.single",
        defaultValue: "Edit Tags…",
        comment: "Context-menu item that opens the tag editor for one track"
    )

    /// Row context-menu item that opens the editor for the multi-selection.
    static func tagsMenuMulti(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "ios.tags.menu.multi",
            defaultValue: "Edit Tags for \(count) Items…",
            comment: "Context-menu item that opens the batch tag editor for N selected tracks"
        )
    }

    /// Row context-menu item that opens the editor and runs online auto-fill.
    static let tagsMenuAutoFill = LocalizedStringResource(
        "ios.tags.menu.autoFill",
        defaultValue: "Auto-fill Tags…",
        comment: "Context-menu item that opens the tag editor and fetches missing metadata online"
    )

    // MARK: Editor titles

    /// Navigation title when editing one track.
    static let tagsEditorTitleSingle = LocalizedStringResource(
        "ios.tags.title.single",
        defaultValue: "Edit Tags",
        comment: "Navigation title of the single-track tag editor"
    )

    /// Navigation title when editing several tracks at once.
    static func tagsEditorTitleMulti(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "ios.tags.title.multi",
            defaultValue: "Edit \(count) Tracks",
            comment: "Navigation title of the batch tag editor"
        )
    }

    // MARK: Sections

    static let tagsSectionDetails = LocalizedStringResource(
        "ios.tags.section.details",
        defaultValue: "Details",
        comment: "Editor section grouping the textual tag fields"
    )
    static let tagsSectionNumbering = LocalizedStringResource(
        "ios.tags.section.numbering",
        defaultValue: "Numbering",
        comment: "Editor section grouping year, track and disc numbers"
    )
    static let tagsSectionArtwork = LocalizedStringResource(
        "ios.tags.section.artwork",
        defaultValue: "Artwork",
        comment: "Editor section for the embedded cover art"
    )

    // MARK: Field labels

    static let tagsFieldTitle = LocalizedStringResource(
        "ios.tags.field.title",
        defaultValue: "Title",
        comment: "Tag editor field label for the track title"
    )
    static let tagsFieldArtist = LocalizedStringResource(
        "ios.tags.field.artist",
        defaultValue: "Artist",
        comment: "Tag editor field label for the track artist"
    )
    static let tagsFieldAlbum = LocalizedStringResource(
        "ios.tags.field.album",
        defaultValue: "Album",
        comment: "Tag editor field label for the album title"
    )
    static let tagsFieldAlbumArtist = LocalizedStringResource(
        "ios.tags.field.albumArtist",
        defaultValue: "Album Artist",
        comment: "Tag editor field label for the album artist"
    )
    static let tagsFieldGenre = LocalizedStringResource(
        "ios.tags.field.genre",
        defaultValue: "Genre",
        comment: "Tag editor field label for the genre"
    )
    static let tagsFieldComposer = LocalizedStringResource(
        "ios.tags.field.composer",
        defaultValue: "Composer",
        comment: "Tag editor field label for the composer"
    )
    static let tagsFieldYear = LocalizedStringResource(
        "ios.tags.field.year",
        defaultValue: "Year",
        comment: "Tag editor field label for the release year"
    )
    static let tagsFieldTrackNumber = LocalizedStringResource(
        "ios.tags.field.trackNumber",
        defaultValue: "Track Number",
        comment: "Tag editor field label for the track number"
    )
    static let tagsFieldDiscNumber = LocalizedStringResource(
        "ios.tags.field.discNumber",
        defaultValue: "Disc Number",
        comment: "Tag editor field label for the disc number"
    )

    /// Placeholder shown for a batch field whose tracks disagree.
    static let tagsMultipleValues = LocalizedStringResource(
        "ios.tags.multipleValues",
        defaultValue: "(Multiple Values)",
        comment: "Placeholder for a batch tag field whose selected tracks hold different values"
    )

    // MARK: Artwork controls

    static let tagsArtworkReplace = LocalizedStringResource(
        "ios.tags.artwork.replace",
        defaultValue: "Replace…",
        comment: "Button that picks a new cover image"
    )
    static let tagsArtworkRemove = LocalizedStringResource(
        "ios.tags.artwork.remove",
        defaultValue: "Remove",
        comment: "Button that clears the embedded cover art"
    )
    static let tagsArtworkNone = LocalizedStringResource(
        "ios.tags.artwork.none",
        defaultValue: "No Artwork",
        comment: "Caption shown when a track carries no embedded cover art"
    )
    static let tagsArtworkDropHint = LocalizedStringResource(
        "ios.tags.artwork.dropHint",
        defaultValue: "Drag an image here, or tap Replace.",
        comment: "Hint explaining how to set cover art"
    )
    static let tagsArtworkBatchNote = LocalizedStringResource(
        "ios.tags.artwork.batchNote",
        defaultValue: "Replacing or removing artwork applies to every selected track.",
        comment: "Note clarifying that batch artwork edits affect all selected tracks"
    )

    // MARK: Read-only gating

    static let tagsReadOnlyBadge = LocalizedStringResource(
        "ios.tags.readOnly.badge",
        defaultValue: "Read-only source",
        comment: "Badge marking a file that cannot be written because it lacks a security-scoped bookmark"
    )
    static let tagsReadOnlyMessage = LocalizedStringResource(
        "ios.tags.readOnly.message",
        defaultValue: "This file is outside your imported folders, so its tags can’t be edited.",
        comment: "Explanation shown when the selected file cannot be written on iOS"
    )

    // MARK: Toolbar + results

    static let tagsSave = LocalizedStringResource(
        "ios.tags.action.save",
        defaultValue: "Save",
        comment: "Toolbar button that writes the edited tags"
    )
    static let tagsCancel = LocalizedStringResource(
        "ios.tags.action.cancel",
        defaultValue: "Cancel",
        comment: "Toolbar button that dismisses the editor without saving"
    )
    static let tagsResultTitle = LocalizedStringResource(
        "ios.tags.result.title",
        defaultValue: "Couldn’t Save Some Tracks",
        comment: "Alert title shown when one or more tracks failed to write"
    )

    /// Summary of a batch write: how many succeeded and how many failed.
    static func tagsResultMessage(succeeded: Int, failed: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "ios.tags.result.message",
            defaultValue: "\(succeeded) updated, \(failed) failed.",
            comment: "Alert body summarizing a batch tag write outcome"
        )
    }

    // MARK: Online auto-fill

    static let tagsAutoFill = LocalizedStringResource(
        "ios.tags.autoFill.button",
        defaultValue: "Auto-fill from MusicBrainz",
        comment: "Button that fetches missing tag fields from the MusicBrainz online database"
    )
    static let tagsAutoFillHint = LocalizedStringResource(
        "ios.tags.autoFill.hint",
        defaultValue: "Looks up this track on MusicBrainz and fills in any empty fields.",
        comment: "VoiceOver hint for the Auto-fill button"
    )
    static let tagsAutoFillBusy = LocalizedStringResource(
        "ios.tags.autoFill.busy",
        defaultValue: "Looking up…",
        comment: "Row shown while an online auto-fill lookup is in flight"
    )
    static let tagsAutoFillNoMatch = LocalizedStringResource(
        "ios.tags.autoFill.noMatch",
        defaultValue: "No match found",
        comment: "Caption shown when MusicBrainz has no match for the track"
    )
}
