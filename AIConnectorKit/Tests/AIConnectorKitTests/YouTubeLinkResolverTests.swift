// YouTubeLinkResolverTests — "verified link or no link", proven without a socket.
//
// Three claims carry the feature, and each is asserted rather than described:
//
//   * THE RETURNED URL PASSED THE VALIDATOR. Every resolve assertion re-runs
//     `validatedWatchURL` on the result and expects it back unchanged — a
//     non-nil `ResolvedVideo` alone would also be produced by a resolver that
//     forgot the gate entirely.
//   * ONLY "200 + parseable JSON" VERIFIES. The status sweep drives 400 / 401 /
//     404 / 503 with a perfectly good JSON body, so the status gate is what
//     rejects them; the "Forbidden" case drives 200 with a body that is not JSON.
//   * NOTHING HANGS. The all-throwing transport and the blown-deadline batch both
//     assert a wall-clock ceiling, so a regression fails the suite instead of
//     wedging it.
//
// The oEmbed titles here are UNTRUSTED input by design (a video title is
// attacker-controlled): the hostile-input test drives quotes, an embedded URL,
// CJK and emoji through the matcher, and the emoji case pins that a request with
// no significant tokens resolves to nil rather than accepting whatever the
// provider said.
import AIConnectorKit
import Foundation
import Testing

@Suite("YouTubeLinkResolverTests")
struct YouTubeLinkResolverTests {
    private static let request = YouTubeLinkResolver.Request(
        title: YouTubeFixture.title,
        artist: YouTubeFixture.artist
    )

    /// A passing run finishes in well under a second; this only stops a regression
    /// from wedging the suite.
    private static let boundedSeconds: TimeInterval = 10

    private static func resolver(
        transport: any HTTPTransport,
        youTubeAPIKey: (@Sendable () async throws -> String)? = nil,
        searchAPIKey: (@Sendable () async throws -> String)? = nil,
        batchDeadlineSeconds: TimeInterval = boundedSeconds
    ) -> YouTubeLinkResolver {
        YouTubeLinkResolver(
            transport: transport,
            youTubeAPIKey: youTubeAPIKey,
            searchAPIKey: searchAPIKey,
            batchDeadlineSeconds: batchDeadlineSeconds
        )
    }

    // MARK: - The one validator

    @Test("validatedWatchURL accepts a canonical watch URL and hands it back unchanged")
    func validatorAcceptsCanonicalWatchURL() throws {
        let url = try #require(URL(string: YouTubeFixture.watchURLText))
        let validated = try #require(YouTubeLinkResolver.validatedWatchURL(url))

        #expect(validated.absoluteString == YouTubeFixture.watchURLText)
        // Idempotent: the gate's own output must survive a second pass, or the
        // view layer's pre-render check (todo 11) would reject what the resolver
        // just approved.
        #expect(YouTubeLinkResolver.validatedWatchURL(validated) == validated)
    }

    @Test("validatedWatchURL accepts the bare youtube.com host too")
    func validatorAcceptsBareHost() throws {
        let url = try #require(URL(string: "https://youtube.com/watch?v=\(YouTubeFixture.videoID)"))
        #expect(YouTubeLinkResolver.validatedWatchURL(url) != nil)
    }

    @Test("validatedWatchURL rejects foreign hosts, non-/watch paths and wrong-length ids")
    func validatorRejectsEverythingElse() throws {
        let rejected = [
            // Foreign hosts — including the lookalikes a naive `contains` check passes.
            "https://youtube.com.evil.invalid/watch?v=dQw4w9WgXcQ",
            "https://evil.invalid/watch?v=dQw4w9WgXcQ",
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ",
            // Not https.
            "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
            // Not /watch.
            "https://www.youtube.com/embed/dQw4w9WgXcQ",
            "https://www.youtube.com/@rickastley",
            "https://www.youtube.com/watch/extra?v=dQw4w9WgXcQ",
            // Ten and twelve characters.
            "https://www.youtube.com/watch?v=dQw4w9WgXc",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQQ",
            // Out-of-alphabet id, missing id, empty id.
            "https://www.youtube.com/watch?v=dQw4w9WgXc!",
            "https://www.youtube.com/watch?list=PL123456789",
            "https://www.youtube.com/watch?v=",
            // Credentials and a port are not the real host either.
            "https://user:pass@www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube.com:8443/watch?v=dQw4w9WgXcQ",
        ]

        for text in rejected {
            let url = try #require(URL(string: text), "fixture \(text) must parse")
            #expect(YouTubeLinkResolver.validatedWatchURL(url) == nil, "\(text) must be rejected")
        }
    }

