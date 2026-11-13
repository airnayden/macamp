// Downloads History tab copy — the pane's tab names, empty state, row actions and the
// Clear History confirmation. Split from `DownloadsQueueStrings.swift` for the SwiftLint
// 400-line file budget; see `DownloadsStrings.swift` for why the shell's Downloads copy
// extends `MacAMPStrings` rather than `Services.DownloadsStrings`.
//
// ── EVERY DESTRUCTIVE SENTENCE SAYS WHAT IS *NOT* DESTROYED ─────────────────
//
// "Delete Entry" and "Clear History" remove rows from a log and never touch a file on
// disk. That is not obvious from either verb, and a listener who assumes otherwise will
// not use the feature — so the help text and the confirmation message both state the
// file's safety explicitly rather than leaving it to be discovered.
//
// The FORMAT BADGE ("M4A · Best") is composed at the call site from an untranslatable
// container token and the existing `PreferencesStrings.downloadsQualityName(_:)` copy,
// so there is no badge key here: the two halves are already translated in the one place
// the listener also picks them.
import Foundation

extension MacAMPStrings {
    // MARK: - Tabs

    static let downloadsTabsLabel = LocalizedStringResource(
        "app.downloads.tabs.label",
        defaultValue: "Downloads view",
        comment: "Accessibility label and tooltip for the Queue/History switch on the Downloads pane"
    )
    static let downloadsTabQueue = LocalizedStringResource(
        "app.downloads.tabs.queue",
        defaultValue: "Queue",
        comment: "Downloads pane tab showing downloads that are running or waiting"
    )
    static let downloadsTabHistory = LocalizedStringResource(
        "app.downloads.tabs.history",
        defaultValue: "History",
        comment: "Downloads pane tab showing downloads that already finished"
    )

    // MARK: - Pane chrome

    static let downloadsHistoryEmptyTitle = LocalizedStringResource(
        "app.downloads.history.emptyTitle",
        defaultValue: "No Downloads Yet",
        comment: "Empty-state title on the Downloads History tab when nothing has finished downloading"
    )
    static let downloadsHistoryEmptyMessage = LocalizedStringResource(
        "app.downloads.history.emptyMessage",
        defaultValue: "Completed and failed downloads appear here",
        comment: "Empty-state message on the Downloads History tab"
    )
    static let downloadsHistoryClear = LocalizedStringResource(
        "app.downloads.history.clear",
        defaultValue: "Clear History",
        comment: "Header button forgetting every entry in the download history"
    )
    static let downloadsHistoryClearHelp = LocalizedStringResource(
        "app.downloads.history.clear.help",
        defaultValue: "Forget every download listed here. The downloaded files are not deleted.",
        comment: """
        Tooltip for the Clear History button, stating plainly that only the log is \
        cleared and the audio files on disk survive
        """
    )
    static let downloadsHistoryClearConfirmTitle = LocalizedStringResource(
        "app.downloads.history.clear.confirmTitle",
        defaultValue: "Clear download history?",
        comment: "Confirmation dialog title before the whole download history is forgotten"
    )
    static let downloadsHistoryClearConfirmMessage = LocalizedStringResource(
        "app.downloads.history.clear.confirmMessage",
        defaultValue: "Every entry is forgotten. The files you downloaded stay exactly where they are.",
        comment: """
        Confirmation dialog message before the whole download history is forgotten, \
        stating that the audio files on disk are untouched
        """
    )
    static let downloadsHistoryClearConfirmAction = LocalizedStringResource(
        "app.downloads.history.clear.confirmAction",
        defaultValue: "Clear History",
        comment: "Destructive confirmation button forgetting every download-history entry"
    )
    static let downloadsHistoryClearCancel = LocalizedStringResource(
        "app.downloads.history.clear.cancel",
        defaultValue: "Cancel",
        comment: "Cancel button leaving the download history untouched"
    )

    // MARK: - Rows

    static let downloadsHistoryReveal = LocalizedStringResource(
        "app.downloads.history.reveal",
        defaultValue: "Reveal in Finder",
        comment: "Row action showing a downloaded file in the Finder"
    )
    static let downloadsHistoryRevealMissing = LocalizedStringResource(
        "app.downloads.history.reveal.missing",
        defaultValue: "File missing — it was moved, renamed or deleted",
        comment: """
        Tooltip on the disabled Reveal in Finder control, explaining that the downloaded \
        file is no longer at the path this entry recorded
        """
    )
    static let downloadsHistoryRedownload = LocalizedStringResource(
        "app.downloads.history.redownload",
        defaultValue: "Download Again",
        comment: "Row action queueing the entry's original link for download a second time"
    )
    static let downloadsHistoryRetry = LocalizedStringResource(
        "app.downloads.history.retry",
        defaultValue: "Retry",
        comment: "Row action moving a failed download back to the queue"
    )
    static let downloadsHistoryDelete = LocalizedStringResource(
        "app.downloads.history.delete",
        defaultValue: "Delete Entry",
        comment: "Row action removing one entry from the download history"
    )
    static let downloadsHistoryDeleteHelp = LocalizedStringResource(
        "app.downloads.history.delete.help",
        defaultValue: "Forget this download. The file itself is not deleted.",
        comment: """
        Tooltip for the Delete Entry action, stating plainly that only the log row goes \
        and the audio file on disk survives
        """
    )

    /// The absolute, capture-local moment a download finished — the tooltip behind a
    /// row's relative phrase.
    static func downloadsHistoryDownloadedAt(_ timestamp: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.downloads.history.downloadedAt",
            defaultValue: "Downloaded \(timestamp)",
            comment: """
            Tooltip naming the exact local date and time a download finished, in the \
            time zone it finished in
            """
        )
    }
}
