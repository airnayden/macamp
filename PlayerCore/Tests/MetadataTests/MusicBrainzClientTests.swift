import Foundation
@testable import Metadata
import Testing

@Suite("MusicBrainzClientTests")
struct MusicBrainzClientTests {
    // MARK: - Response mapping

    @Test("parses the first recording match into a MetadataLookupResult")
    func parsesFirstMatch() throws {
        let result = try MusicBrainzClient.parseFirstMatch(from: Data(Self.sampleJSON.utf8))
        let match = try #require(result)
        #expect(match.title == "Come Together")
        #expect(match.artist == "The Beatles")
        #expect(match.album == "Abbey Road")
        #expect(match.year == 1969)
        #expect(match.trackNumber == 1)
        #expect(match.discNumber == 1)
        #expect(match.genre == "Rock")
        let artwork = try #require(match.artworkURL)
        #expect(artwork.absoluteString == "https://coverartarchive.org/release/abc-release/front")
    }

    @Test("an empty recordings array is no match (nil)")
    func emptyRecordingsIsNil() throws {
        let result = try MusicBrainzClient.parseFirstMatch(from: Data(#"{"recordings":[]}"#.utf8))
        #expect(result == nil)
    }

    @Test("a missing recordings key is no match (nil)")
    func missingRecordingsIsNil() throws {
        let result = try MusicBrainzClient.parseFirstMatch(from: Data(#"{"count":0}"#.utf8))
        #expect(result == nil)
    }

    @Test("a joined artist-credit is concatenated with its joinphrase")
    func joinsArtistCredit() throws {
        let json = #"""
        {"recordings":[{"title":"X","artist-credit":[
        {"name":"Artist A","joinphrase":" feat. "},{"name":"Artist B"}]}]}
        """#
        let match = try #require(try MusicBrainzClient.parseFirstMatch(from: Data(json.utf8)))
        #expect(match.artist == "Artist A feat. Artist B")
    }

    // MARK: - Query construction

    @Test("the Lucene query phrase-quotes each present term")
    func luceneQueryFormat() {
        let query = MusicBrainzClient.luceneQuery(artist: "The Beatles", title: "Come Together", album: nil)
        #expect(query == #"artist:"The Beatles" AND recording:"Come Together""#)
    }

    @Test("a query with no usable terms is empty")
    func luceneQueryEmpty() {
        #expect(MusicBrainzClient.luceneQuery(artist: "  ", title: nil, album: nil).isEmpty)
    }

    // MARK: - Year parsing

    @Test("a year is parsed from the leading four digits, else nil")
    func yearParsing() {
        #expect(MusicBrainzClient.year(from: "1969-09-26") == 1969)
        #expect(MusicBrainzClient.year(from: "1969") == 1969)
        #expect(MusicBrainzClient.year(from: "19") == nil)
        #expect(MusicBrainzClient.year(from: nil) == nil)
    }

    // MARK: - MockMetadataFetcher

    @Test("the mock returns its canned result and records the query")
    func mockReturnsAndRecords() async throws {
        let canned = MetadataLookupResult(title: "T1", artist: "A1")
        let mock = MockMetadataFetcher(returning: canned)
        let result = try await mock.lookup(artist: "A1", title: "T1", album: nil, duration: 120)
        #expect(result == canned)
        #expect(mock.lookupCount == 1)
        let query = try #require(mock.queries.first)
        #expect(query.artist == "A1")
        #expect(query.title == "T1")
        #expect(query.duration == 120)
    }

    @Test("the mock returns nil by default (no match)")
    func mockDefaultsToNil() async throws {
        let mock = MockMetadataFetcher()
        let result = try await mock.lookup(artist: "A1", title: "T1", album: nil, duration: nil)
        #expect(result == nil)
    }

    @Test("the mock throws its configured error")
    func mockThrows() async {
        let mock = MockMetadataFetcher(throwing: OnlineMetadataError.httpStatus(503))
        await #expect(throws: OnlineMetadataError.self) {
            _ = try await mock.lookup(artist: "A1", title: "T1", album: nil, duration: nil)
        }
    }

    // MARK: - Recording id + composer follow-up

    @Test("the first match carries the recording MBID for the composer follow-up")
    func parsesRecordingID() throws {
        let match = try #require(try MusicBrainzClient.parseFirstMatch(from: Data(Self.sampleJSON.utf8)))
        #expect(match.recordingID == "abc-recording")
    }

    @Test("a composer is extracted from the work's artist relationships")
    func parsesComposer() {
        #expect(MusicBrainzClient.parseComposer(from: Data(Self.composerJSON.utf8)) == "Lennon-McCartney")
    }

    @Test("a body with no composer relation yields nil")
    func composerAbsentIsNil() {
        let json = #"{"id":"x","relations":[{"target-type":"work","work":{"relations":[]}}]}"#
        #expect(MusicBrainzClient.parseComposer(from: Data(json.utf8)) == nil)
    }

    @Test("a malformed composer body is nil, never an error")
    func composerMalformedIsNil() {
        #expect(MusicBrainzClient.parseComposer(from: Data("not json".utf8)) == nil)
    }

    @Test("the default lookupComposer returns nil (mock has no composer source)")
    func mockComposerDefaultsToNil() async throws {
        let mock = MockMetadataFetcher()
        let composer = try await mock.lookupComposer(recordingID: "abc")
        #expect(composer == nil)
    }

    // MARK: - Fixtures

    private static let sampleJSON = #"""
    {
      "count": 1,
      "recordings": [
        {
          "id": "abc-recording",
          "title": "Come Together",
          "artist-credit": [
            { "name": "The Beatles", "artist": { "name": "The Beatles" } }
          ],
          "releases": [
            {
              "id": "abc-release",
              "title": "Abbey Road",
              "date": "1969-09-26",
              "release-group": { "first-release-date": "1969-09-26" },
              "media": [
                { "position": 1, "track": [ { "number": "1", "position": 1 } ] }
              ]
            }
          ],
          "tags": [ { "count": 3, "name": "rock" }, { "count": 1, "name": "classic rock" } ]
        }
      ]
    }
    """#

    private static let composerJSON = #"""
    {
      "id": "abc-recording",
      "title": "Come Together",
      "relations": [
        {
          "type": "performance",
          "target-type": "work",
          "work": {
            "id": "work-1",
            "title": "Come Together",
            "relations": [
              { "type": "composer", "target-type": "artist", "artist": { "name": "Lennon-McCartney" } }
            ]
          }
        }
      ]
    }
    """#
}

// MARK: - Multi-candidate fixtures

enum MusicBrainzCandidateFixtures {
    /// Five candidates in the order MusicBrainz would rank them — by TEXT relevance,
    /// so the 354 s album version the caller actually wants sits fourth, behind a
    /// 210 s radio edit.
    static let fiveCandidates = #"""
    {
      "count": 5,
      "recordings": [
        { "id": "r-radio", "title": "Radio Edit", "length": 210000 },
        { "id": "r-remaster", "title": "2011 Remaster", "length": 368000 },
        { "id": "r-extended", "title": "Extended Mix", "length": 512000 },
        { "id": "r-album", "title": "Album Version", "length": 354000 },
        { "id": "r-live", "title": "Live 1972", "length": 402000 }
      ]
    }
    """#

    static let noLengths = #"""
    {
      "recordings": [
        { "id": "r-radio", "title": "Radio Edit" },
        { "id": "r-album", "title": "Album Version" }
      ]
    }
    """#
}

// MARK: - Candidate selection

/// These decode real JSON bodies rather than hand-built ``MBRecording`` values: a
/// `length` missing from `CodingKeys` decodes as `nil` and turns the whole selection
/// into a silent no-op, which only a decode-backed test can catch.
@Suite("MusicBrainzClientSelectionTests")
struct MusicBrainzClientSelectionTests {
    @Test("the recording length decodes from JSON in milliseconds")
    func decodesLengthMilliseconds() throws {
        let body = Data(MusicBrainzCandidateFixtures.fiveCandidates.utf8)
        let response = try JSONDecoder().decode(MBSearchResponse.self, from: body)
        let recordings = try #require(response.recordings)
        #expect(recordings.map(\.length) == [210_000, 368_000, 512_000, 354_000, 402_000])
    }

    @Test("the duration-nearest candidate wins, not the first")
    func picksNearestDuration() throws {
        let body = Data(MusicBrainzCandidateFixtures.fiveCandidates.utf8)
        let match = try #require(try MusicBrainzClient.parseFirstMatch(from: body, duration: 355))
        #expect(match.title == "Album Version")
    }

    @Test("no requested duration keeps MusicBrainz's own ranking (the first candidate)")
    func nilDurationKeepsFirst() throws {
        let body = Data(MusicBrainzCandidateFixtures.fiveCandidates.utf8)
        let match = try #require(try MusicBrainzClient.parseFirstMatch(from: body, duration: nil))
        #expect(match.title == "Radio Edit")
    }

    @Test("every candidate further apart than the tolerance falls back to the first")
    func outOfToleranceFallsBackToFirst() throws {
        let body = Data(MusicBrainzCandidateFixtures.fiveCandidates.utf8)
        let match = try #require(try MusicBrainzClient.parseFirstMatch(from: body, duration: 600))
        #expect(match.title == "Radio Edit")
    }

    @Test("candidates carrying no length at all fall back to the first")
    func missingLengthFallsBackToFirst() throws {
        let body = Data(MusicBrainzCandidateFixtures.noLengths.utf8)
        let match = try #require(try MusicBrainzClient.parseFirstMatch(from: body, duration: 355))
        #expect(match.title == "Radio Edit")
    }

    @Test("equal deltas keep MusicBrainz's own ranking (the earlier candidate)")
    func equalDeltasKeepRanking() throws {
        let json = #"""
        {"recordings":[{"id":"earlier","title":"A","length":350000},
        {"id":"later","title":"B","length":360000}]}
        """#
        let response = try JSONDecoder().decode(MBSearchResponse.self, from: Data(json.utf8))
        let best = try #require(MusicBrainzClient.bestMatch(from: response.recordings ?? [], duration: 355))
        #expect(best.id == "earlier")
    }

    @Test("a candidate exactly at the tolerance boundary still matches")
    func toleranceBoundaryIsInclusive() throws {
        let json = #"{"recordings":[{"title":"First","length":600000},{"title":"Edge","length":370000}]}"#
        let match = try #require(try MusicBrainzClient.parseFirstMatch(from: Data(json.utf8), duration: 355))
        #expect(match.title == "Edge")
        #expect(MusicBrainzClient.durationTolerance == 15)
    }

    @Test("an empty recordings array is still no match (nil), never a throw")
    func emptyRecordingsStillNil() throws {
        let result = try MusicBrainzClient.parseFirstMatch(from: Data(#"{"recordings":[]}"#.utf8), duration: 355)
        #expect(result == nil)
    }

    @Test("a malformed body still propagates a DecodingError")
    func malformedBodyStillThrows() {
        #expect(throws: DecodingError.self) {
            try MusicBrainzClient.parseFirstMatch(from: Data("not json".utf8), duration: 355)
        }
    }
}

// MARK: - Transport stub

/// A `URLProtocol` that answers every request with one canned 200 JSON body and
/// records the URL it was asked for. Its state is process-global, so the suite that
/// installs it is `.serialized`.
final class MusicBrainzStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var body = Data()
    private nonisolated(unsafe) static var recorded: [URL] = []

    static func install(json: String) {
        lock.withLock {
            body = Data(json.utf8)
            recorded = []
        }
    }

    /// Removes the body and history — call from every test's `defer`.
    static func reset() {
        lock.withLock {
            body = Data()
            recorded = []
        }
    }

    /// The query items of the first recorded request, as a dictionary.
    static var firstQuery: [String: String] {
        let first = lock.withLock { recorded.first }
        guard let first,
              let items = URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        return items.reduce(into: [:]) { result, item in result[item.name] = item.value }
    }

    /// A `URLSession` wired to this stub and nothing else.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MusicBrainzStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let payload = Self.lock.withLock { () -> Data in
            if let url = request.url { Self.recorded.append(url) }
            return Self.body
        }
        if let url = request.url,
           let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - End-to-end lookup

@Suite("MusicBrainzClientLookupTests", .serialized)
struct MusicBrainzClientLookupTests {
    @Test("lookup asks for five candidates and returns the duration-nearest one")
    func lookupPicksNearestCandidate() async throws {
        MusicBrainzStubURLProtocol.install(json: MusicBrainzCandidateFixtures.fiveCandidates)
        defer { MusicBrainzStubURLProtocol.reset() }
        let client = Self.makeClient()
        let result = try await client.lookup(
            artist: "The Beatles",
            title: "Come Together",
            album: nil,
            duration: 355
        )
        let match = try #require(result)
        #expect(match.title == "Album Version")
        #expect(MusicBrainzStubURLProtocol.firstQuery["limit"] == "5")
    }

    @Test("lookup without a duration returns the first (search-ranked) candidate")
    func lookupWithoutDurationKeepsFirst() async throws {
        MusicBrainzStubURLProtocol.install(json: MusicBrainzCandidateFixtures.fiveCandidates)
        defer { MusicBrainzStubURLProtocol.reset() }
        let client = Self.makeClient()
        let result = try await client.lookup(artist: "The Beatles", title: "Come Together", album: nil, duration: nil)
        let match = try #require(result)
        #expect(match.title == "Radio Edit")
    }

    /// `.zero` disables the limiter's sleep — the shared 1 req/sec gate itself is
    /// untouched, and a limit-5 search is still exactly ONE request.
    private static func makeClient() -> MusicBrainzClient {
        MusicBrainzClient(
            session: MusicBrainzStubURLProtocol.makeSession(),
            baseURLString: "https://musicbrainz.test",
            minimumInterval: .zero
        )
    }
}
