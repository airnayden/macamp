// ReplayGainTagStrings — copy for the library selection's loudness actions and the
// tag-write confirmation sheet.
//
// The three refusal lines are one per ``ReplayGainTagUnsupportedReason``, and they
// say WHY rather than just "skipped": an M4A owner told only that their files were
// skipped has no way to learn that this build's tag backend discards MP4 ReplayGain
// atoms, and would reasonably conclude MacAMP is broken.
import Foundation

/// Catalog-resolved copy for "Analyze Loudness" and "Write ReplayGain Tags…".
enum ReplayGainTagStrings {
    // MARK: Context menu

    static let analyze = LocalizedStringResource(
        "app.replayGainTags.analyze",
        defaultValue: "Analyze Loudness",
        comment: "Context-menu action that measures the selected tracks' loudness"
    )
    static let write = LocalizedStringResource(
        "app.replayGainTags.write",
        defaultValue: "Write ReplayGain Tags…",
        comment: "Context-menu action that writes measured loudness into the selected files' tags"
    )

    // MARK: Confirmation sheet

    static let sheetTitle = LocalizedStringResource(
        "app.replayGainTags.sheetTitle",
        defaultValue: "Write ReplayGain tags?",
        comment: "Title of the sheet confirming a tag write"
    )
    static let confirm = LocalizedStringResource(
        "app.replayGainTags.confirm",
        defaultValue: "Write Tags",
        comment: "Primary button that performs the confirmed tag write"
    )
    static let cancel = LocalizedStringResource(
        "app.replayGainTags.cancel",
        defaultValue: "Cancel",
        comment: "Cancel button of the tag-write confirmation sheet"
    )
    static let unmeasuredNote = LocalizedStringResource(
        "app.replayGainTags.unmeasuredNote",
        defaultValue: """
        Tracks MacAMP has not measured yet are left untouched. \
        Scan your library first in Settings ▸ Playback ▸ Loudness.
        """,
        comment: "Explains that unmeasured files are left alone and how to measure them"
    )
    static let nothingEligible = LocalizedStringResource(
        "app.replayGainTags.nothingEligible",
        defaultValue: "None of the selected files can carry ReplayGain tags.",
        comment: "Shown when a selection contains no file whose format MacAMP writes tags to"
    )

    static func fileCount(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.replayGainTags.fileCount",
            defaultValue: "MacAMP will rewrite the tags of \(count.formatted()) files.",
            comment: "Names exactly how many files a confirmed tag write would change"
        )
    }

    static func skipOggFamily(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.replayGainTags.skip.oggFamily",
            defaultValue: """
            \(count.formatted()) Ogg or Opus files are skipped — \
            they normalise against a different reference level.
            """,
            comment: "Refusal line for the Ogg family, which may carry R128 rather than ReplayGain"
        )
    }

    static func skipMP4Family(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.replayGainTags.skip.mp4Family",
            defaultValue: """
            \(count.formatted()) MP4 or M4A files are skipped — \
            this version cannot store ReplayGain tags in them.
            """,
            comment: "Refusal line for the MP4 family, whose ReplayGain atoms the tag backend discards"
        )
    }

    static func skipUnverified(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.replayGainTags.skip.unverified",
            defaultValue: """
            \(count.formatted()) files are skipped — \
            MacAMP has not verified ReplayGain tags in their format.
            """,
            comment: "Refusal line for every format outside the verified allow-list"
        )
    }

    // MARK: Outcome

    static func writtenToast(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.replayGainTags.writtenToast",
            defaultValue: "ReplayGain tags written to \(count.formatted()) files",
            comment: "Toast summarising a successful tag write"
        )
    }

    static let nothingWrittenToast = LocalizedStringResource(
        "app.replayGainTags.nothingWrittenToast",
        defaultValue: "Nothing was written — those tracks have not been measured yet",
        comment: "Toast shown when every eligible file lacked a measurement"
    )

    static func failedToast(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.replayGainTags.failedToast",
            defaultValue: "\(count.formatted()) files could not be updated",
            comment: "Toast reporting files the tag writer could not rewrite"
        )
    }

    static func analyzeToast(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.replayGainTags.analyzeToast",
            defaultValue: "Measuring loudness for \(count.formatted()) tracks",
            comment: "Toast confirming a selection was queued for loudness analysis"
        )
    }
}
