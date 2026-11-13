// LibraryChatSuggestionSelectionTests — which songs a chat row lets you pick, and what
// pressing "Download selected" actually asks for.
//
// Mirrors `LibraryChatRowsCompositionTests`: a rendered SwiftUI row cannot be inspected
// after the fact, so everything the list DECIDES lives in statics on the view and is
// driven here. `row(_:)` draws a tick exactly when ``selectableKey(_:)`` names one and a
// handler exists, and `downloadSection(_:)` draws the button and captions exactly when
// the three `shows…` predicates say so — so the predicates ARE the surface.
//
// MEASURED, and why there is no hosted suite here: an `NSHostingView` walked by
// accessibility identifier reports NOTHING in a unit-test bundle — not the checkboxes,
// and not the link rows that predate this file. A probe that finds nothing satisfies
// every "renders none" claim while measuring none of them, and one that depends on
// whether accessibility happens to be enabled on the host is a flake. Drawing is
// asserted by XCUITest, from identifiers pinned below.
//
// Deliberately a NEW file rather than more cases on `LibraryChatRowsCompositionTests`:
// that file is carrying unrelated in-flight work, and a suite appended to it could not
// be committed on its own.
import Foundation
@testable import MacAMP
import Services
import Testing

/// Fixtures at file scope so both suites share them without growing a type.
private enum SelectionFixture {
    /// A miss the enricher resolved to a real watch link — the `.video` kind.
    static func video(_ videoID: String, title: String = "Marrow") throws -> AssistantChatSuggestion {
        try AssistantChatSuggestion(
            title: title,
            artist: "Anvil",
            videoURL: url("https://www.youtube.com/watch?v=\(videoID)")
        )
    }

    /// A miss with no link of its own — the `.search` fallback this app composes.
    static func search(_ title: String = "Harrow") -> AssistantChatSuggestion {
        AssistantChatSuggestion(title: title, artist: "Quarry")
    }

    /// A miss named however the test needs it, with no link of its own.
    static func named(title: String, artist: String?) -> AssistantChatSuggestion {
        AssistantChatSuggestion(title: title, artist: artist)
    }

    /// A `.video` row whose URL names no canonical id.
    ///
    /// Built DIRECTLY because `linkable(_:)` cannot produce one — the validator it runs
    /// would have turned this URL into a search row. It still has to behave: the two
    /// validators are different code, and a row this one cannot key must travel as
    /// something a lookup can act on rather than as an id that does not exist.
    static func unkeyableVideoRow() throws -> LinkableSuggestion {
        try LinkableSuggestion(
            id: 0,
            name: "Nothing To Key On — Anvil",
            title: "Nothing To Key On",
            artist: "Anvil",
            url: url("https://example.com/watch?v=dQw4w9WgXcQ"),
            kind: .video
        )
    }

    /// A row with nothing to look up.
    ///
    /// Built DIRECTLY because `linkable(_:)` drops a blank title before it can become a
    /// row — `YouTubeSearchLink.url` has nothing to search for. The guard still has to
    /// hold: every blank-titled row folds to the same degenerate `"q:|"`, so one tick
    /// would select all of them at once.
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

@Suite("Library chat suggestion selection")
@MainActor
struct LibraryChatSuggestionSelectionTests {
    // MARK: Which rows can be picked

    @Test("every row is selectable — a verified one by its id, the rest by their query")
    func everyRowIsSelectableAndKeyedByWhatItMeans() throws {
        let rows = try SelectionFixture.linkable([
            SelectionFixture.video("dQw4w9WgXcQ"),
            SelectionFixture.search(),
        ])
        #expect(rows.map(\.kind) == [.video, .search])

        // A verified row keys by the id the DOWNLOADER will use, derived from the row's
        // validated destination — never the row's `id`, a transient enumeration offset.
        #expect(LibraryChatSuggestionList.rowKey(rows[0]) == "dQw4w9WgXcQ")
        #expect(LibraryChatSuggestionList.verifiedVideoID(rows[0]) == "dQw4w9WgXcQ")

        // A row with no verified video keys by the two strings it was NAMED by, which
        // is exactly what the lookup behind it will be given.
        #expect(LibraryChatSuggestionList.rowKey(rows[1]) == "q:harrow|quarry")
        #expect(LibraryChatSuggestionList.verifiedVideoID(rows[1]) == nil)

        #expect(LibraryChatSuggestionList.selectableKeys(rows) == ["dQw4w9WgXcQ", "q:harrow|quarry"])
    }

