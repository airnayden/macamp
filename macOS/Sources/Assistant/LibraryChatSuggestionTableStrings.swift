// LibraryChatSuggestionTableStrings — every word the suggestion TABLE says.
//
// An extension rather than more of `LibraryChatStrings.swift`, which is at 381 lines
// against SwiftLint's strict 400-line ceiling — the same reason
// `LibraryChatSuggestionSelection.swift` carries the download surface's own copy, and
// the same reason `LibraryChatSuggestionKeys.swift` exists at all.
//
// ── THE HEADING IS NOT RE-KEYED ──────────────────────────────────────────────
//
// There is deliberately no `suggestionsTableTitle` here. The table's heading is
// ``LibraryChatStrings/suggestionsHeader`` — "Not in your library" — the constant this
// surface has always drawn, under the catalog key it has always carried. A second key
// with byte-identical English would give a translator two entries for one sentence and
// two places for them to drift, and would orphan whatever is already translated. Only
// the SUBTITLE is new, because only the subtitle is new copy.
//
// ── A STATUS IS COPY, A PROGRESS FRACTION IS NOT ─────────────────────────────
//
// Every status renders a localized sentence. The `.downloading` percentage is drawn as
// a `ProgressView`, never interpolated into the sentence: a number formatted into copy
// is a number a locale cannot re-format, and the bar states it without words.
import Foundation

extension LibraryChatStrings {
    // MARK: The table's heading

    /// What the table is for, under the heading that names it.
    ///
    /// Two clauses because the table now offers two different actions, and a listener
    /// has to know which one costs a download before pressing either.
    static let suggestionsTableSubtitle = LocalizedStringResource(
        "app.assistant.chat.suggestions.table.subtitle",
        defaultValue: "Pick songs to download; verified links open on YouTube.",
        comment: "Subtitle under the heading of the table listing songs the library does not have"
    )

    // MARK: The per-row buttons

    /// Opens the row's verified video.
    static let suggestionOpenAction = LocalizedStringResource(
        "app.assistant.chat.suggestions.open",
        defaultValue: "Open",
        comment: "Button on a suggestion row that opens that song's verified video in the browser"
    )

    /// Opens the row's search fallback. A DIFFERENT word from ``suggestionOpenAction``
    /// on purpose: the two buttons make different promises, and a listener must be able
    /// to tell a verified video from a query at a glance.
    static let suggestionSearchAction = LocalizedStringResource(
        "app.assistant.chat.suggestions.search",
        defaultValue: "Search",
        comment: "Button on a suggestion row that opens a web search for that song"
    )

    /// Downloads this one row, without touching the ticks.
    static let suggestionDownloadAction = LocalizedStringResource(
        "app.assistant.chat.download.row",
        defaultValue: "Download",
        comment: "Button on a suggestion row that downloads that one song"
    )

    static let suggestionDownloadRowHelp = LocalizedStringResource(
        "app.assistant.chat.download.rowHelp",
        defaultValue: "Download this song to your downloads folder.",
        comment: "Tooltip of the button that downloads one song from a suggestion row"
    )

    /// Names WHICH song the row's Download button asks for, so VoiceOver reads more
    /// than "download".
    static func suggestionDownloadRowLabel(name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.download.rowLabel",
            defaultValue: "Download \(name)",
            comment: "Accessibility label of the button that downloads one song from a suggestion row"
        )
    }
}

// MARK: - What a row's download currently says

extension LibraryChatStrings {
    static let statusResolving = LocalizedStringResource(
        "app.assistant.chat.status.resolving",
        defaultValue: "Looking up…",
        comment: "Status on a suggestion row while its video is being looked up"
    )

    static let statusNotFound = LocalizedStringResource(
        "app.assistant.chat.status.notFound",
        defaultValue: "Not found",
        comment: "Status on a suggestion row whose song no video could be found for"
    )

    static let statusAlreadyDownloaded = LocalizedStringResource(
        "app.assistant.chat.status.alreadyDownloaded",
        defaultValue: "Already downloaded",
        comment: "Advisory status on a suggestion row whose song is already in the download history"
    )

    static let statusQueued = LocalizedStringResource(
        "app.assistant.chat.status.queued",
        defaultValue: "Queued",
        comment: "Status on a suggestion row waiting in the download queue"
    )

    static let statusDownloading = LocalizedStringResource(
        "app.assistant.chat.status.downloading",
        defaultValue: "Downloading",
        comment: "Status on a suggestion row whose song is transferring; the percentage is drawn as a bar beside it"
    )

    static let statusConverting = LocalizedStringResource(
        "app.assistant.chat.status.converting",
        defaultValue: "Converting…",
        comment: "Status on a suggestion row whose downloaded file is being converted"
    )

    static let statusDownloaded = LocalizedStringResource(
        "app.assistant.chat.status.downloaded",
        defaultValue: "Downloaded",
        comment: "Status on a suggestion row whose song finished downloading"
    )

    static let statusFailed = LocalizedStringResource(
        "app.assistant.chat.status.failed",
        defaultValue: "Failed",
        comment: "Status on a suggestion row whose download, import or playlist append gave up"
    )

    /// The terminal success for a song the conversation named a playlist for.
    static func statusAddedToPlaylist(name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.assistant.chat.status.addedToPlaylist",
            defaultValue: "Added to “\(name)”",
            comment: "Status on a suggestion row whose song was added to the named playlist"
        )
    }

    /// The same fact when the playlist's name could not be read — the rendering side
    /// owns this fallback, exactly as ``ChatDownloadToastCoalescer/summaryText(count:playlist:)``
    /// does for the toast.
    static let statusAddedToUnnamedPlaylist = LocalizedStringResource(
        "app.assistant.chat.status.addedToUnnamedPlaylist",
        defaultValue: "Added to a playlist",
        comment: "Status on a suggestion row added to a playlist whose name could not be read"
    )
}
