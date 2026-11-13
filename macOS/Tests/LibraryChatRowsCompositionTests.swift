// LibraryChatRowsCompositionTests — the track list a chat turn draws, and the links
// beside it.
//
// A rendered SwiftUI row cannot be inspected after the fact, so everything the list
// DECIDES lives in static functions on the two views and is driven here — the same
// arrangement `LibraryChatMessageRow.activityText(_:)` already uses, and for the same
// reason.
//
// Deliberately a NEW suite rather than more cases on `LibraryChatCompositionTests`:
// that struct sits at SwiftLint's `type_body_length` ceiling.
import AIConnectorBridge
import AIConnectorKit
import Foundation
@testable import MacAMP
import Persistence
import Services
import SwiftUI
import Testing
import ViewModels

/// Fixtures at file scope so both suites below share them without growing a type.
private enum Fixture {
    static func scoped(_ id: Int64, _ title: String, favourite: Bool = false) -> ProfileScopedTrack {
        ProfileScopedTrack(
            track: TrackRecord(id: id, filePath: "/Music/\(id).flac", title: title, artistName: "Artist \(id)"),
            isFavourite: favourite
        )
    }

    static func row(_ id: Int64?) -> AssistantChatRow {
        AssistantChatRow(trackId: id, title: id.map { "Title \($0)" }, artist: "Artist")
    }

    /// `count` rows numbered from 1, all of which resolve.
    static func resolvedPair(count: Int) -> ([AssistantChatRow], [Int64: ProfileScopedTrack]) {
        let ids = (1 ... Int64(count))
        return (
            ids.map { row($0) },
            Dictionary(uniqueKeysWithValues: ids.map { ($0, scoped($0, "Title \($0)")) })
        )
    }
}

@Suite("Library chat track rows")
@MainActor
struct LibraryChatRowsCompositionTests {
    // MARK: The rows a lookup answered with

    @Test("an allow-listed lookup's rows resolve into drawable rows, in the tool's order")
    func rowsResolveInToolOrder() {
        let resolved: [Int64: ProfileScopedTrack] = [
            7: Fixture.scoped(7, "Marrow"),
            3: Fixture.scoped(3, "Anvil"),
        ]
        let derived = LibraryChatTrackList.resolvedRows([Fixture.row(7), Fixture.row(3)], in: resolved)

        // The tool's order, NOT the dictionary's and NOT alphabetical: a lookup
        // answered with a running order and the transcript keeps it.
        #expect(derived.map(\.id) == [7, 3])
        #expect(derived.map(\.track.displayTitle) == ["Marrow", "Anvil"])
    }

    @Test("an id that no longer resolves is dropped, and the rest still draw")
    func anUnresolvableIdIsDropped() {
        // The QA failure scenario: the track was deleted between the turn and the
        // render. The row must be ABSENT, never a row that plays nothing.
        let resolved: [Int64: ProfileScopedTrack] = [1: Fixture.scoped(1, "Anvil")]
        let derived = LibraryChatTrackList.resolvedRows(
            [Fixture.row(1), Fixture.row(404), Fixture.row(nil)],
            in: resolved
        )

        #expect(derived.map(\.id) == [1])
    }

    @Test("no row resolves, so there is no list section at all")
    func zeroResolvedRowsRenderNothing() {
        let derived = LibraryChatTrackList.resolvedRows([Fixture.row(1), Fixture.row(2)], in: [:])

        #expect(derived.isEmpty)
        #expect(LibraryChatTrackList.visibleRows(derived, isExpanded: false).isEmpty)
        #expect(!LibraryChatTrackList.showsExpander(derived, isExpanded: false))
    }

    @Test("a repeated id is drawn once, so the list has no duplicate identities")
    func aRepeatedIdIsCollapsed() {
        let resolved: [Int64: ProfileScopedTrack] = [5: Fixture.scoped(5, "Cinder")]
        let derived = LibraryChatTrackList.resolvedRows([Fixture.row(5), Fixture.row(5)], in: resolved)

        #expect(derived.map(\.id) == [5])
    }

    // MARK: The cap and its expander