    @Test("a video row whose URL names no canonical id travels as a candidate, not an id")
    func anUnkeyableVideoRowTravelsAsACandidate() throws {
        let row = try SelectionFixture.unkeyableVideoRow()
        let key = "q:nothing to key on|anvil"

        #expect(LibraryChatSuggestionList.verifiedVideoID(row) == nil)
        #expect(LibraryChatSuggestionList.rowKey(row) == key)

        // It is still pickable — refusing the tick only ever meant the song could not be
        // asked for at all, and a lookup can find it from the same two strings.
        let request = LibraryChatSuggestionList.request(
            selected: [key],
            in: [row],
            appendTarget: nil,
            appendProfileId: nil
        )
        #expect(request.videoIDs.isEmpty)
        #expect(request.unresolved == [ChatDownloadCandidate(key: key, title: "Nothing To Key On", artist: "Anvil")])
    }

    @Test("a row with no title to look up draws no checkbox, whatever key it would derive")
    func aBlankTitleRowIsNotSelectable() throws {
        let row = try SelectionFixture.blankTitleRow()

        #expect(LibraryChatSuggestionList.rowKey(row) == "q:|")
        #expect(LibraryChatSuggestionList.selectableKey(row) == nil)
        #expect(LibraryChatSuggestionList.rowSelectionKey(row, isEnabled: true) == nil)
        #expect(LibraryChatSuggestionList.selectableKeys([row]).isEmpty)
        // …and with nothing selectable the whole download surface stays away.
        #expect(!LibraryChatSuggestionList.showsDownloadControls([row], isEnabled: true))
    }

    @Test("the per-row tick is gated by the handler, and by nothing about the row")
    func theRowTickIsGatedByTheHandlerOnly() throws {
        let rows = try SelectionFixture.linkable([
            SelectionFixture.video("dQw4w9WgXcQ"),
            SelectionFixture.search(),
        ])

        #expect(LibraryChatSuggestionList.rowSelectionKey(rows[0], isEnabled: false) == nil)
        #expect(LibraryChatSuggestionList.rowSelectionKey(rows[1], isEnabled: false) == nil)
        #expect(LibraryChatSuggestionList.rowSelectionKey(rows[0], isEnabled: true) == "dQw4w9WgXcQ")
        #expect(LibraryChatSuggestionList.rowSelectionKey(rows[1], isEnabled: true) == "q:harrow|quarry")
    }

    @Test("a list of only search rows now offers the whole download surface")
    func searchOnlyListsNowOfferTheDownloadSurface() {
        let rows = SelectionFixture.linkable([SelectionFixture.search("A"), SelectionFixture.search("B")])

        #expect(LibraryChatSuggestionList.selectableKeys(rows) == ["q:a|quarry", "q:b|quarry"])
        #expect(LibraryChatSuggestionList.showsDownloadControls(rows, isEnabled: true))
        #expect(LibraryChatSuggestionList.showsNoPlaylistCaption(rows, isEnabled: true, appendTarget: nil))
        #expect(LibraryChatSuggestionList.showsImportWarning(rows, isEnabled: true, isImportConfigured: false))
    }

    @Test("the same song spelled two ways is one checkbox and one candidate")
    func foldedSpellingsOfOneSongCollapseToOneKey() {
        let rows = SelectionFixture.linkable([
            SelectionFixture.named(title: "Café", artist: "Zoë"),
            SelectionFixture.named(title: "  CAFE  ", artist: "ZOE"),
        ])
        #expect(rows.count == 2)

        // Case, diacritics and surrounding whitespace all fold away: a model that names
        // one song two ways must not produce two ticks and two downloads.
        #expect(LibraryChatSuggestionList.selectableKeys(rows) == ["q:cafe|zoe"])
        let request = LibraryChatSuggestionList.request(
            selected: ["q:cafe|zoe"],
            in: rows,
            appendTarget: nil,
            appendProfileId: nil
        )
        #expect(request.unresolved == [ChatDownloadCandidate(key: "q:cafe|zoe", title: "Café", artist: "Zoë")])
    }

    @Test("no handler means no download surface at all, whatever the rows are")
    func noHandlerMeansNoSurface() throws {
        let rows = try SelectionFixture.linkable([SelectionFixture.video("dQw4w9WgXcQ")])

        #expect(!LibraryChatSuggestionList.showsDownloadControls(rows, isEnabled: false))
        #expect(!LibraryChatSuggestionList.showsNoPlaylistCaption(rows, isEnabled: false, appendTarget: nil))
        #expect(!LibraryChatSuggestionList.showsImportWarning(rows, isEnabled: false, isImportConfigured: false))
    }