    // MARK: - Keyed branch

    @Test("With a YouTube Data API key the keyed search runs and is still oEmbed-verified")
    func keyedBranchResolvesAndCrossChecks() async throws {
        let transport = RoutingYouTubeTransport(searchBody: YouTubeFixture.dataAPISearch)
        let resolver = Self.resolver(transport: transport, youTubeAPIKey: { "test-youtube-key" })

        let resolved = try #require(await resolver.resolve(Self.request))

        #expect(resolved.videoId == YouTubeFixture.videoID)
        #expect(resolved.canonicalTitle == YouTubeFixture.canonicalTitle)
        #expect(YouTubeLinkResolver.validatedWatchURL(resolved.url) == resolved.url)

        let recorded = await transport.recordedRequests
        #expect(recorded.count == 2)
        let search = try #require(recorded.first?.url?.absoluteString)
        #expect(search.hasPrefix("https://www.googleapis.com/youtube/v3/search?"))
        #expect(search.contains("part=snippet"))
        #expect(search.contains("type=video"))
        #expect(search.contains("maxResults=3"))
        #expect(search.contains("key=test-youtube-key"))
        // The verification hop is not optional on the keyed path.
        #expect(recorded.last?.url?.host == "www.youtube.com")
    }

    // MARK: - Keyless branch

    @Test("With no key the keyless search is youtube-scoped and the hit is verified")
    func keylessBranchResolvesAndVerifies() async throws {
        let transport = RoutingYouTubeTransport()
        let resolved = try #require(await Self.resolver(transport: transport).resolve(Self.request))

        #expect(resolved.videoId == YouTubeFixture.videoID)
        #expect(YouTubeLinkResolver.validatedWatchURL(resolved.url) == resolved.url)

        let recorded = await transport.recordedRequests
        #expect(recorded.count == 2)
        let search = try #require(recorded.first)
        #expect(search.url?.absoluteString == "https://api.tavily.com/search")
        #expect(search.httpMethod == "POST")
        #expect(search.value(forHTTPHeaderField: "X-Tavily-Access-Mode") == "keyless")
        #expect(search.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(search.httpBody.flatMap { String(bytes: $0, encoding: .utf8) })
        #expect(body.contains("\"include_domains\":[\"youtube.com\"]"))
    }

    @Test("A search API key swaps the keyless header for a bearer and changes nothing else")
    func searchKeySwapsTheHeader() async throws {
        let transport = RoutingYouTubeTransport()
        let resolver = Self.resolver(transport: transport, searchAPIKey: { "test-tavily-key" })

        _ = await resolver.resolve(Self.request)

        let search = try #require(await transport.recordedRequests.first)
        #expect(search.value(forHTTPHeaderField: "Authorization") == "Bearer test-tavily-key")
        #expect(search.value(forHTTPHeaderField: "X-Tavily-Access-Mode") == nil)
        #expect(search.url?.absoluteString == "https://api.tavily.com/search")
    }

    @Test("A leading non-watch hit is skipped; the first candidate that PASSES the gate wins")
    func nonWatchCandidatesAreSkipped() async throws {
        let transport = RoutingYouTubeTransport(searchBody: YouTubeFixture.tavilySearchWithLeadingJunk)
        let resolved = try #require(await Self.resolver(transport: transport).resolve(Self.request))

        #expect(resolved.videoId == YouTubeFixture.videoID)
        #expect(YouTubeLinkResolver.validatedWatchURL(resolved.url) == resolved.url)
    }

    @Test("No candidate means no verification hop at all")
    func noCandidateSkipsVerification() async {
        let transport = RoutingYouTubeTransport(searchBody: YouTubeFixture.tavilySearchWithoutWatchURL)

        #expect(await Self.resolver(transport: transport).resolve(Self.request) == nil)
        let recorded = await transport.recordedRequests
        #expect(recorded.count == 1)
    }

