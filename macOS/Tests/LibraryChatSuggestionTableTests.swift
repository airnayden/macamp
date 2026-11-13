// LibraryChatSuggestionTableTests — what the suggestion TABLE decides.
//
// Statics-only, for the reason `LibraryChatSuggestionSelectionTests`' header records in
// full: a rendered SwiftUI row cannot be inspected after the fact, and an
// `NSHostingView` walked by accessibility identifier reports NOTHING in a unit-test
// bundle — a probe that finds nothing satisfies every "renders none" claim while
// measuring none of them. So every decision the table makes lives in a static on
// ``LibraryChatSuggestionList`` and is driven here; DRAWING is asserted by XCUITest,
// from the identifiers pinned below.
//
// A NEW file rather than more cases on `LibraryChatSuggestionSelectionTests`, which sits
// at 397 lines against SwiftLint's strict 400-line ceiling — `macOS/Tests` is not in
// `.swiftlint.yml`'s `excluded`, so `file_length` applies to test code too.
import Foundation
@testable import MacAMP
import Services
import Testing

/// Fixtures at file scope, never as a `static let` inside the `@MainActor` suite: the
/// `@Test` macro expands argument expressions OUTSIDE the actor, and an actor-isolated
/// static there fails to compile pointing at generated source.
private enum TableFixture {
    /// Every status the column can be asked to render, in the order
    /// ``ChatDownloadRowStatus`` declares them. A case added without copy must fail
    /// here rather than render a blank cell.
    static let everyStatus: [ChatDownloadRowStatus] = [
        .none,
        .resolving,
        .notFound,
        .alreadyDownloaded,
        .queued,
        .downloading(fraction: 0.42),
        .converting,
        .downloaded,
        .addedToPlaylist(name: "Late Night"),
        .failed,
    ]

    static func video(_ videoID: String, title: String = "Marrow") throws -> AssistantChatSuggestion {
        try AssistantChatSuggestion(
            title: title,
            artist: "Anvil",
            videoURL: url("https://www.youtube.com/watch?v=\(videoID)")
        )
    }

    static func search(_ title: String = "Harrow", artist: String? = "Quarry") -> AssistantChatSuggestion {
        AssistantChatSuggestion(title: title, artist: artist)
    }

    /// A row with nothing to look up. Built directly because `linkable(_:)` drops a
    /// blank title before it can become a row.
    static func blankTitleRow() throws -> LinkableSuggestion {
        try LinkableSuggestion(
            id: 0,
            name: "",
            title: "   ",
            artist: nil,
            url: url("https://www.youtube.com/results?search_query=x"),
            kind: .search
        )
    }

    static func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    static func linkable(_ suggestions: [AssistantChatSuggestion]) -> [LinkableSuggestion] {
        LibraryChatSuggestionList.linkable(suggestions)
    }
}

@Suite("Library chat suggestion table")
@MainActor
struct LibraryChatSuggestionTableTests {
    // MARK: The heading

