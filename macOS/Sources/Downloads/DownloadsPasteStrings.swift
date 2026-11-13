// Paste-links sheet copy. Split from `DownloadsStrings.swift` for the SwiftLint
// file-length budget; see that file's header for why the shell's Downloads copy
// extends `MacAMPStrings` rather than `Services.DownloadsStrings`.
//
// Counted copy resolves through ``MacAMPStrings/downloadsInflected(_:)`` because
// `String(localized:)` returns raw `^[…](inflect: true)` markup for an inline
// `defaultValue`.
import Foundation

extension MacAMPStrings {
    // MARK: - Sheet chrome

    static let downloadsPasteTitle = LocalizedStringResource(
        "app.downloads.paste.title",
        defaultValue: "Add YouTube Links",
        comment: "Title of the sheet where YouTube links are pasted for download"
    )
    static let downloadsPasteMessage = LocalizedStringResource(
        "app.downloads.paste.message",
        defaultValue: "Paste one link per line. Videos, Shorts and playlists are all fine.",
        comment: "Instruction under the paste sheet's title"
    )
    static let downloadsPasteEditorLabel = LocalizedStringResource(
        "app.downloads.paste.editorLabel",
        defaultValue: "YouTube links",
        comment: "Accessibility label for the multi-line paste field"
    )
    static let downloadsPasteAdd = LocalizedStringResource(
        "app.downloads.paste.add",
        defaultValue: "Add",
        comment: "Button that parses the pasted text and queues the links it found"
    )
    static let downloadsPasteAddHelp = LocalizedStringResource(
        "app.downloads.paste.addHelp",
        defaultValue: "Queue every YouTube link in the text above",
        comment: "Tooltip for the paste sheet's Add button"
    )
    static let downloadsPasteCancel = LocalizedStringResource(
        "app.downloads.paste.cancel",
        defaultValue: "Cancel",
        comment: "Button dismissing the paste sheet before anything is queued"
    )
    static let downloadsPasteDone = LocalizedStringResource(
        "app.downloads.paste.done",
        defaultValue: "Done",
        comment: "Button dismissing the paste sheet after links have been queued"
    )
    static let downloadsPasteMenuItem = LocalizedStringResource(
        "app.downloads.paste.menuItem",
        defaultValue: "Add YouTube Links…",
        comment: "File menu item that opens the Downloads pane and its paste sheet"
    )
    static let downloadsPasteOpenHelp = LocalizedStringResource(
        "app.downloads.paste.openHelp",
        defaultValue: "Add YouTube links to the download queue",
        comment: "Tooltip for the Downloads pane toolbar button that opens the paste sheet"
    )
    /// Shown beside a spinner while Add or a playlist confirmation is in flight. That
    /// wait is a real `yt-dlp` spawn — a PyInstaller onefile binary that unpacks ~37 MB
    /// to `$TMPDIR` before it does any work, measured at ~12.6 s — so the sheet has to
    /// say it is working rather than sit there with two greyed buttons.
    static let downloadsPasteWorking = LocalizedStringResource(
        "app.downloads.paste.working",
        defaultValue: "Reading link details…",
        comment: "Busy caption while the paste sheet asks the engine about the pasted links"
    )

    // MARK: - Report

    /// The report's LEAD clause: how many YouTube links the paste contained. The
    /// clauses that follow subtract from it, so "3 links, 1 duplicate skipped" and two
    /// new rows is arithmetic the reader can check.
    static func downloadsPasteLinksReport(_ count: Int) -> String {
        downloadsInflected(LocalizedStringResource(
            "app.downloads.paste.report.links",
            defaultValue: "^[\(count) link](inflect: true)",
            comment: "Leading clause of the paste report, counting the YouTube links the paste held"
        ))
    }

    static func downloadsPasteAddedReport(_ count: Int) -> String {
        downloadsInflected(LocalizedStringResource(
            "app.downloads.paste.report.added",
            defaultValue: "^[\(count) link](inflect: true) added",
            comment: "Part of the paste report stating how many links were queued"
        ))
    }

    static func downloadsPasteDuplicatesReport(_ count: Int) -> String {
        downloadsInflected(LocalizedStringResource(
            "app.downloads.paste.report.duplicates",
            defaultValue: "^[\(count) duplicate](inflect: true) skipped",
            comment: "Part of the paste report stating how many links were already queued"
        ))
    }