    @Test("the same video twice is one checkbox and one id in the request")
    func duplicateVideosCollapseToOneID() throws {
        let rows = try SelectionFixture.linkable([
            SelectionFixture.video("dQw4w9WgXcQ", title: "Marrow"),
            SelectionFixture.video("dQw4w9WgXcQ", title: "Marrow (Remaster)"),
        ])
        #expect(rows.count == 2)

        // Two rows, ONE key: selection state is per key, so ticking either ticks both,
        // and the request must not ask the downloader for the same video twice.
        #expect(LibraryChatSuggestionList.selectableKeys(rows) == ["dQw4w9WgXcQ"])
        let request = LibraryChatSuggestionList.request(
            selected: ["dQw4w9WgXcQ"],
            in: rows,
            appendTarget: nil,
            appendProfileId: nil
        )
        #expect(request.videoIDs == ["dQw4w9WgXcQ"])
    }

    // MARK: The count and the button

    @Test("the count spans the whole list, including rows folded behind the expander")
    func theCountSurvivesTheExpander() throws {
        // Eleven characters exactly — the normalizer rejects anything else, and a
        // shorter fixture would make every assertion below pass against nothing.
        let ids = (1 ... 13).map { String(format: "vid%08d", $0) }
        let rows = try SelectionFixture.linkable(ids.map { try SelectionFixture.video($0, title: "Miss \($0)") })
        #expect(rows.count == 13)

        // Rows 11–13 are behind the expander while collapsed…
        let visible = LibraryChatSuggestionList.visible(rows, isExpanded: false)
        #expect(visible.count == 10)
        let hidden = Set(ids.suffix(3))
        #expect(LibraryChatSuggestionList.selectableKeys(visible).allSatisfy { !hidden.contains($0) })

        // …and the count still counts them, because selection lives on the LIST.
        #expect(LibraryChatSuggestionList.selectedCount(hidden, in: rows) == 3)
        #expect(LibraryChatSuggestionList.selectedCount(Set(ids), in: rows) == 13)
    }

    @Test("the button is disabled at zero and states the count once something is picked")
    func theButtonIsDisabledAtZero() throws {
        let rows = try SelectionFixture.linkable([SelectionFixture.video("dQw4w9WgXcQ")])

        #expect(!LibraryChatSuggestionList.canDownload(selectedCount: 0))
        #expect(LibraryChatSuggestionList.canDownload(selectedCount: 1))
        #expect(LibraryChatSuggestionList.selectedCount([], in: rows) == 0)
        #expect(LibraryChatSuggestionList.selectedCount(["dQw4w9WgXcQ"], in: rows) == 1)

        // The label is a catalog key carrying the count, not a hand-built string.
        #expect(LibraryChatStrings.downloadSelected(count: 3).key == "app.assistant.chat.download.selected")
    }

    // MARK: What the press asks for

    @Test("the request carries canonical ids in list order and the turn's target verbatim")
    func theRequestCarriesTheTargetVerbatim() throws {
        let rows = try SelectionFixture.linkable([
            SelectionFixture.video("aaaaaaaaaaa"),
            SelectionFixture.video("bbbbbbbbbbb"),
            SelectionFixture.search(),
            SelectionFixture.video("ccccccccccc"),
        ])
        let request = LibraryChatSuggestionList.request(
            selected: ["ccccccccccc", "aaaaaaaaaaa"],
            in: rows,
            appendTarget: .playlist(42),
            appendProfileId: 7
        )

        // LIST order, not selection order and not `Set` order — a request assembled
        // from a `Set` would vary between runs.
        #expect(request.videoIDs == ["aaaaaaaaaaa", "ccccccccccc"])
        // The search row was on offer but was not ticked, so it asks for no lookup.
        #expect(request.unresolved.isEmpty)
        #expect(request.appendTarget == .playlist(42))
        #expect(request.appendProfileId == 7)
    }