    // MARK: - oEmbed verification

    @Test("The oEmbed request percent-encodes the inner watch URL into ONE query value")
    func oEmbedRequestIsPercentEncoded() async throws {
        let transport = RoutingYouTubeTransport()
        _ = await Self.resolver(transport: transport).resolve(Self.request)

        let verification = try #require(await transport.recordedRequests.last?.url?.absoluteString)
        #expect(verification.contains("url=https%3A%2F%2F"))
        // Raw interpolation would bind `&format=` to the OUTER query and `v=` would
        // escape as its own parameter — both are visible right here.
        #expect(verification.contains("%3Fv%3D\(YouTubeFixture.videoID)"))
        #expect(verification.hasSuffix("&format=json"))
        #expect(verification.hasPrefix("https://www.youtube.com/oembed?"))
    }

    @Test("Neither branch ever fetches a watch page — every youtube.com hop is oEmbed")
    func watchPageHTMLIsNeverFetched() async {
        // Scraping `youtube.com/watch` breaches the Terms of Service, so the only
        // request either branch may aim at youtube.com is the oEmbed JSON endpoint.
        // Both are driven: a keyed path that confirmed a hit by fetching the watch
        // page would breach the terms exactly as badly as a keyless one.
        let keyless = RoutingYouTubeTransport()
        _ = await Self.resolver(transport: keyless).resolve(Self.request)

        let keyed = RoutingYouTubeTransport(searchBody: YouTubeFixture.dataAPISearch)
        _ = await Self.resolver(transport: keyed, youTubeAPIKey: { "test-youtube-key" }).resolve(Self.request)

        // Search + verification per branch, and nothing else — an extra hop would
        // be a fetch this assertion has not vetted.
        let issued = await keyless.recordedRequests + keyed.recordedRequests
        #expect(issued.count == 4)
        for url in issued.compactMap(\.url) {
            #expect(url.path != "/watch", "\(url) fetches a watch page")
            guard url.host?.hasSuffix("youtube.com") == true else { continue }
            #expect(url.path == "/oembed", "\(url) is not the oEmbed endpoint")
        }
    }

    @Test("Every non-200 oEmbed answer resolves to nil, whatever the body says")
    func everyNonSuccessStatusIsUnresolved() async {
        for status in [400, 401, 403, 404, 429, 500, 503] {
            let transport = RoutingYouTubeTransport(oEmbedStatusCode: status)
            let resolved = await Self.resolver(transport: transport).resolve(Self.request)
            #expect(resolved == nil, "status \(status) must be unresolved")
        }
    }

    @Test("A 200 whose body is not JSON — the observed 'Forbidden' shape — resolves to nil")
    func twoHundredWithUnparseableBodyIsUnresolved() async {
        let transport = FakeHTTPTransport(scripts: [
            .success(YouTubeFixture.response(YouTubeFixture.tavilySearch)),
            .success(YouTubeFixture.text("Forbidden", statusCode: 200)),
        ])

        #expect(await Self.resolver(transport: transport).resolve(Self.request) == nil)
        let recorded = await transport.recordedRequests
        #expect(recorded.count == 2)
    }

    @Test("A canonical title that shares too few tokens with the request resolves to nil")
    func titleMismatchIsUnresolved() async {
        let transport = RoutingYouTubeTransport(canonicalTitle: "Ten Hours of Rain Sounds for Sleeping")

        #expect(await Self.resolver(transport: transport).resolve(Self.request) == nil)
    }

    @Test("Half the significant tokens is enough — a cover or live version still verifies")
    func halfOverlapVerifies() async throws {
        let transport = RoutingYouTubeTransport(canonicalTitle: "NEVER GONNA GIVE YOU UP — live cover")
        let resolved = try #require(await Self.resolver(transport: transport).resolve(Self.request))

        #expect(YouTubeLinkResolver.validatedWatchURL(resolved.url) == resolved.url)
    }

    // MARK: - Hostile input