    @Test("the list shows ten rows and offers to show the rest, counting ALL of them")
    func theListCapsAtTenAndCountsTheWholeSet() {
        let (rows, resolved) = Fixture.resolvedPair(count: 14)
        let derived = LibraryChatTrackList.resolvedRows(rows, in: resolved)

        #expect(LibraryChatTrackList.visibleLimit == 10)
        #expect(derived.count == 14)
        #expect(LibraryChatTrackList.visibleRows(derived, isExpanded: false).count == 10)
        #expect(LibraryChatTrackList.showsExpander(derived, isExpanded: false))

        // The label states the TOTAL, not the hidden remainder — "Show all 14",
        // never "Show all 4".
        #expect(LibraryChatStrings.showAllTracks(count: derived.count).key == "app.assistant.chat.rows.showAll")

        let expanded = LibraryChatTrackList.visibleRows(derived, isExpanded: true)
        #expect(expanded.count == 14)
        #expect(!LibraryChatTrackList.showsExpander(derived, isExpanded: true))
    }

    @Test("exactly ten rows need no expander")
    func exactlyTenRowsNeedNoExpander() {
        let (rows, resolved) = Fixture.resolvedPair(count: 10)
        let derived = LibraryChatTrackList.resolvedRows(rows, in: resolved)

        #expect(LibraryChatTrackList.visibleRows(derived, isExpanded: false).count == 10)
        #expect(!LibraryChatTrackList.showsExpander(derived, isExpanded: false))
    }

    // MARK: What the message asks the database for

    @Test("the message resolves every lookup's ids once, in order, bounded and de-duplicated")
    func theResolveSetIsOrderedAndBounded() {
        let activities = [
            AssistantChatActivity(name: "search_tracks", rows: [Fixture.row(3), Fixture.row(1)]),
            AssistantChatActivity(name: "get_tracks", rows: [Fixture.row(1), Fixture.row(2), Fixture.row(nil)]),
        ]

        // One read per message: both lookups' ids, first-seen order, `1` not asked
        // for twice and a row with no id not asked for at all.
        #expect(ChatTrackResolver.trackIds(in: activities) == [3, 1, 2])
    }

    @Test("the resolve set is truncated deterministically at the repository's own cap")
    func theResolveSetIsTruncatedInOrder() {
        let overflowing = AssistantChatActivity(
            name: "search_tracks",
            rows: (1 ... 150).map { Fixture.row(Int64($0)) }
        )
        let ids = ChatTrackResolver.trackIds(in: [overflowing])

        // Ordered rather than a `Set`, so WHICH hundred survive does not vary
        // between runs — `resolvedTracks` would otherwise truncate a `Set`.
        #expect(ids.count == ChatTrackResolver.resolveLimit)
        #expect(ids == (1 ... 100).map(Int64.init))
    }

    @Test("a lookup that answered with nothing asks the database for nothing")
    func anEmptyLookupAsksForNothing() {
        #expect(ChatTrackResolver.trackIds(in: [AssistantChatActivity(name: "list_genres")]).isEmpty)
        #expect(ChatTrackResolver.trackIds(in: []).isEmpty)
    }
}

// MARK: - The misses beside the rows

@Suite("Library chat suggestions")
@MainActor
struct LibraryChatSuggestionCompositionTests {
    @Test("a suggestion's link is EXACTLY the helper's URL, never a field off the event")
    func theLinkIsTheHelperOutput() throws {
        let suggestion = AssistantChatSuggestion(title: "November Rain", artist: "Guns N' Roses")
        let link = try #require(LibraryChatSuggestionList.linkable([suggestion]).first)

        // Asserted against the helper rather than a hand-typed literal: the shell
        // must not own a second opinion about how a search URL is built.
        #expect(link.url == YouTubeSearchLink.url(title: "November Rain", artist: "Guns N' Roses"))
        #expect(link.name == "November Rain — Guns N' Roses")
        #expect(link.url.absoluteString.hasPrefix("https://www.youtube.com/results?search_query="))
    }

    @Test("a miss with no artist reads as its title alone and still links")
    func aMissWithNoArtistStillLinks() throws {
        let suggestion = AssistantChatSuggestion(title: "Riders On The Storm")
        let link = try #require(LibraryChatSuggestionList.linkable([suggestion]).first)

        #expect(link.name == "Riders On The Storm")
        #expect(link.url == YouTubeSearchLink.url(title: "Riders On The Storm", artist: nil))
    }

    @Test("a miss with nothing to search for is dropped rather than drawn dead")
    func anUnlinkableMissIsDropped() {
        #expect(LibraryChatSuggestionList.linkable([AssistantChatSuggestion(title: "  ")]).isEmpty)
        #expect(LibraryChatSuggestionList.linkable([]).isEmpty)
    }

