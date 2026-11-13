// YouTubeLinkProposedIDTests — the caller-proposed half of the link resolver.
//
// Split from `YouTubeLinkResolverTests.swift` for the usual mechanical reason:
// `.swiftlint.yml` does not override `file_length`, the ceiling is 400 lines and
// CI runs `--strict`. Same precedent as `AnthropicWireTypes.swift`.
//
// What these pin is the CONTRACT that makes a model-supplied id safe to render:
// a proposed id buys the caller only the SEARCH half of the work. The gate —
// shape, existence via oEmbed, and "it is the song that was asked for" — is
// identical to the one a searched candidate passes, so a wrong id answers nil
// and the caller falls back to the search link it would have shown anyway.
//
// ZERO live network: every hop is scripted through `RoutingYouTubeTransport`.
import AIConnectorKit
import Foundation
import Testing

@Suite("YouTubeLinkProposedIDTests")
struct YouTubeLinkProposedIDTests {
    private static let boundedSeconds: TimeInterval = 10

    private static func resolver(transport: any HTTPTransport) -> YouTubeLinkResolver {
        YouTubeLinkResolver(transport: transport, batchDeadlineSeconds: boundedSeconds)
    }

    private static var request: YouTubeLinkResolver.Request {
        YouTubeLinkResolver.Request(title: YouTubeFixture.title, artist: YouTubeFixture.artist)
    }

    // MARK: - Caller-proposed ids

    @Test("A proposed id is verified through oEmbed and NEVER searched for")
    func proposedIDSkipsTheSearchProvider() async {
        let transport = RoutingYouTubeTransport()
        let request = Self.request

        let verified = await Self.resolver(transport: transport)
            .verify([request], proposedIDs: [YouTubeFixture.videoID])

        #expect(verified.count == 1)
        #expect(verified[0]?.url.absoluteString == YouTubeFixture.watchURLText)
        // The whole point: the rate-capped search provider is never touched.
        let recorded = await transport.recordedRequests
        #expect(recorded.count == 1)
        #expect(recorded.first?.url?.path == "/oembed")
    }

    @Test("A proposed id whose video does not verify answers nil, so the caller can fall back")
    func unverifiableProposedIDAnswersNil() async {
        let transport = RoutingYouTubeTransport(oEmbedStatusCode: 404)
        let request = Self.request

        let verified = await Self.resolver(transport: transport)
            .verify([request], proposedIDs: [YouTubeFixture.videoID])

        #expect(verified == [nil])
    }

    @Test("A proposed id naming a DIFFERENT song fails the same token gate a search hit would")
    func proposedIDForAnotherSongIsRejected() async {
        let transport = RoutingYouTubeTransport(canonicalTitle: "Totally Unrelated Opera Aria")
        let request = Self.request

        let verified = await Self.resolver(transport: transport)
            .verify([request], proposedIDs: [YouTubeFixture.videoID])

        #expect(verified == [nil])
    }

    @Test("A malformed id spends no round-trip, and a nil id spends none either")
    func unusableProposedIDsIssueNoRequests() async {
        let transport = RoutingYouTubeTransport()
        let request = Self.request

        let verified = await Self.resolver(transport: transport)
            .verify([request, request], proposedIDs: ["not-an-id", nil])

        #expect(verified == [nil, nil])
        #expect(await transport.recordedRequests.isEmpty)
    }

    @Test("A length mismatch pairs nothing rather than pairing the wrong id to a song")
    func lengthMismatchPairsNothing() async {
        let transport = RoutingYouTubeTransport()
        let request = Self.request

        let verified = await Self.resolver(transport: transport)
            .verify([request, request], proposedIDs: [YouTubeFixture.videoID])

        #expect(verified == [nil, nil])
        #expect(await transport.recordedRequests.isEmpty)
    }
}
