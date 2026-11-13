// ProposalPreviewFailureStrings — the sheet's apply-failure copy.
//
// Split out of ``ProposalPreviewStrings`` for one reason and no other: the combined
// enum body breached SwiftLint's 250-line `type_body_length` budget. Members declared
// in an extension are not counted against the main declaration, so this keeps every
// call site — `ProposalPreviewModel.message(for:)` and ``AssistantErrorCopy`` — spelled
// exactly as before.
//
// Same namespace rules as the parent file: `app.assistant.preview.*`, chrome only,
// never the proposal's own content.
import Foundation

extension ProposalPreviewStrings {
    static let failurePlaylistChanged = LocalizedStringResource(
        "app.assistant.preview.failurePlaylistChanged",
        defaultValue: "This playlist changed after the preview. Generate a new suggestion and try again.",
        comment: "A stale playlist proposal was refused without changing membership"
    )
    static let failureBatchNotConfirmed = LocalizedStringResource(
        "app.assistant.preview.failureBatchNotConfirmed",
        defaultValue: "Tag changes need their own confirmation before anything is written.",
        comment: "Shown when a tag batch reached the writer without the extra confirmation"
    )
    static let failureUnknownProposal = LocalizedStringResource(
        "app.assistant.preview.failureUnknownProposal",
        defaultValue: "This suggestion isn't available any more.",
        comment: "Shown when the proposal being applied was already applied or discarded"
    )
    static let failurePlaylistNotCreated = LocalizedStringResource(
        "app.assistant.preview.failurePlaylistNotCreated",
        defaultValue: "MacAMP couldn't create the playlist.",
        comment: "Shown when the repository created a playlist but returned no identifier"
    )
    static let failurePlaylistNotFound = LocalizedStringResource(
        "app.assistant.preview.failurePlaylistNotFound",
        defaultValue: "That playlist doesn't exist any more, so nothing was changed.",
        comment: "Shown when a rename or reorganisation names a playlist that has since been deleted"
    )
    static let failureWriterUnavailable = LocalizedStringResource(
        "app.assistant.preview.failureWriterUnavailable",
        defaultValue: "Tag editing isn't available right now.",
        comment: "Shown when a tag proposal is applied on a build composed without a tag writer"
    )
    static let failureTagWrite = LocalizedStringResource(
        "app.assistant.preview.failureTagWrite",
        defaultValue: "MacAMP couldn't write the tags. Files earlier in the batch may already be updated — applying again is safe.",
        comment: "Shown when a tag write failed part-way through a batch"
    )
    static let failureNoMatchingTracks = LocalizedStringResource(
        "app.assistant.preview.failureNoMatchingTracks",
        defaultValue: "Nothing in your library matched that request.",
        comment: "Shown when a request was understood but selected no playable tracks"
    )
    static let failureGeneration = LocalizedStringResource(
        "app.assistant.preview.failureGeneration",
        defaultValue: "MacAMP couldn't read your library to build that suggestion.",
        comment: "Shown when a read failed while building a proposal; nothing was written"
    )
    static let failureUnexpected = LocalizedStringResource(
        "app.assistant.preview.failureUnexpected",
        defaultValue: "Something went wrong, so nothing was changed. The suggestion is still here — try again.",
        comment: "Shown when applying failed with an error the assistant does not classify"
    )
}
