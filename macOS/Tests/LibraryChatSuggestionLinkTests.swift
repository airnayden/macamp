// LibraryChatSuggestionLinkTests — what a miss becomes on screen, and the one line
// that explains why an on-device conversation never gets one.
//
// ── THE GATE IS ASSERTED THROUGH THE VIEW'S OWN DERIVATION ───────────────────
//
// Every case below drives `LibraryChatSuggestionList.linkable(_:)` — the same static
// derivation `body` renders from — rather than calling
// `YouTubeLinkResolver.validatedWatchURL` directly. Asserting the validator in
// isolation would prove the validator works and say nothing about whether the VIEW
// consults it, which is the whole of this todo's rendering gate. So a lookalike host
// is asserted to produce a SEARCH row, not merely to fail validation.
//
// ── DESTINATIONS ARE COMPARED, NOT COUNTED ──────────────────────────────────
//
// A row's `url` is asserted whole, against the canonical form the validator
// produces. "A link rendered" is the misleading-success shape this suite refuses:
// a fallback and a direct link both render a link, and the difference between them
// is exactly what a listener is trusting.
//
// ── THE BANNER'S DISMISSAL IS PINNED AS THREE STATEMENTS ────────────────────
//
// Dismiss → hidden. `LibraryChatViewModel.reset()` — the call "New Conversation"
// makes — → still hidden. A freshly constructed model → shown again, which is what
// "session-scoped, in memory, no defaults key" means at the next launch. The third
// is the one that would fail if somebody reached for `UserDefaults`: a persisted
// flag makes a new instance start dismissed.
import AIConnectorKit
import Foundation
@testable import MacAMP
import Services
import Testing
import ViewModels

@Suite("Library chat suggestion links")
@MainActor
struct LibraryChatSuggestionLinkTests {
    // MARK: - The rendering gate

    @Test("a validated watch link becomes the row's destination, verbatim")
    func aValidatedVideoLinkIsTheDestination() throws {
        let received = try #require(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        let suggestion = AssistantChatSuggestion(
            title: "November Rain",
            artist: "Guns N' Roses",
            videoURL: received
        )

        let link = try #require(LibraryChatSuggestionList.linkable([suggestion]).first)

