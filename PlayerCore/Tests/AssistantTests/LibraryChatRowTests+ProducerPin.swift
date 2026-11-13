// LibraryChatRowTests+ProducerPin — the payload builder is not a producer of video
// links.
//
// ── WHY A TEST AND NOT A TYPE ────────────────────────────────────────────────
//
// ``AssistantChatSuggestion/videoURL`` has exactly ONE writer: `LibraryChatViewModel`'s
// enrichment seam, which runs AFTER a turn has landed and admits only a URL its shell
// has already put through `YouTubeLinkResolver.validatedWatchURL` — AIConnectorKit's
// single sanctioned gate. Before that field existed the property was STRUCTURAL: a
// model could hand back whatever it liked and there was nowhere on the type for it to
// sit. It is now a convention, and a convention with no test is a comment.
//
// There are exactly TWO non-enricher producers of ``AssistantChatSuggestion`` in this
// repo, so there are exactly two pins. This file holds the one that lives in
// PlayerCore — ``AssistantChatRow/suggestion(fromPayload:)``, which reads an UNTYPED
// `ToolboxJSON` a model's own tool call produced and is therefore the likeliest place
// for a stray key to be adopted. The other producer, the macOS shell's
// `ConnectorChatEventMapping`, is pinned by
// `macampMacTests/LibraryChatSuggestionProducerPinTests`.
//
// Declared as an EXTENSION of ``LibraryChatRowTests`` rather than as its own suite for
// two reasons: the QA lane filters on that suite's TYPE name, so a differently-named
// sibling would compile, pass locally and silently never run in the lane meant to gate
// it; and `LibraryChatRowTests.swift` is close enough to `file_length` that it has no
// room left.
import Foundation
@testable import Services
import Testing

extension LibraryChatRowTests {
    /// Every spelling a model could plausibly reach for, on one otherwise valid miss.
    ///
    /// The builder reads `kind`, `title` and `artist` and nothing else, so all of
    /// these must be IGNORED rather than adopted — including the two that name the
    /// field exactly.
    static var linkBearingMissPayload: ToolboxJSON {
        .object([
            "kind": .string("miss"),
            "title": .string("Ghost Song"),
            "artist": .string("Nobody"),
            "videoURL": .string("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            "video_url": .string("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            "url": .string("https://example.com/anything"),
        ])
    }

    @Test("No payload key can put a video link on a suggestion — the enricher is the only writer")
    func payloadBuiltSuggestionsNeverCarryAVideoLink() throws {
        let built = try #require(AssistantChatRow.suggestion(fromPayload: Self.linkBearingMissPayload))
        #expect(built == AssistantChatSuggestion(title: "Ghost Song", artist: "Nobody"))
        #expect(built.videoURL == nil)
        #expect(AssistantChatRow.suggestions(from: [Self.linkBearingMissPayload]).allSatisfy { $0.videoURL == nil })
    }

    @Test("The suggestions a shipped tool answers with carry no video link either")
    func toolBuiltSuggestionsNeverCarryAVideoLink() async throws {
        // Over the REAL toolbox, so the pin survives a payload-shape change one layer
        // down — the same reason the shape cases above drive shipped tools rather than
        // payload literals.
        let database = try ToolboxFixtures.makeLibrary()
        let toolbox = ToolboxFixtures.makeToolbox(database)
        let matched = try await toolbox.execute("match_tracks", arguments: ToolArguments(["pairs": .array([
            .object(["title": .string("Ghost Song"), "artist": .string("Nobody")]),
            .object(["title": .string("Second Ghost")]),
        ])]))
        let suggestions = AssistantChatRow.suggestions(from: matched.rows)
        #expect(suggestions.count == 2)
        #expect(suggestions.allSatisfy { $0.videoURL == nil })
    }
}
