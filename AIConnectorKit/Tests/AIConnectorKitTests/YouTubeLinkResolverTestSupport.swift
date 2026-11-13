// YouTubeLinkResolverTestSupport — fixtures and the URL-ROUTED transport the
// resolver suite drives. No test in this file or its suite touches the network.
//
// `FakeHTTPTransport` scripts responses in CALL ORDER, which is exactly wrong for
// a resolver that fans out up to four lookups at once: the arrival order of a
// concurrent batch is not defined, so a positional script would answer the wrong
// request. ``RoutingYouTubeTransport`` answers by URL instead — search host vs
// oEmbed host — which stays correct however the lookups interleave, and records
// the high-water mark of in-flight calls so the concurrency cap is measured
// rather than assumed.
import AIConnectorKit
import Foundation

/// The wire bodies the resolver parses, kept as literals so a payload-shape change
/// shows up as a diff rather than as a mystery nil.
enum YouTubeFixture {
    static let videoID = "dQw4w9WgXcQ"
    static let watchURLText = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    static let title = "Never Gonna Give You Up"
    static let artist = "Rick Astley"
    static let canonicalTitle = "Rick Astley - Never Gonna Give You Up (Official Video)"

    /// One `items` entry, shaped like the YouTube Data API v3 `search.list` reply.
    static let dataAPISearch = """
    {"items":[{"id":{"kind":"youtube#video","videoId":"\(videoID)"},\
    "snippet":{"title":"\(canonicalTitle)"}}]}
    """

    /// One `results` entry, shaped like Tavily's `/search` reply.
    static let tavilySearch = """
    {"results":[{"title":"\(canonicalTitle)","url":"\(watchURLText)","content":"snippet"}]}
    """

    /// A Tavily reply whose first hit is NOT a watch URL — the resolver must skip
    /// it and take the second rather than returning a channel page.
    static let tavilySearchWithLeadingJunk = """
    {"results":[{"title":"Channel","url":"https://www.youtube.com/@rickastley","content":"c"},\
    {"title":"\(canonicalTitle)","url":"\(watchURLText)","content":"snippet"}]}
    """

    /// A Tavily reply with no usable candidate at all.
    static let tavilySearchWithoutWatchURL = """
    {"results":[{"title":"Lyrics","url":"https://lyrics.invalid/never-gonna","content":"c"}]}
    """

    static func oEmbed(title: String = canonicalTitle) -> String {
        """
        {"title":"\(title)","author_name":"Rick Astley","provider_name":"YouTube","html":"<iframe/>"}
        """
    }

    static func response(_ json: String, statusCode: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
    }

    static func text(_ body: String, statusCode: Int) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, headers: ["Content-Type": "text/plain"], body: Data(body.utf8))
    }
}

/// A transport that answers by URL and measures how many calls overlap.
///
/// An `actor` for the same reason ``FakeHTTPTransport`` is one: the counters are
/// mutated from several concurrent lookups, and the delay suspends — which
/// RELEASES the actor — so `peakConcurrency` really does observe overlap instead
/// of serializing it away.
actor RoutingYouTubeTransport: HTTPTransport {
    private let canonicalTitle: String
    private let searchBody: String
    private let oEmbedStatusCode: Int
    private let delaySeconds: TimeInterval

    private(set) var recordedRequests: [URLRequest] = []
    private(set) var peakConcurrency = 0
    private var inFlight = 0

    init(
        canonicalTitle: String = YouTubeFixture.canonicalTitle,
        searchBody: String = YouTubeFixture.tavilySearch,
        oEmbedStatusCode: Int = 200,
        delaySeconds: TimeInterval = 0
    ) {
        self.canonicalTitle = canonicalTitle
        self.searchBody = searchBody
        self.oEmbedStatusCode = oEmbedStatusCode
        self.delaySeconds = delaySeconds
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        recordedRequests.append(request)
        inFlight += 1
        peakConcurrency = max(peakConcurrency, inFlight)
        defer { inFlight -= 1 }
        if delaySeconds > 0 {
            do {
                try await Task.sleep(for: .seconds(delaySeconds))
            } catch {
                throw ConnectorFailure.cancelled
            }
        }
        return response(for: request)
    }

    private func response(for request: URLRequest) -> HTTPResponse {
        switch request.url?.host {
        case "api.tavily.com", "www.googleapis.com":
            YouTubeFixture.response(searchBody)
        case "www.youtube.com":
            YouTubeFixture.response(YouTubeFixture.oEmbed(title: canonicalTitle), statusCode: oEmbedStatusCode)
        default:
            YouTubeFixture.text("not found", statusCode: 404)
        }
    }
}