    @Test("one press splits verified ids from candidates, each list in list order")
    func theRequestSplitsVerifiedIDsFromCandidates() throws {
        let rows = try SelectionFixture.linkable([
            SelectionFixture.named(title: "Harrow", artist: "Quarry"),
            SelectionFixture.video("aaaaaaaaaaa"),
            SelectionFixture.named(title: "Marrow", artist: nil),
        ])
        let keys = Set(LibraryChatSuggestionList.selectableKeys(rows))
        let request = LibraryChatSuggestionList.request(
            selected: keys,
            in: rows,
            appendTarget: nil,
            appendProfileId: nil
        )

        // Two lists because the two cost different things: an id goes straight to the
        // downloader, a candidate has to be looked up first and may not resolve at all.
        #expect(request.videoIDs == ["aaaaaaaaaaa"])
        #expect(request.unresolved == [
            ChatDownloadCandidate(key: "q:harrow|quarry", title: "Harrow", artist: "Quarry"),
            ChatDownloadCandidate(key: "q:marrow|", title: "Marrow", artist: nil),
        ])
        #expect(LibraryChatSuggestionList.selectedCount(keys, in: rows) == 3)
    }

    @Test("a turn that named no playlist asks for a plain download, target and profile absent")
    func aTurnWithNoTargetAsksForAPlainDownload() throws {
        let rows = try SelectionFixture.linkable([SelectionFixture.video("dQw4w9WgXcQ")])
        let request = LibraryChatSuggestionList.request(
            selected: ["dQw4w9WgXcQ"],
            in: rows,
            appendTarget: nil,
            appendProfileId: nil
        )

        // Spelled without `unresolved:` on purpose: the default is what keeps every
        // caller that only ever has verified ids — including the re-entry a resolver
        // makes — reading as the three-field request it was.
        #expect(request == ChatDownloadRequest(
            videoIDs: ["dQw4w9WgXcQ"],
            appendTarget: nil,
            appendProfileId: nil
        ))
        #expect(request.unresolved.isEmpty)
    }

    @Test("a pending proposal crosses as itself, so the append can still be parked")
    func aPendingProposalCrossesVerbatim() throws {
        let proposalId = UUID()
        let rows = try SelectionFixture.linkable([SelectionFixture.video("dQw4w9WgXcQ")])
        let request = LibraryChatSuggestionList.request(
            selected: ["dQw4w9WgXcQ"],
            in: rows,
            appendTarget: .pendingProposal(proposalId),
            appendProfileId: nil
        )

        #expect(request.appendTarget == .pendingProposal(proposalId))
        #expect(request.appendProfileId == nil)
    }

    @Test("a selected id that the list no longer offers is dropped from the request")
    func aStaleSelectionIsDropped() throws {
        // Enrichment rewrites a turn's suggestions in place, so a tick can outlive the
        // row it was made on. The request must ask only for what is still on screen.
        let rows = try SelectionFixture.linkable([SelectionFixture.video("aaaaaaaaaaa")])
        let request = LibraryChatSuggestionList.request(
            selected: ["aaaaaaaaaaa", "zzzzzzzzzzz"],
            in: rows,
            appendTarget: .playlist(1),
            appendProfileId: 1
        )

        #expect(request.videoIDs == ["aaaaaaaaaaa"])
        #expect(LibraryChatSuggestionList.selectedCount(["aaaaaaaaaaa", "zzzzzzzzzzz"], in: rows) == 1)
    }

    // MARK: The captions

    @Test("the no-playlist caption appears only when the turn named no playlist")
    func theNoPlaylistCaptionIsDrivenByTheTarget() throws {
        let rows = try SelectionFixture.linkable([SelectionFixture.video("dQw4w9WgXcQ")])

        #expect(LibraryChatSuggestionList.showsNoPlaylistCaption(rows, isEnabled: true, appendTarget: nil))
        #expect(!LibraryChatSuggestionList.showsNoPlaylistCaption(
            rows,
            isEnabled: true,
            appendTarget: .playlist(42)
        ))
    }

    @Test("the import warning appears only while the import preview says nothing is imported")
    func theImportWarningIsDrivenByThePreview() throws {
        let rows = try SelectionFixture.linkable([SelectionFixture.video("dQw4w9WgXcQ")])

        #expect(LibraryChatSuggestionList.showsImportWarning(rows, isEnabled: true, isImportConfigured: false))
        #expect(!LibraryChatSuggestionList.showsImportWarning(rows, isEnabled: true, isImportConfigured: true))
    }

    // MARK: Identifiers

    @Test("each checkbox is addressed by its row key, and the button by the list's prefix")
    func identifiersFollowTheListsScheme() {
        let prefix = "assistant.chat.suggestions.2.0"

        #expect(
            LibraryChatSuggestionList.selectionIdentifier(prefix: prefix, rowKey: "dQw4w9WgXcQ")
                == "assistant.chat.suggestions.2.0.select.dQw4w9WgXcQ"
        )
        #expect(
            LibraryChatSuggestionList.selectionIdentifier(prefix: prefix, rowKey: "q:harrow|quarry")
                == "assistant.chat.suggestions.2.0.select.q:harrow|quarry"
        )
        #expect(
            LibraryChatSuggestionList.downloadIdentifier(prefix: prefix)
                == "assistant.chat.suggestions.2.0.downloadSelected"
        )
    }
}
