// ModelVideoLinkProposerTests — the untrusted half of the model-supplied link path.
//
// Every id this type hands back is verified downstream by
// `YouTubeLinkResolver.verify(_:proposedIDs:)`, which is covered in the kit's own
// suite. What is pinned HERE is the part that runs before any verification: reading
// a provider's JSON answer without ever pairing an id to a song that did not ask
// for it. Positional pairing is the whole risk — a shifted answer would attach
// Madonna's video to a Spice Girls row, and both would verify perfectly well.
//
// Pure functions over literals: no connector, no network, no schema round-trip.
import AIConnectorKit
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Model video-link proposer")
struct ModelVideoLinkProposerTests {
    private static func data(_ json: String) -> Data {
        Data(json.utf8)
    }

    // MARK: Reading the answer

    @Test("ids land at the index the answer names, not at the order it lists them in")
    func idsLandAtTheirNamedIndex() {
        let answer = Self.data(#"""
        {"videos":[{"index":2,"video_id":"ccccccccccc"},
                   {"index":0,"video_id":"aaaaaaaaaaa"}]}
        """#)

        let identifiers = ModelVideoLinkProposer.identifiers(in: answer, count: 3)

        #expect(identifiers == ["aaaaaaaaaaa", nil, "ccccccccccc"])
    }

    @Test("a null, blank or absent id reads as no proposal rather than as an empty one")
    func unusableIdsReadAsAbsent() {
        let answer = Self.data(#"""
        {"videos":[{"index":0,"video_id":null},
                   {"index":1,"video_id":"   "},
                   {"index":2}]}
        """#)

        #expect(ModelVideoLinkProposer.identifiers(in: answer, count: 3) == [nil, nil, nil])
    }

    @Test("an out-of-range index is DROPPED, never clamped onto a song nobody asked about")
    func outOfRangeIndexIsDropped() {
        let answer = Self.data(#"""
        {"videos":[{"index":7,"video_id":"zzzzzzzzzzz"},
                   {"index":-1,"video_id":"yyyyyyyyyyy"},
                   {"index":1,"video_id":"bbbbbbbbbbb"}]}
        """#)

        #expect(ModelVideoLinkProposer.identifiers(in: answer, count: 2) == [nil, "bbbbbbbbbbb"])
    }

    @Test("a malformed, empty or wrong-shaped answer yields no proposals at all")
    func malformedAnswersYieldNothing() {
        for json in ["not json at all", "{}", #"{"videos":[]}"#, #"{"videos":"nope"}"#, ""] {
            #expect(
                ModelVideoLinkProposer.identifiers(in: Self.data(json), count: 2) == [nil, nil],
                "\(json) must not produce a proposal"
            )
        }
    }

    // MARK: The prompt

    @Test("the prompt numbers songs from zero and names the artist only when there is one")
    func promptNumbersSongsAndTolerionsAMissingArtist() {
        let prompt = ModelVideoLinkProposer.prompt(for: [
            AssistantChatSuggestion(title: "Vogue", artist: "Madonna"),
            AssistantChatSuggestion(title: "Harrow"),
            AssistantChatSuggestion(title: "Torn", artist: "   "),
        ])

        #expect(prompt == "0. Vogue — Madonna\n1. Harrow\n2. Torn")
    }

    // MARK: The schema

    @Test("the schema asks for one entry per song, addressed by index")
    func schemaIsIndexAddressed() {
        let videos = ModelVideoLinkProposer.schema.property(named: "videos")

        #expect(videos != nil)
        #expect(ModelVideoLinkProposer.schema.requiredPropertyNames == ["videos"])
        // A model that does not know an id must be able to say so, or it will
        // invent one — the id field is the only nullable part of the contract.
        #expect(ModelVideoLinkProposer.instructions.contains("null"))
        #expect(ModelVideoLinkProposer.instructions.contains("a wrong id is worse than none"))
    }
}

// MARK: - The chain

/// The ordering that keeps a long answer inside the search provider's daily cap:
/// the model answers first, and the RATE-CAPPED search runs only for the songs it
/// could not supply. Measured 2026-09-09: once that cap trips, every unresolved
/// song silently degrades to a search link — so "how many searches did we spend"
/// is the behaviour worth pinning, not an implementation detail.
@Suite("Model-first link enrichment")
struct ModelFirstEnrichmentTests {
    /// Answers an id for song 0 only; song 1 is left for the search path.
    private struct OneIDConnector: AIProviderConnector {
        let id = "macamp.tests.oneid"
        let displayName = "One Id"
        let authDescriptor = AuthDescriptor.subscription

        func listModels() async throws -> [ModelInfo] {
            []
        }

        func structuredCompletion(
            schema _: JSONSchemaObject,
            instructions _: String,
            prompt _: String,
            model _: String
        ) async throws -> Data {
            Data(#"{"videos":[{"index":0,"video_id":"dQw4w9WgXcQ"}]}"#.utf8)
        }

        func completion(instructions _: String, prompt _: String, model _: String) async throws -> String {
            ""
        }
    }

    /// Answers oEmbed for any id, and records every host it was asked for so the
    /// test can assert the search provider was spared.
    private actor CountingTransport: HTTPTransport {
        private(set) var hosts: [String] = []

        func send(_ request: URLRequest) async throws -> HTTPResponse {
            hosts.append(request.url?.host ?? "")
            let body = #"{"title":"Never Gonna Give You Up","author_name":"Rick Astley"}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
    }

    @Test("the model's id resolves without a search, and only the leftover song is searched for")
    func searchRunsOnlyForWhatTheModelCouldNotSupply() async {
        let transport = CountingTransport()
        let resolver = YouTubeLinkResolver(transport: transport, batchDeadlineSeconds: 10)
        let proposer = ModelVideoLinkProposer(connector: OneIDConnector(), model: "test-model")
        let suggestions = [
            AssistantChatSuggestion(title: "Never Gonna Give You Up", artist: "Rick Astley"),
            AssistantChatSuggestion(title: "Some Song The Model Skipped", artist: "Nobody"),
        ]

        let enriched = await AppEnvironment.enriched(suggestions, using: resolver, proposer: proposer)

        // Song 0 came from the model and verified.
        #expect(enriched[0].videoURL?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        // Exactly one search host appears — song 1's. Song 0 never reached it.
        let searched = await transport.hosts.filter { $0.contains("tavily") }
        #expect(searched.count == 1, "the search provider must be spent only on the model's leftovers")
    }

    @Test("with no provider to ask, every song still takes the search path unchanged")
    func withoutAProposerNothingRegresses() async {
        let transport = CountingTransport()
        let resolver = YouTubeLinkResolver(transport: transport, batchDeadlineSeconds: 10)
        let suggestions = [AssistantChatSuggestion(title: "Never Gonna Give You Up", artist: "Rick Astley")]

        _ = await AppEnvironment.enriched(suggestions, using: resolver, proposer: nil)

        let searched = await transport.hosts.filter { $0.contains("tavily") }
        #expect(searched.count == 1)
    }
}
