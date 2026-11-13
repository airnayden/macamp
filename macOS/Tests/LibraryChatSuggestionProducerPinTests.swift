// LibraryChatSuggestionProducerPinTests — the shell's connector event mapping is not a
// producer of video links.
//
// ── WHY THIS SUITE EXISTS AT ALL ─────────────────────────────────────────────
//
// `AssistantChatSuggestion.videoURL` has exactly ONE writer: `LibraryChatViewModel`'s
// enrichment seam, which runs AFTER a turn has landed and admits only a URL its shell
// has already put through `YouTubeLinkResolver.validatedWatchURL` — AIConnectorKit's
// single sanctioned gate. Everything else that BUILDS a suggestion must leave the field
// nil.
//
// That used to be free. Before the field existed a model could hand back any URL it
// liked and there was nowhere on the type to put it, so "no unvalidated URL reaches the
// surface" was a property of the type system. The field retires that property, so it
// takes two tests to replace it — one per non-enricher producer:
//
//   * ``AssistantChatRow/suggestion(fromPayload:)`` (PlayerCore), pinned by
//     `AssistantTests/LibraryChatRowTests+ProducerPin.swift`
//   * `ConnectorChatEventMapping.event(_:)` — THIS file
//
// This is the macampMac SHELL's mapping, deliberately not `AIConnectorBridge`'s: the
// bridge's `LibraryToolAdapter` maps the OPPOSITE direction, PlayerCore's own
// discriminator into ``AIToolSuggestion``, and ``AIToolSuggestion`` has no `videoURL`
// field at all. So the kit structurally CANNOT hand one over, and what is left to pin
// is that this shell does not invent one on the way back.
import AIConnectorKit
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("LibraryChat suggestion producer pins")
struct LibraryChatSuggestionProducerPinTests {
    private static let misses = [
        AIToolSuggestion(title: "November Rain", artist: "Guns N' Roses"),
        AIToolSuggestion(title: "Riders On The Storm"),
    ]

    /// The suggestions one mapped event carries, or an empty list for any other case.
    private static func suggestions(in event: AssistantChatEvent) -> [AssistantChatSuggestion] {
        guard case let .toolResult(_, _, _, _, carried) = event else { return [] }
        return carried
    }

    @Test("The mapping copies title and artist field-for-field, and never a video link")
    func connectorMappingNeverWritesAVideoLink() {
        let mapped = ConnectorChatEventMapping.event(.toolResult(
            name: "match_tracks",
            text: "1 of 3 matched.",
            resultCount: 1,
            rows: [AIToolRow(trackId: 1, title: "Aurora Drift", artist: "Nova Field")],
            suggestions: Self.misses
        ))
        #expect(Self.suggestions(in: mapped) == [
            AssistantChatSuggestion(title: "November Rain", artist: "Guns N' Roses"),
            AssistantChatSuggestion(title: "Riders On The Storm"),
        ])
        #expect(Self.suggestions(in: mapped).allSatisfy { $0.videoURL == nil })
    }

    @Test("A miss whose TITLE is itself a URL is still only a title — never promoted to a link")
    func aUrlShapedTitleIsNotPromotedToALink() {
        // The adversarial shape: a model that cannot put a URL in a field it does not
        // have will put one where it can. The mapping must carry it as the text it is.
        let spelled = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let mapped = ConnectorChatEventMapping.event(.toolResult(
            name: "match_tracks",
            text: "Nothing matched.",
            resultCount: 0,
            suggestions: [AIToolSuggestion(title: spelled, artist: spelled)]
        ))
        #expect(Self.suggestions(in: mapped).first?.title == spelled)
        #expect(Self.suggestions(in: mapped).first?.videoURL == nil)
    }

    @Test("Every event a whole turn maps leaves its suggestions unlinked")
    func everyMappedEventLeavesItsSuggestionsUnlinked() {
        let events = ConnectorChatEventMapping.events([
            .assistantText("Two of those are not in your library."),
            .toolCall(name: "match_tracks", argumentsJSON: "{}"),
            .toolResult(name: "match_tracks", text: "1 of 3 matched.", resultCount: 1, suggestions: Self.misses),
            .toolResult(name: "search_tracks", text: "12 tracks.", resultCount: 12),
        ])
        let carried = events.flatMap(Self.suggestions(in:))
        #expect(carried.count == Self.misses.count)
        #expect(carried.allSatisfy { $0.videoURL == nil })
    }
}