        #expect(link.kind == .video)
        // Compared against the ONE validator's own output rather than a typed
        // literal: the view must not hold a second opinion about canonical form.
        #expect(link.url == YouTubeLinkResolver.validatedWatchURL(received))
        #expect(link.url.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(link.name == "November Rain — Guns N' Roses")
    }

    @Test("a link carrying extra parameters renders the validator's stripped form, not what arrived")
    func aVideoLinkIsRenderedCanonically() throws {
        let received = try #require(
            URL(string: "https://youtube.com/watch?v=dQw4w9WgXcQ&list=PLsomething&t=42")
        )
        let link = try #require(
            LibraryChatSuggestionList.linkable([
                AssistantChatSuggestion(title: "November Rain", videoURL: received),
            ]).first
        )

        #expect(link.kind == .video)
        #expect(link.url.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(link.url != received)
    }

    @Test("no link at all renders today's search link, marked as a search")
    func anAbsentVideoLinkFallsBackToTheSearchRow() throws {
        let link = try #require(
            LibraryChatSuggestionList.linkable([
                AssistantChatSuggestion(title: "Riders On The Storm"),
            ]).first
        )

        #expect(link.kind == .search)
        #expect(link.url == YouTubeSearchLink.url(title: "Riders On The Storm", artist: nil))
    }

    @Test("a lookalike host is rejected by the gate and falls back to the search row")
    func aLookalikeHostFallsBack() throws {
        // The malformed-input shape the ONE validator exists for: a host that
        // CONTAINS the real one. Asserted through the view's derivation, so this
        // fails if the view ever stops asking.
        let hostile = try #require(URL(string: "https://youtube.com.evil.example/watch?v=dQw4w9WgXcQ"))
        let link = try #require(
            LibraryChatSuggestionList.linkable([
                AssistantChatSuggestion(title: "November Rain", artist: "Guns N' Roses", videoURL: hostile),
            ]).first
        )

        #expect(link.kind == .search)
        #expect(link.url == YouTubeSearchLink.url(title: "November Rain", artist: "Guns N' Roses"))
        #expect(link.url.host() == "www.youtube.com")
    }

    @Test("a non-/watch URL on the real host falls back too")
    func aNonWatchPathFallsBack() throws {
        for rejected in [
            "https://www.youtube.com/results?search_query=November+Rain",
            "https://www.youtube.com/watch?v=tooshort",
            "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com/",
        ] {
            let url = try #require(URL(string: rejected))
            let link = try #require(
                LibraryChatSuggestionList.linkable([
                    AssistantChatSuggestion(title: "November Rain", videoURL: url),
                ]).first
            )
            #expect(link.kind == .search, "\(rejected) must not render as a video link")
            #expect(link.url == YouTubeSearchLink.url(title: "November Rain", artist: nil))
        }
    }

    @Test("a URL-shaped TITLE is still only a title — it never becomes a destination")
    func aUrlShapedTitleIsNeverADestination() throws {
        // Prompt injection: a model that cannot fill `videoURL` writes a link where
        // it can. The title is search TERMS; only `videoURL` reaches the gate.
        let spelled = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let link = try #require(
            LibraryChatSuggestionList.linkable([
                AssistantChatSuggestion(title: spelled, artist: "[click here](\(spelled))"),
            ]).first
        )

        #expect(link.kind == .search)
        #expect(link.url == YouTubeSearchLink.url(title: spelled, artist: "[click here](\(spelled))"))
        #expect(link.url.absoluteString.hasPrefix("https://www.youtube.com/results?search_query="))
    }

    @Test("a miss with nothing to search for is still dropped, link or no link")
    func anUnlinkableMissIsStillDropped() {
        #expect(LibraryChatSuggestionList.linkable([AssistantChatSuggestion(title: "  ")]).isEmpty)
    }

    // MARK: - Copy Link

    @Test("Copy Link yields the row's raw URL, with no display formatting")
    func copyLinkYieldsTheRawURL() throws {
        let received = try #require(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        let video = try #require(
            LibraryChatSuggestionList.linkable([
                AssistantChatSuggestion(title: "November Rain", videoURL: received),
            ]).first
        )
        let search = try #require(
            LibraryChatSuggestionList.linkable([AssistantChatSuggestion(title: "November Rain")]).first
        )

        // The machine-readable contract: exactly the destination, character for
        // character — never the display name beside it.
        #expect(LibraryChatSuggestionList.copyText(for: video) == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(LibraryChatSuggestionList.copyText(for: search) == search.url.absoluteString)
        #expect(LibraryChatSuggestionList.copyText(for: video).contains(video.name) == false)
    }

    // MARK: - Identifiers a UI test can find

    @Test("each kind carries its own predictable identifier")
    func eachKindHasItsOwnIdentifier() throws {
        let received = try #require(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        let links = LibraryChatSuggestionList.linkable([
            AssistantChatSuggestion(title: "November Rain", videoURL: received),
            AssistantChatSuggestion(title: "Riders On The Storm"),
        ])
        let prefix = "assistant.chat.suggestions.0.0"

        #expect(LibraryChatSuggestionList.identifier(prefix: prefix, links[0]) == "\(prefix).link.video.0")
        #expect(LibraryChatSuggestionList.identifier(prefix: prefix, links[1]) == "\(prefix).link.search.1")
    }

    // MARK: - The on-device pointer banner

    @Test("the banner appears only on the on-device route, and only with BOTH records")
    func theBannerNeedsTheTripleCondition() {
        let settings = Self.settings(#function)
        let pointer = LibraryChatWebPointer()

        // Neither record: nothing to explain.
        #expect(!pointer.isVisible(route: .appleIntelligence, settings: settings))

        // The switch alone is not the grant — the disclosure is its own record.
        settings.webSuggestionsEnabled = true
        #expect(!pointer.isVisible(route: .appleIntelligence, settings: settings))

        settings.webSuggestionsEnabled = false
        settings.webSuggestionsConsented = true
        #expect(!pointer.isVisible(route: .appleIntelligence, settings: settings))

        settings.webSuggestionsEnabled = true
        #expect(pointer.isVisible(route: .appleIntelligence, settings: settings))
    }

    @Test("the banner is never shown on a cloud route, or when no conversation is possible")
    func theBannerIsNeverShownOnCloud() {
        let settings = Self.grantedSettings(#function)
        let pointer = LibraryChatWebPointer()

        // The cloud route is the one that actually GETS web suggestions, so a
        // pointer at it would be a lie about a feature that is working.
        #expect(!pointer.isVisible(
            route: .connector(id: "anthropic", displayName: "Anthropic Claude", model: "claude"),
            settings: settings
        ))
        // No route at all: `LibraryChatNoticeView` owns that explanation.
        #expect(!pointer.isVisible(route: nil, settings: settings))
    }

    @Test("dismissal is session state: dismiss hides it, reset leaves it hidden, a fresh launch shows it")
    func dismissalIsSessionScoped() {
        let settings = Self.grantedSettings(#function)
        let pointer = LibraryChatWebPointer()
        let chat = LibraryChatViewModel(makeEngine: { .failure(.unavailable(.modelNotReady)) })

        #expect(pointer.isVisible(route: .appleIntelligence, settings: settings))

        pointer.dismiss()
        #expect(!pointer.isVisible(route: .appleIntelligence, settings: settings))

        // "New Conversation" clears the transcript AND the tier's history. It does
        // not un-dismiss a notice the listener already read and closed.
        chat.reset()
        #expect(!pointer.isVisible(route: .appleIntelligence, settings: settings))

        // A new launch is a new instance. This is the assertion a `UserDefaults`
        // key would fail — which is exactly why there is not one.
        #expect(LibraryChatWebPointer().isVisible(route: .appleIntelligence, settings: settings))
    }

    // MARK: - The web tool's own caption

    @Test("web_search reads as a web search, not as the library fallback")
    func theWebToolHasItsOwnCaption() {
        let caption = LibraryChatStrings.toolCaption(for: WebSearchTool.toolName)

        #expect(caption.key != LibraryChatStrings.toolUnknown.key)
        #expect(caption.key == LibraryChatStrings.toolWebSearch.key)
        // And it does not borrow a library tool's wording either.
        #expect(caption.key != LibraryChatStrings.toolSearchTracks.key)
        // Its glyph is not the generic one, so the row reads as "web" at a glance.
        #expect(LibraryChatStrings.toolSymbol(for: WebSearchTool.toolName) == "globe")
    }

    @Test("a web lookup that answered with a count and no library rows states the count and draws no list")
    func aCountedWebLookupDrawsNoTrackChrome() {
        // `WebSearchTool` is the first tool to report a `resultCount` with no
        // library rows behind it. The count belongs in the caption; the track list
        // must stay absent rather than render empty chrome.
        let activity = AssistantChatActivity(name: WebSearchTool.toolName, resultCount: 4)

        #expect(activity.rows.isEmpty)
        #expect(ChatTrackResolver.trackIds(in: [activity]).isEmpty)
        #expect(LibraryChatTrackList.resolvedRows(activity.rows, in: [:]).isEmpty)
        #expect(LibraryChatSuggestionList.linkable(activity.suggestions).isEmpty)
        // The count still reaches the caption through the shared inflected template.
        #expect(LibraryChatStrings.toolResultCount(4).key == "app.assistant.chat.tool.resultCount")
    }
}

// MARK: - Fixtures

private extension LibraryChatSuggestionLinkTests {
    static let suitePrefix = "com.example.macamp.tests.libraryChatSuggestionLink"

    /// Both web-suggestion records written — the only state the banner can show in.
    static func grantedSettings(_ function: String) -> AppSettings {
        let settings = Self.settings(function)
        settings.webSuggestionsConsented = true
        settings.webSuggestionsEnabled = true
        return settings
    }

    /// A settings store on a volatile, per-test suite so nothing leaks into the
    /// developer's real preferences or between cases.
    static func settings(_ function: String) -> AppSettings {
        let suite = "\(suitePrefix).\(function)"
        guard let store = UserDefaults(suiteName: suite) else { return AppSettings(defaults: .standard) }
        store.removePersistentDomain(forName: suite)
        return AppSettings(defaults: store)
    }
}
