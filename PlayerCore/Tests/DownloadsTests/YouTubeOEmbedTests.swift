// Coverage of `YouTubeOEmbed` — the POLICY half of the oEmbed lookup, which is
// everything except the bytes: request-URL construction, the "did this answer?"
// decision, and the thumbnail-URL shape gate.
//
// All of it is pure, so this suite runs with zero network — which is the whole
// point of the split. `macOS/Sources/Downloads/YouTubeOEmbedClient.swift` is a
// shim over these three functions.
import Foundation
import Services
import Testing

/// One `(statusCode, body) -> nil` row. Every failure mode the plan names, plus the
/// ones the AIConnectorKit resolver measured against the live endpoint.
struct OEmbedRejectionCase: CustomStringConvertible {
    let name: String
    let response: OEmbedResponse?

    var description: String {
        name
    }
}

@Suite("YouTube oEmbed policy")
struct YouTubeOEmbedTests {
    static let videoID = "dQw4w9WgXcQ"

    /// A full live-shaped answer, unmodelled fields included on purpose: an
    /// upstream addition must not break decoding.
    static let liveShapedJSON = """
    {
      "title": "Rick Astley - Never Gonna Give You Up (Official Video)",
      "author_name": "Rick Astley",
      "author_url": "https://www.youtube.com/@RickAstleyYT",
      "type": "video",
      "height": 113,
      "width": 200,
      "version": "1.0",
      "provider_name": "YouTube",
      "provider_url": "https://www.youtube.com/",
      "thumbnail_height": 360,
      "thumbnail_width": 480,
      "thumbnail_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
      "html": "<iframe width=\\"200\\" height=\\"113\\" src=\\"https://www.youtube.com/embed/dQw4w9WgXcQ\\"></iframe>"
    }
    """

    static func ok(_ json: String) -> OEmbedResponse {
        OEmbedResponse(statusCode: 200, body: Data(json.utf8))
    }

    // MARK: - Request URL