    @Test("the heading appears for any row at all, and its subtitle only where songs can be picked")
    func theHeadingFollowsTheRowsAndTheSubtitleFollowsTheSurface() throws {
        let rows = try TableFixture.linkable([TableFixture.video("dQw4w9WgXcQ"), TableFixture.search()])

        #expect(LibraryChatSuggestionList.showsHeader(rows))
        #expect(!LibraryChatSuggestionList.showsHeader([]))

        // The subtitle explains how to PICK, so it follows the download surface: with
        // no handler there is nothing to pick and the sentence would name controls
        // that are not drawn.
        #expect(LibraryChatSuggestionList.showsHeaderSubtitle(rows, isEnabled: true))
        #expect(!LibraryChatSuggestionList.showsHeaderSubtitle(rows, isEnabled: false))
        #expect(!LibraryChatSuggestionList.showsHeaderSubtitle([], isEnabled: true))

        // The heading is the constant this surface has always drawn — deliberately NOT
        // re-keyed for the table, so nothing already translated is orphaned.
        #expect(LibraryChatStrings.suggestionsHeader.key == "app.assistant.chat.suggestions.header")
        #expect(
            LibraryChatStrings.suggestionsTableSubtitle.key
                == "app.assistant.chat.suggestions.table.subtitle"
        )
    }

    // MARK: Every row carries a tick

    @Test("a verified row and a search row both draw a tick; only an untitled row does not")
    func everyRowThatNamesSomethingDrawsATick() throws {
        let rows = try TableFixture.linkable([TableFixture.video("dQw4w9WgXcQ"), TableFixture.search()])
        #expect(rows.map(\.kind) == [.video, .search])

        #expect(LibraryChatSuggestionList.rowSelectionKey(rows[0], isEnabled: true) == "dQw4w9WgXcQ")
        #expect(LibraryChatSuggestionList.rowSelectionKey(rows[1], isEnabled: true) == "q:harrow|quarry")

        // …and the row with no title to look up draws neither the tick nor the
        // per-row Download button, which the table gates on the same key.
        let blank = try TableFixture.blankTitleRow()
        #expect(LibraryChatSuggestionList.rowSelectionKey(blank, isEnabled: true) == nil)
        #expect(LibraryChatSuggestionList.selectableKey(blank) == nil)
    }

    // MARK: The status column

    @Test("every status renders its own sentence, and only `.none` renders nothing")
    func everyStatusHasItsOwnCopy() {
        let expected: [String?] = [
            nil,
            "app.assistant.chat.status.resolving",
            "app.assistant.chat.status.notFound",
            "app.assistant.chat.status.alreadyDownloaded",
            "app.assistant.chat.status.queued",
            "app.assistant.chat.status.downloading",
            "app.assistant.chat.status.converting",
            "app.assistant.chat.status.downloaded",
            "app.assistant.chat.status.addedToPlaylist",
            "app.assistant.chat.status.failed",
        ]
        let actual = TableFixture.everyStatus.map { LibraryChatSuggestionList.statusText(for: $0)?.key }

        #expect(actual == expected)
        // Distinct keys, not merely non-nil: nine statuses collapsing onto one
        // sentence would satisfy "renders something" and tell a listener nothing.
        #expect(Set(actual.compactMap(\.self)).count == 9)
    }

    @Test("a playlist whose name could not be read falls back to the unnamed sentence")
    func anUnnamedPlaylistStillReadsAsAnAppend() {
        #expect(
            LibraryChatSuggestionList.statusText(for: .addedToPlaylist(name: ""))?.key
                == "app.assistant.chat.status.addedToUnnamedPlaylist"
        )
        #expect(
            LibraryChatSuggestionList.statusText(for: .addedToPlaylist(name: "Late Night"))?.key
                == "app.assistant.chat.status.addedToPlaylist"
        )
    }

    @Test("each status reads in the colour role its meaning deserves")
    func everyStatusHasItsOwnTone() {
        let expected: [ChatSuggestionStatusTone?] = [
            nil, .working, .warning, .advisory, .working,
            .working, .working, .success, .success, .warning,
        ]

        #expect(TableFixture.everyStatus.map { LibraryChatSuggestionList.statusTone(for: $0) } == expected)
    }

    @Test("only a download in flight draws a determinate bar, and only when it reports one")
    func onlyDownloadingCarriesAFraction() {
        let fractions = TableFixture.everyStatus.map { LibraryChatSuggestionList.statusFraction(for: $0) }

        #expect(fractions == [nil, nil, nil, nil, nil, 0.42, nil, nil, nil, nil])
        // The metadata prefetch reports no fraction, and an indeterminate phase must
        // draw no bar rather than a fabricated zero.
        #expect(LibraryChatSuggestionList.statusFraction(for: .downloading(fraction: nil)) == nil)
    }

    // MARK: The per-row Download button

    @Test("a row already working refuses its own Download button; every settled row keeps it")
    func downloadIsRefusedOnlyWhileTheRowIsWorking() {
        let expected = [true, false, true, true, false, false, false, true, true, true]

        #expect(
            TableFixture.everyStatus.map { LibraryChatSuggestionList.downloadButtonEnabled(status: $0) }
                == expected
        )
    }

    @Test("one row's Download asks for exactly that row, with the turn's target verbatim")
    func aRowDownloadAsksForThatRowAlone() throws {
        let rows = try TableFixture.linkable([
            TableFixture.video("aaaaaaaaaaa"),
            TableFixture.search("Harrow"),
            TableFixture.video("ccccccccccc"),
        ])
        let key = try #require(LibraryChatSuggestionList.selectableKey(rows[1]))

        // The button's whole body is `request(selected: [selectableKey(row)], …)`, so
        // what it can get wrong is WHICH key travels and WHAT ELSE comes with it.
        let single = LibraryChatSuggestionList.request(
            selected: [key],
            in: rows,
            appendTarget: .playlist(42),
            appendProfileId: 7
        )

        #expect(single.videoIDs.isEmpty)
        #expect(single.unresolved == [ChatDownloadCandidate(key: key, title: "Harrow", artist: "Quarry")])
        #expect(single.appendTarget == .playlist(42))
        #expect(single.appendProfileId == 7)

        // Identical to ticking only that row and pressing the batch button — one
        // derivation, so the two gestures cannot disagree about what they asked for.
        #expect(single == LibraryChatSuggestionList.request(
            selected: Set([key]),
            in: rows,
            appendTarget: .playlist(42),
            appendProfileId: 7
        ))
        // …and it leaves the other two rows entirely alone.
        #expect(LibraryChatSuggestionList.selectedCount([key], in: rows) == 1)
    }

    @Test("a verified row's own Download travels as an id, never as a lookup")
    func aVerifiedRowDownloadsWithoutALookup() throws {
        let rows = try TableFixture.linkable([TableFixture.video("aaaaaaaaaaa"), TableFixture.search()])
        let request = LibraryChatSuggestionList.request(
            selected: ["aaaaaaaaaaa"],
            in: rows,
            appendTarget: nil,
            appendProfileId: nil
        )

        #expect(request.videoIDs == ["aaaaaaaaaaa"])
        #expect(request.unresolved.isEmpty)
    }

    // MARK: What the table announces

    @Test("only verified videos are announced, in draw order, each once")
    func theTableAnnouncesTheVerifiedVideosItDrew() throws {
        let rows = try TableFixture.linkable([
            TableFixture.video("aaaaaaaaaaa"),
            TableFixture.search(),
            TableFixture.video("bbbbbbbbbbb"),
            TableFixture.video("aaaaaaaaaaa", title: "Marrow (Remaster)"),
        ])

        // A candidate has no video id yet, so there is nothing download history could
        // be asked about — announcing its `"q:"` key would prime a row against a table
        // keyed by canonical ids.
        #expect(LibraryChatSuggestionList.announcedVideoIDs(rows) == ["aaaaaaaaaaa", "bbbbbbbbbbb"])
        #expect(LibraryChatSuggestionList.announcedVideoIDs([]).isEmpty)
    }

    @Test("the default hooks report nothing and prime nothing")
    func theInertHooksAreTrulyInert() {
        var announced: [[String]] = []
        let hooks = ChatSuggestionHooks.inert

        #expect(hooks.status("dQw4w9WgXcQ") == .none)
        #expect(hooks.status("q:harrow|quarry") == .none)
        hooks.onSuggestionsShown(["dQw4w9WgXcQ"])
        #expect(announced.isEmpty)

        // …and a recorder in its place is what todo 9 substitutes, with no other change.
        let recording = ChatSuggestionHooks(
            status: { _ in .queued },
            onSuggestionsShown: { announced.append($0) }
        )
        #expect(recording.status("dQw4w9WgXcQ") == .queued)
        recording.onSuggestionsShown(["dQw4w9WgXcQ"])
        #expect(announced == [["dQw4w9WgXcQ"]])
    }

    // MARK: Identifiers

    @Test("every new control is addressed by the key its row means, beside the list's own prefix")
    func identifiersFollowTheTablesScheme() throws {
        let prefix = "assistant.chat.suggestions.2.0"
        let rows = try TableFixture.linkable([TableFixture.video("dQw4w9WgXcQ"), TableFixture.search()])

        #expect(LibraryChatSuggestionList.headerIdentifier(prefix: prefix) == "\(prefix).header")
        #expect(
            LibraryChatSuggestionList.statusIdentifier(prefix: prefix, rowKey: "q:harrow|quarry")
                == "\(prefix).status.q:harrow|quarry"
        )
        // Distinct from `downloadIdentifier(prefix:)`, which is the ONE batch button at
        // the foot of the list — a collision would make a UI test press either.
        #expect(
            LibraryChatSuggestionList.rowDownloadIdentifier(prefix: prefix, rowKey: "dQw4w9WgXcQ")
                == "\(prefix).download.dQw4w9WgXcQ"
        )
        #expect(
            LibraryChatSuggestionList.rowDownloadIdentifier(prefix: prefix, rowKey: "dQw4w9WgXcQ")
                != LibraryChatSuggestionList.downloadIdentifier(prefix: prefix)
        )

        // The browser button keeps the list's long-standing link identifier, which is
        // what the shipped `WebSuggestionsChatUITests` walks.
        #expect(
            LibraryChatSuggestionList.identifier(prefix: prefix, rows[0]) == "\(prefix).link.video.0"
        )
        #expect(
            LibraryChatSuggestionList.identifier(prefix: prefix, rows[1]) == "\(prefix).link.search.1"
        )
    }

    @Test("the two browser buttons say different words, because they make different promises")
    func theBrowserButtonNamesItsPromise() {
        #expect(SuggestionLinkKind.video.actionLabel.key == "app.assistant.chat.suggestions.open")
        #expect(SuggestionLinkKind.search.actionLabel.key == "app.assistant.chat.suggestions.search")
        #expect(LibraryChatStrings.suggestionDownloadAction.key == "app.assistant.chat.download.row")
        #expect(
            LibraryChatStrings.suggestionDownloadRowLabel(name: "Marrow").key
                == "app.assistant.chat.download.rowLabel"
        )
    }
}