    @Test("the misses cap at ten and the expander counts all of them")
    func theMissesCapAtTen() {
        let misses = (1 ... 13).map { AssistantChatSuggestion(title: "Miss \($0)", artist: "Artist") }
        let linkable = LibraryChatSuggestionList.linkable(misses)

        #expect(LibraryChatSuggestionList.visibleLimit == 10)
        #expect(linkable.count == 13)
        #expect(LibraryChatSuggestionList.visible(linkable, isExpanded: false).count == 10)
        #expect(LibraryChatSuggestionList.showsExpander(linkable, isExpanded: false))
        #expect(LibraryChatSuggestionList.visible(linkable, isExpanded: true).count == 13)
        #expect(!LibraryChatSuggestionList.showsExpander(linkable, isExpanded: true))
        #expect(
            LibraryChatStrings.showAllSuggestions(count: linkable.count).key
                == "app.assistant.chat.suggestions.showAll"
        )
    }
}

// MARK: - The mapping that feeds both lists

@Suite("Library chat connector rows mapping")
@MainActor
struct LibraryChatConnectorRowsMappingTests {
    @Test("the connector mapping now CARRIES the rows and misses it used to drop")
    func theMappingCarriesRowsAndSuggestions() {
        let mapped = ConnectorChatEventMapping.event(.toolResult(
            name: "match_tracks",
            text: "1 of 2 matched.",
            resultCount: 2,
            rows: [AIToolRow(trackId: 42, title: "Marrow", artist: "Anvil")],
            suggestions: [AIToolSuggestion(title: "November Rain", artist: "Guns N' Roses")]
        ))

        #expect(mapped == .toolResult(
            name: "match_tracks",
            summary: "1 of 2 matched.",
            resultCount: 2,
            rows: [AssistantChatRow(trackId: 42, title: "Marrow", artist: "Anvil")],
            suggestions: [AssistantChatSuggestion(title: "November Rain", artist: "Guns N' Roses")]
        ))
    }

    @Test("a result carrying no structure still maps to no structure — nothing is invented")
    func anEmptyResultInventsNothing() {
        let mapped = ConnectorChatEventMapping.event(
            .toolResult(name: "list_genres", text: "Jazz (12)", resultCount: 12)
        )

        #expect(mapped == .toolResult(name: "list_genres", summary: "Jazz (12)", resultCount: 12))
    }

    @Test("rows reach the activity the transcript draws, per lookup")
    func rowsReachTheActivityRow() {
        let turn = ConnectorChatTurn(
            text: "Two of those are yours.",
            events: [
                .toolCall(name: "match_tracks", argumentsJSON: "{}"),
                .toolResult(
                    name: "match_tracks",
                    text: "1 matched.",
                    resultCount: 1,
                    rows: [AIToolRow(trackId: 9, title: "Cinder", artist: "Quarry")],
                    suggestions: [AIToolSuggestion(title: "Harrow")]
                ),
            ],
            termination: .answered,
            history: [],
            rounds: 1
        )
        let activity = ConnectorChatEventMapping.reply(turn).turn.toolActivity

        #expect(activity == [AssistantChatActivity(
            name: "match_tracks",
            resultCount: 1,
            rows: [AssistantChatRow(trackId: 9, title: "Cinder", artist: "Quarry")],
            suggestions: [AssistantChatSuggestion(title: "Harrow")]
        )])
        #expect(ChatTrackResolver.trackIds(in: activity) == [9])
    }

    // MARK: The collapse decision

    @Test("a proposal turn with lookups folds its machinery; every other turn stays flat")
    func proposalTurnsCollapseTheirMachinery() {
        let gathering: [AssistantChatEvent] = [
            .toolCall(name: "search_tracks"),
            .toolResult(name: "search_tracks", summary: "Found 12.", resultCount: 12),
        ]
        let proposalTurn = LibraryChatMessage(
            role: .assistant, text: "Filed.", events: gathering, proposalIds: [UUID()]
        )
        #expect(LibraryChatMessageRow.collapsesActivity(proposalTurn))

        // The searches ARE the answer when nothing was filed — they stay visible.
        let searchTurn = LibraryChatMessage(role: .assistant, text: "Here.", events: gathering)
        #expect(!LibraryChatMessageRow.collapsesActivity(searchTurn))

        // A proposal with no lookups behind it has nothing to fold.
        let bareProposal = LibraryChatMessage(role: .assistant, text: "Filed.", proposalIds: [UUID()])
        #expect(!LibraryChatMessageRow.collapsesActivity(bareProposal))
    }
}