    @Test("the request URL wraps the canonical watch URL as ONE opaque query value")
    func requestURLIsTheLiveVerifiedShape() throws {
        let url = try #require(YouTubeOEmbed.requestURL(forVideoID: Self.videoID))
        #expect(url.absoluteString == "https://www.youtube.com/oembed"
            + "?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3D\(Self.videoID)&format=json")
        // The inner `?v=` must be encoded, or it binds to the OUTER query and
        // YouTube is asked about a URL that stops at `/watch`.
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.count == 2)
        #expect(query.first?.name == "url")
        #expect(query.first?.value == "https://www.youtube.com/watch?v=\(Self.videoID)")
        #expect(query.last?.name == "format")
        #expect(query.last?.value == "json")
    }

    @Test("no API key, and no path but /oembed, ever appears in the request")
    func requestURLIsKeyless() throws {
        let url = try #require(YouTubeOEmbed.requestURL(forVideoID: Self.videoID))
        #expect(url.scheme == "https")
        #expect(url.host() == YouTubeOEmbed.endpointHost)
        #expect(url.path() == YouTubeOEmbed.endpointPath)
        let lowered = url.absoluteString.lowercased()
        #expect(lowered.contains("key=") == false)
        #expect(lowered.contains("token") == false)
        #expect(lowered.contains("authorization") == false)
    }

    @Test(
        "a malformed id builds no request at all",
        arguments: ["", "short", "twelvechars1", "dQw4w9WgXc!", "dQw4w9WgXc\u{00E9}"]
    )
    func requestURLRefusesAMalformedID(_ candidate: String) {
        #expect(YouTubeOEmbed.requestURL(forVideoID: candidate) == nil)
    }

    // MARK: - Decoding a real answer

    @Test("a live-shaped 200 decodes into title, uploader and thumbnail URL")
    func aLiveShapedAnswerDecodes() throws {
        let payload = try #require(YouTubeOEmbed.payload(from: Self.ok(Self.liveShapedJSON)))
        #expect(payload.title == "Rick Astley - Never Gonna Give You Up (Official Video)")
        #expect(payload.authorName == "Rick Astley")
        #expect(payload.thumbnailURL?.absoluteString == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    }

    @Test("the spec-level minimum — a bare title — is still an answer")
    func aTitleOnlyAnswerDecodes() throws {
        let payload = try #require(YouTubeOEmbed.payload(from: Self.ok(#"{"title":"Only a title"}"#)))
        #expect(payload.title == "Only a title")
        #expect(payload.authorName == nil)
        #expect(payload.thumbnailURL == nil)
    }

    /// `duration` is not an oEmbed field and MacAMP must not start depending on
    /// one appearing: duration keeps coming from the dequeue-time `-J` pass. A
    /// payload with a `duration` key decodes exactly like one without.
    @Test("an unmodelled duration key is ignored, not adopted")
    func durationIsNotPartOfThePayload() throws {
        let withDuration = try #require(
            YouTubeOEmbed.payload(from: Self.ok(#"{"title":"T","duration":212}"#))
        )
        let without = try #require(YouTubeOEmbed.payload(from: Self.ok(#"{"title":"T"}"#)))
        #expect(withDuration == without)
    }

    /// A bad `thumbnail_url` must not discard a good title — nothing depends on
    /// the thumbnail, and a paste-time title is the field the listener sees.
    @Test("an unparsable thumbnail_url degrades to nil without failing the payload")
    func aBadThumbnailURLDoesNotFailThePayload() throws {
        let payload = try #require(
            YouTubeOEmbed.payload(from: Self.ok(#"{"title":"T","thumbnail_url":"ht tp://not a url"}"#))
        )
        #expect(payload.title == "T")
        #expect(payload.thumbnailURL == nil)
    }

    // MARK: - Every failure collapses to nil

    static let rejections: [OEmbedRejectionCase] = [
        OEmbedRejectionCase(
            name: "404 — no such video",
            response: OEmbedResponse(statusCode: 404, body: Data(#"{"title":"T"}"#.utf8))
        ),
        OEmbedRejectionCase(
            name: "401 — private or deleted video",
            response: OEmbedResponse(statusCode: 401, body: Data(#"{"title":"T"}"#.utf8))
        ),
        OEmbedRejectionCase(
            name: "400 — the third status the same failure has been seen under",
            response: OEmbedResponse(statusCode: 400, body: Data(#"{"title":"T"}"#.utf8))
        ),
        OEmbedRejectionCase(
            name: "timeout / offline — the request never completed",
            response: nil
        ),
        OEmbedRejectionCase(
            name: "malformed — a 200 whose body is not JSON",
            response: OEmbedResponse(statusCode: 200, body: Data("Forbidden".utf8))
        ),
        OEmbedRejectionCase(
            name: "malformed — a 200 whose JSON is truncated",
            response: OEmbedResponse(statusCode: 200, body: Data(#"{"title":"T"#.utf8))
        ),
        OEmbedRejectionCase(
            name: "malformed — valid JSON carrying no title",
            response: OEmbedResponse(statusCode: 200, body: Data(#"{"author_name":"A"}"#.utf8))
        ),
        OEmbedRejectionCase(
            name: "malformed — a blank title tells the caller nothing",
            response: OEmbedResponse(statusCode: 200, body: Data(#"{"title":"   "}"#.utf8))
        ),
        OEmbedRejectionCase(
            name: "empty body",
            response: OEmbedResponse(statusCode: 200, body: Data())
        ),
        OEmbedRejectionCase(
            name: "over the size ceiling",
            response: OEmbedResponse(
                statusCode: 200,
                body: Data(count: YouTubeOEmbed.maximumResponseBytes + 1)
            )
        ),
        OEmbedRejectionCase(
            name: "500 — the endpoint itself is unwell",
            response: OEmbedResponse(statusCode: 500, body: Data(#"{"title":"T"}"#.utf8))
        ),
        OEmbedRejectionCase(
            name: "302 — a redirect the session did not follow",
            response: OEmbedResponse(statusCode: 302, body: Data())
        ),
    ]

    @Test("every failure mode answers a silent nil", arguments: rejections)
    func everyFailureIsNil(_ rejection: OEmbedRejectionCase) {
        #expect(YouTubeOEmbed.payload(from: rejection.response) == nil)
    }

    /// The rejection table only means something if the ACCEPTING branch is
    /// reachable through the very same function — otherwise a `payload` that
    /// always returned nil would pass all twelve rows.
    @Test("the rejection table is not vacuous: the same function does accept a 200")
    func theAcceptingBranchIsReachable() {
        #expect(YouTubeOEmbed.payload(from: Self.ok(Self.liveShapedJSON)) != nil)
    }

    // MARK: - Thumbnail bytes

    @Test("thumbnail bytes follow the same 2xx / non-empty / in-budget rule")
    func thumbnailBytesFollowTheSameRule() throws {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let accepted = try #require(
            YouTubeOEmbed.thumbnailData(from: OEmbedResponse(statusCode: 200, body: bytes))
        )
        #expect(accepted == bytes)
        #expect(YouTubeOEmbed.thumbnailData(from: nil) == nil)
        #expect(YouTubeOEmbed.thumbnailData(from: OEmbedResponse(statusCode: 404, body: bytes)) == nil)
        #expect(YouTubeOEmbed.thumbnailData(from: OEmbedResponse(statusCode: 200, body: Data())) == nil)
        #expect(
            YouTubeOEmbed.thumbnailData(
                from: OEmbedResponse(
                    statusCode: 200,
                    body: Data(count: YouTubeOEmbed.maximumResponseBytes + 1)
                )
            ) == nil
        )
    }

    @Test(
        "a thumbnail URL out of an untrusted body is re-checked, not trusted",
        arguments: [
            ("https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", true),
            ("https://i9.ytimg.com/vi/dQw4w9WgXcQ/hq720.jpg", true),
            ("http://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg", false),
            ("https://user:secret@i.ytimg.com/vi/x/hqdefault.jpg", false),
            ("https://i.ytimg.com:8443/vi/x/hqdefault.jpg", false),
            ("file:///etc/passwd", false),
            ("data:image/png;base64,AAAA", false),
        ]
    )
    func thumbnailURLsAreShapeChecked(_ candidate: String, _ isAccepted: Bool) throws {
        let url = try #require(URL(string: candidate))
        #expect((YouTubeOEmbed.validatedThumbnailURL(url) != nil) == isAccepted)
    }

    // MARK: - The two numeric policies

    /// Pinned so neither can drift silently: the window is what bounds fan-out at
    /// paste time, and the deadline is what makes the window deadlock-free.
    @Test("the window and the deadline are the values the client is built around")
    func thePoliciesArePinned() {
        #expect(YouTubeOEmbed.maximumConcurrentFetches == 4)
        #expect(YouTubeOEmbed.requestTimeoutSeconds == 5)
    }
}