    static func downloadsPasteSkippedReport(_ count: Int) -> String {
        downloadsInflected(LocalizedStringResource(
            "app.downloads.paste.report.skipped",
            defaultValue: "^[\(count) line](inflect: true) skipped",
            comment: "Part of the paste report stating how many lines were not YouTube links"
        ))
    }

    /// The advisory history hint, and the ONE counted string in this file that is FLAT
    /// rather than inflected.
    ///
    /// Every other counted clause here is `count + bare noun`, which
    /// `^[…](inflect: true)` agrees correctly in all seven languages. This one is
    /// `count + a VERB`, and the recorded doctrine is explicit that markup cannot help
    /// there — it agrees only what sits INSIDE the brackets, so a participle outside
    /// them renders wrong grammar (the "2 enlaces añadido" case). Each locale therefore
    /// carries a plain `%lld` inside a frame whose verb agrees with the SUBJECT rather
    /// than with the count, which is number-invariant in all seven. No
    /// ``MacAMPStrings/downloadsInflected(_:)`` call: there is no morphology to run.
    static func downloadsPastePreviouslyDownloadedReport(_ count: Int) -> String {
        String(localized: LocalizedStringResource(
            "app.downloads.paste.report.previouslyDownloaded",
            defaultValue: "You already downloaded \(count) of these",
            comment: "Advisory line in the paste report stating how many of the pasted links had been downloaded before"
        ))
    }

    static let downloadsPasteNothingReport = LocalizedStringResource(
        "app.downloads.paste.report.nothing",
        defaultValue: "No YouTube links found.",
        comment: "Paste report shown when the pasted text contained nothing usable"
    )
    static let downloadsPasteSkippedHeader = LocalizedStringResource(
        "app.downloads.paste.report.skippedHeader",
        defaultValue: "These lines weren’t YouTube links:",
        comment: "Header above the list of pasted lines that were not YouTube links"
    )

    static func downloadsPasteSkippedMore(_ count: Int) -> String {
        downloadsInflected(LocalizedStringResource(
            "app.downloads.paste.report.skippedMore",
            defaultValue: "and ^[\(count) more line](inflect: true)",
            comment: "Trailing row when the skipped-lines list is longer than the sheet shows"
        ))
    }

    // MARK: - Playlist confirmation

    static let downloadsPlaylistTitle = LocalizedStringResource(
        "app.downloads.paste.playlist.title",
        defaultValue: "That link is a playlist",
        comment: "Heading of the confirmation step shown when a pasted link expands to many videos"
    )

    static func downloadsPlaylistCount(_ count: Int) -> String {
        downloadsInflected(LocalizedStringResource(
            "app.downloads.paste.playlist.count",
            defaultValue: "It holds ^[\(count) video](inflect: true). Nothing is queued until you confirm.",
            comment: "Body of the playlist confirmation step, stating the real video count"
        ))
    }

    static func downloadsPlaylistCapped(_ count: Int) -> String {
        downloadsInflected(LocalizedStringResource(
            "app.downloads.paste.playlist.capped",
            defaultValue: "Only its first ^[\(count) video](inflect: true) can be queued at once.",
            comment: "Body of the playlist confirmation step when the expansion was truncated to the cap"
        ))
    }

    static func downloadsPlaylistAdd(_ count: Int) -> String {
        downloadsInflected(LocalizedStringResource(
            "app.downloads.paste.playlist.add",
            defaultValue: "Add ^[\(count) Video](inflect: true)",
            comment: "Button confirming a playlist expansion that fits under the cap"
        ))
    }

    static func downloadsPlaylistAddCapped(_ count: Int) -> String {
        downloadsInflected(LocalizedStringResource(
            "app.downloads.paste.playlist.addCapped",
            defaultValue: "Add First ^[\(count) Video](inflect: true)",
            comment: "Button confirming a truncated playlist expansion, naming the capped count"
        ))
    }

    static let downloadsPlaylistSkip = LocalizedStringResource(
        "app.downloads.paste.playlist.skip",
        defaultValue: "Skip Playlist",
        comment: "Button discarding a held playlist expansion without queueing any of it"
    )
    static let downloadsPlaylistSkipHelp = LocalizedStringResource(
        "app.downloads.paste.playlist.skipHelp",
        defaultValue: "Discard this playlist without queueing any of its videos",
        comment: "Tooltip for the button discarding a held playlist expansion"
    )
    static let downloadsPlaylistExpiredReport = LocalizedStringResource(
        "app.downloads.paste.playlist.expired",
        defaultValue: "0 added — that playlist confirmation had expired.",
        comment: "Report shown when a playlist confirmation token was already discarded by the queue"
    )
}
