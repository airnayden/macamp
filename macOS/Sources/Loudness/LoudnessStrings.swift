// LoudnessStrings — every user-facing string of the loudness surface.
//
// Split from ``PreferencesStrings`` because this copy is read on two surfaces that
// are not both preferences: the Playback pane's Loudness section, and the library
// selection's own context menu and confirmation sheet.
import Foundation

/// Catalog-resolved copy for loudness analysis and ReplayGain tag writing.
enum LoudnessStrings {
    // MARK: Playback pane section

    static let section = LocalizedStringResource(
        "app.loudness.section",
        defaultValue: "Loudness",
        comment: "Header of the Playback-pane section that measures how loud each track is"
    )
    static let caption = LocalizedStringResource(
        "app.loudness.caption",
        defaultValue: """
        Measures how loud every track really is, so ReplayGain can even them out. \
        Runs only when you start it, never on import.
        """,
        comment: "Explains what the loudness pass does and that it never starts on its own"
    )
    static let scan = LocalizedStringResource(
        "app.loudness.scan",
        defaultValue: "Scan Library",
        comment: "Button that starts the loudness pass over the library"
    )
    static let scanHelp = LocalizedStringResource(
        "app.loudness.scanHelp",
        defaultValue: "Measure only the tracks that have no up-to-date loudness yet",
        comment: "Tooltip on the incremental Scan Library button"
    )
    static let rescan = LocalizedStringResource(
        "app.loudness.rescan",
        defaultValue: "Re-scan Library",
        comment: "Button that discards every cached loudness value and measures the library again"
    )
    static let rescanHelp = LocalizedStringResource(
        "app.loudness.rescanHelp",
        defaultValue: "Measure every track again, in case something was missed",
        comment: "Tooltip on the Re-scan Library button"
    )
    static let rescanConfirmTitle = LocalizedStringResource(
        "app.loudness.rescanConfirmTitle",
        defaultValue: "Measure your whole library again?",
        comment: "Title of the confirmation asked before a full loudness re-scan"
    )
    static let rescanConfirmMessage = LocalizedStringResource(
        "app.loudness.rescanConfirmMessage",
        defaultValue: """
        This discards every loudness value MacAMP has cached and decodes every audio file again. \
        On a large library it can take a long time. You can pause or stop it at any point, \
        and your music files are never changed.
        """,
        comment: "Honest description of what a full loudness re-scan costs"
    )
    static let rescanConfirmAction = LocalizedStringResource(
        "app.loudness.rescanConfirmAction",
        defaultValue: "Re-scan",
        comment: "Destructive confirm button of the full loudness re-scan dialog"
    )
    static let cancel = LocalizedStringResource(
        "app.loudness.cancel",
        defaultValue: "Cancel",
        comment: "Cancel button shared by the loudness dialogs"
    )
    static let running = LocalizedStringResource(
        "app.loudness.running",
        defaultValue: "Measuring…",
        comment: "Status shown while the loudness pass is running"
    )
    static let paused = LocalizedStringResource(
        "app.loudness.paused",
        defaultValue: "Paused",
        comment: "Status shown while a running loudness pass is suspended"
    )
    static let empty = LocalizedStringResource(
        "app.loudness.empty",
        defaultValue: "Nothing to measure yet — add music to your library first.",
        comment: "Coverage line shown when the library holds no measurable tracks"
    )

    /// "34% measured — 340 of 1,000 tracks". Reads "measured", never "complete":
    /// a permanently undecodable file is retried by every pass and never counted,
    /// so this figure can legitimately sit below 100% forever.
    static func coverage(percent: String, analyzed: Int, total: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.loudness.coverage",
            defaultValue: "\(percent) measured — \(analyzed.formatted()) of \(total.formatted()) tracks",
            comment: "Coverage line: share of the library carrying current loudness values"
        )
    }

    static func skipped(count: Int) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.loudness.skipped",
            defaultValue: "\(count.formatted()) tracks could not be measured and are skipped.",
            comment: "Footnote explaining why the measured percentage stays below 100%"
        )
    }
}