    @Test("Hostile titles fold and tokenize without crashing, and never fabricate a link")
    func hostileTitlesAreHandled() async {
        let hostile = [
            "\"Quoted\" — He said: <script>alert(1)</script>",
            "https://evil.invalid/watch?v=AAAAAAAAAAA",
            "%s %@ %n {0} \\(injection)",
            "🎵🎶🎵",
        ]

        for title in hostile {
            let request = YouTubeLinkResolver.Request(title: title, artist: nil)
            // A transport that answers nothing but failures — the title must not be
            // able to produce a link on its own.
            let resolved = await Self.resolver(transport: FakeHTTPTransport()).resolve(request)
            #expect(resolved == nil, "hostile title must not resolve: \(title)")
        }
    }

    @Test("A request with no significant tokens stays unresolved even on a perfect 200")
    func unverifiableRequestStaysUnresolved() async {
        let transport = RoutingYouTubeTransport()
        let request = YouTubeLinkResolver.Request(title: "🎵🎶", artist: nil)

        #expect(await Self.resolver(transport: transport).resolve(request) == nil)
    }

    @Test("Diacritics and CJK fold rather than blocking a genuine match")
    func foldedTokensMatch() async throws {
        let transport = RoutingYouTubeTransport(canonicalTitle: "YOASOBI - 夜に駆ける / Into The Night")
        let request = YouTubeLinkResolver.Request(title: "夜に駆ける", artist: "YOASOBI")
        let resolved = try #require(await Self.resolver(transport: transport).resolve(request))

        #expect(YouTubeLinkResolver.validatedWatchURL(resolved.url) == resolved.url)

        let accented = RoutingYouTubeTransport(canonicalTitle: "Bjork - Joga (Official Video)")
        let accentedRequest = YouTubeLinkResolver.Request(title: "Jóga", artist: "Björk")
        #expect(await Self.resolver(transport: accented).resolve(accentedRequest) != nil)
    }

    // MARK: - Batch

    @Test("A batch of ten resolves in order and never exceeds the concurrency cap")
    func batchRespectsTheConcurrencyCap() async {
        let transport = RoutingYouTubeTransport(delaySeconds: 0.02)
        let requests = Array(repeating: Self.request, count: 10)
        let startedAt = Date()

        let resolved = await Self.resolver(transport: transport).resolve(requests)

        #expect(Date().timeIntervalSince(startedAt) < Self.boundedSeconds)
        #expect(resolved.count == 10)
        #expect(resolved.allSatisfy { $0?.videoId == YouTubeFixture.videoID })
        let peak = await transport.peakConcurrency
        #expect(peak <= YouTubeLinkResolver.maximumConcurrentLookups)
        // And it really is concurrent — a serial resolver would peak at 1.
        #expect(peak > 1)
        let recorded = await transport.recordedRequests
        #expect(recorded.count == 20)
    }

    @Test("A batch that blows its deadline yields all-nil promptly instead of hanging")
    func batchDeadlineBoundsTheWholeRun() async {
        let transport = RoutingYouTubeTransport(delaySeconds: 30)
        let resolver = Self.resolver(transport: transport, batchDeadlineSeconds: 0.2)
        let requests = Array(repeating: Self.request, count: 10)
        let startedAt = Date()

        let resolved = await resolver.resolve(requests)

        #expect(Date().timeIntervalSince(startedAt) < Self.boundedSeconds)
        #expect(resolved.count == 10)
        #expect(resolved.allSatisfy { $0 == nil })
    }

    @Test("An all-throwing transport yields all-nil in bounded time and never throws")
    func throwingTransportYieldsAllNil() async {
        let requests = Array(repeating: Self.request, count: 10)
        let startedAt = Date()

        let resolved = await Self.resolver(transport: FakeHTTPTransport()).resolve(requests)

        #expect(Date().timeIntervalSince(startedAt) < Self.boundedSeconds)
        #expect(resolved.count == 10)
        #expect(resolved.allSatisfy { $0 == nil })
    }

    @Test("An empty batch is answered without a single request")
    func emptyBatchIssuesNoRequests() async {
        let transport = RoutingYouTubeTransport()

        #expect(await Self.resolver(transport: transport).resolve([]).isEmpty)
        let recorded = await transport.recordedRequests
        #expect(recorded.isEmpty)
    }
}
