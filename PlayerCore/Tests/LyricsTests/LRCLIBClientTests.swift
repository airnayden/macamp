import Foundation
import Lyrics
import Testing

// LRCLIBClientTests — drives the real ``LRCLIBClient`` end-to-end over a stubbed
// `URLProtocol`, so the `/api/get` → `/api/search` fallback is exercised without a
// single live network request. The transport is the seam; the client itself is
// production code.
//
// The stub keeps its handler in process-global state, so the suite is
// `.serialized` (Swift Testing runs suites concurrently by default).

// MARK: - Transport stub

/// A `URLProtocol` that answers every request from a registered handler and
/// records what it was asked for.
final class StubURLProtocol: URLProtocol {
    /// A canned HTTP reply.
    struct Reply {
        var status: Int
        var body: Data

        static func json(_ status: Int, _ text: String) -> Reply {
            Reply(status: status, body: Data(text.utf8))
        }

        static func notFound() -> Reply {
            Reply(status: 404, body: Data())
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Reply)?
    private nonisolated(unsafe) static var recorded: [URL] = []

    /// Installs `handler` and clears the recorded history.
    static func install(_ handler: @escaping @Sendable (URLRequest) throws -> Reply) {
        lock.withLock {
            Self.handler = handler
            recorded = []
        }
    }

    /// Removes the handler and history — call from every test's `defer`.
    static func reset() {
        lock.withLock {
            handler = nil
            recorded = []
        }
    }

    /// The URLs the client actually requested, in order.
    static var requestedURLs: [URL] {
        lock.withLock { recorded }
    }

    /// The `path` component of each requested URL, in order.
    static var requestedPaths: [String] {
        requestedURLs.map(\.path)
    }

    /// The query items of the first request hitting `path`, as a dictionary.
    static func query(forPath path: String) -> [String: String] {
        guard let url = requestedURLs.first(where: { $0.path == path }),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return [:] }
        return items.reduce(into: [:]) { result, item in result[item.name] = item.value }
    }

    /// A `URLSession` wired to this stub and nothing else.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let outcome = Self.lock.withLock { () -> Result<Reply, any Error>? in
            if let url = request.url { Self.recorded.append(url) }
            guard let handler = Self.handler else { return nil }
            return Result { try handler(request) }
        }
        guard let outcome else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch outcome {
        case let .success(reply):
            send(reply)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func send(_ reply: Reply) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: reply.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: nil
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Fixtures

private enum LRCLIBFixtures {
    static let host = "https://lrclib.test"
    static let getPath = "/api/get"
    static let searchPath = "/api/search"

    static func client() -> LRCLIBClient {
        LRCLIBClient(session: StubURLProtocol.makeSession(), baseURLString: host)
    }

    /// A `/api/get` 200 body.
    static func getBody(synced: String) -> String {
        """
        {"plainLyrics": "plain", "syncedLyrics": "\(synced)", "instrumental": false}
        """
    }

    /// One `/api/search` candidate row.
    static func candidate(id: Int, duration: Double, synced: String?) -> String {
        let syncedField = synced.map { "\"\($0)\"" } ?? "null"
        return """
        {"id": \(id), "trackName": "T", "artistName": "A", "albumName": "AL", \
        "duration": \(duration), "instrumental": false, \
        "plainLyrics": "plain-\(id)", "syncedLyrics": \(syncedField)}
        """
    }

    static func searchBody(_ candidates: String...) -> String {
        "[\(candidates.joined(separator: ","))]"
    }

    /// Answers `/api/get` with 404 and `/api/search` with `searchBody`.
    static func notFoundThenSearch(_ searchBody: String) -> @Sendable (URLRequest) throws -> StubURLProtocol.Reply {
        { request in
            request.url?.path == searchPath
                ? .json(200, searchBody)
                : .notFound()
        }
    }
}

// MARK: - Tests

@Suite("LRCLIBClientTests", .serialized)
struct LRCLIBClientTests {
    // MARK: /api/get

    @Test("a 200 from /api/get short-circuits — the search fallback never runs")
    func getHitSkipsSearch() async throws {
        StubURLProtocol.install { _ in .json(200, LRCLIBFixtures.getBody(synced: "[00:01.00]from-get")) }
        defer { StubURLProtocol.reset() }

        let result = try await LRCLIBFixtures.client()
            .fetch(artist: "A", title: "T", album: "AL", duration: 180)

        #expect(result?.syncedLyrics == "[00:01.00]from-get")
        #expect(StubURLProtocol.requestedPaths == [LRCLIBFixtures.getPath])
    }

    @Test("a non-404 error status still throws httpStatus — no silent fallback")
    func serverErrorThrows() async throws {
        StubURLProtocol.install { _ in .json(500, "boom") }
        defer { StubURLProtocol.reset() }

        let client = LRCLIBFixtures.client()
        await #expect(throws: OnlineLyricsError.httpStatus(500)) {
            try await client.fetch(artist: "A", title: "T", album: nil, duration: 180)
        }
        #expect(StubURLProtocol.requestedPaths == [LRCLIBFixtures.getPath])
    }

    // MARK: /api/search fallback

    @Test("a 404 falls back to search and picks the duration-closest candidate")
    func searchPicksClosestDuration() async throws {
        StubURLProtocol.install(LRCLIBFixtures.notFoundThenSearch(
            LRCLIBFixtures.searchBody(
                LRCLIBFixtures.candidate(id: 1, duration: 194, synced: "[00:01.00]far"),
                LRCLIBFixtures.candidate(id: 2, duration: 182, synced: "[00:01.00]closest"),
                LRCLIBFixtures.candidate(id: 3, duration: 172, synced: "[00:01.00]near")
            )
        ))
        defer { StubURLProtocol.reset() }

        let result = try await LRCLIBFixtures.client()
            .fetch(artist: "A", title: "T", album: "AL", duration: 180)

        #expect(result?.syncedLyrics == "[00:01.00]closest")
        #expect(StubURLProtocol.requestedPaths == [LRCLIBFixtures.getPath, LRCLIBFixtures.searchPath])
    }

    @Test("the search query carries track_name and artist_name, and no album_name")
    func searchQueryShape() async throws {
        StubURLProtocol.install(LRCLIBFixtures.notFoundThenSearch(LRCLIBFixtures.searchBody()))
        defer { StubURLProtocol.reset() }

        _ = try await LRCLIBFixtures.client()
            .fetch(artist: "Boards", title: "Roygbiv", album: "Music Has The Right", duration: 150)

        let query = StubURLProtocol.query(forPath: LRCLIBFixtures.searchPath)
        #expect(query["track_name"] == "Roygbiv")
        #expect(query["artist_name"] == "Boards")
        #expect(query["album_name"] == nil)
    }

    @Test("every candidate further than the 15 s tolerance is a no-match, not a wrong match")
    func searchRejectsOutOfToleranceCandidates() async throws {
        StubURLProtocol.install(LRCLIBFixtures.notFoundThenSearch(
            LRCLIBFixtures.searchBody(
                LRCLIBFixtures.candidate(id: 1, duration: 120, synced: "[00:01.00]short"),
                LRCLIBFixtures.candidate(id: 2, duration: 240, synced: "[00:01.00]long"),
                LRCLIBFixtures.candidate(id: 3, duration: 196, synced: "[00:01.00]just-over")
            )
        ))
        defer { StubURLProtocol.reset() }

        let result = try await LRCLIBFixtures.client()
            .fetch(artist: "A", title: "T", album: nil, duration: 180)

        #expect(result == nil)
        #expect(StubURLProtocol.requestedPaths == [LRCLIBFixtures.getPath, LRCLIBFixtures.searchPath])
    }

    @Test("a candidate exactly at the tolerance boundary is accepted")
    func searchAcceptsBoundaryCandidate() async throws {
        StubURLProtocol.install(LRCLIBFixtures.notFoundThenSearch(
            LRCLIBFixtures.searchBody(LRCLIBFixtures.candidate(id: 1, duration: 195, synced: "[00:01.00]edge"))
        ))
        defer { StubURLProtocol.reset() }

        let result = try await LRCLIBFixtures.client()
            .fetch(artist: "A", title: "T", album: nil, duration: 180)

        #expect(result?.syncedLyrics == "[00:01.00]edge")
    }

    @Test("candidates equidistant from the request break the tie toward synced lyrics")
    func searchTieBreaksTowardSynced() async throws {
        StubURLProtocol.install(LRCLIBFixtures.notFoundThenSearch(
            LRCLIBFixtures.searchBody(
                LRCLIBFixtures.candidate(id: 1, duration: 175, synced: nil),
                LRCLIBFixtures.candidate(id: 2, duration: 185, synced: "[00:01.00]synced")
            )
        ))
        defer { StubURLProtocol.reset() }

        let result = try await LRCLIBFixtures.client()
            .fetch(artist: "A", title: "T", album: nil, duration: 180)

        #expect(result?.syncedLyrics == "[00:01.00]synced")
    }

    @Test("with no request duration the first synced candidate wins")
    func searchWithoutDurationPrefersSynced() async throws {
        StubURLProtocol.install(LRCLIBFixtures.notFoundThenSearch(
            LRCLIBFixtures.searchBody(
                LRCLIBFixtures.candidate(id: 1, duration: 600, synced: nil),
                LRCLIBFixtures.candidate(id: 2, duration: 900, synced: "[00:01.00]only-synced")
            )
        ))
        defer { StubURLProtocol.reset() }

        let result = try await LRCLIBFixtures.client()
            .fetch(artist: "A", title: "T", album: nil, duration: nil)

        #expect(result?.syncedLyrics == "[00:01.00]only-synced")
    }

    @Test("an empty candidate list is a no-match")
    func searchWithNoCandidates() async throws {
        StubURLProtocol.install(LRCLIBFixtures.notFoundThenSearch(LRCLIBFixtures.searchBody()))
        defer { StubURLProtocol.reset() }

        let result = try await LRCLIBFixtures.client()
            .fetch(artist: "A", title: "T", album: nil, duration: 180)

        #expect(result == nil)
    }

    // MARK: Title guard

    @Test(
        "a blank or absent title never reaches /api/search — that request would 400",
        arguments: [nil, "", "   "] as [String?]
    )
    func blankTitleSkipsSearch(title: String?) async throws {
        StubURLProtocol.install { _ in .notFound() }
        defer { StubURLProtocol.reset() }

        let result = try await LRCLIBFixtures.client()
            .fetch(artist: "A", title: title, album: nil, duration: 180)

        #expect(result == nil)
        #expect(StubURLProtocol.requestedPaths == [LRCLIBFixtures.getPath])
    }

    // MARK: Error surfacing

    @Test("a network failure during the search phase surfaces — it is never swallowed")
    func searchNetworkFailureSurfaces() async throws {
        StubURLProtocol.install { request in
            guard request.url?.path == LRCLIBFixtures.searchPath else { return .notFound() }
            throw URLError(.networkConnectionLost)
        }
        defer { StubURLProtocol.reset() }

        let client = LRCLIBFixtures.client()
        await #expect(throws: (any Error).self) {
            try await client.fetch(artist: "A", title: "T", album: nil, duration: 180)
        }
        #expect(StubURLProtocol.requestedPaths == [LRCLIBFixtures.getPath, LRCLIBFixtures.searchPath])
    }

    @Test("a non-404 error status during the search phase throws httpStatus")
    func searchServerErrorThrows() async throws {
        StubURLProtocol.install { request in
            request.url?.path == LRCLIBFixtures.searchPath ? .json(503, "down") : .notFound()
        }
        defer { StubURLProtocol.reset() }

        let client = LRCLIBFixtures.client()
        await #expect(throws: OnlineLyricsError.httpStatus(503)) {
            try await client.fetch(artist: "A", title: "T", album: nil, duration: 180)
        }
    }

    @Test("a 404 from /api/search itself is a no-match, not an error")
    func searchNotFoundIsNoMatch() async throws {
        StubURLProtocol.install { _ in .notFound() }
        defer { StubURLProtocol.reset() }

        let result = try await LRCLIBFixtures.client()
            .fetch(artist: "A", title: "T", album: nil, duration: 180)

        #expect(result == nil)
        #expect(StubURLProtocol.requestedPaths == [LRCLIBFixtures.getPath, LRCLIBFixtures.searchPath])
    }

    // MARK: Etiquette

    @Test("both phases carry the LRCLIB User-Agent header")
    func bothPhasesSendUserAgent() async throws {
        let seen = UserAgentRecorder()
        StubURLProtocol.install { request in
            seen.record(request.value(forHTTPHeaderField: "User-Agent"))
            return .notFound()
        }
        defer { StubURLProtocol.reset() }

        _ = try await LRCLIBFixtures.client()
            .fetch(artist: "A", title: "T", album: nil, duration: 180)

        #expect(seen.values.count == 2)
        #expect(seen.values.allSatisfy { $0?.hasPrefix("MacAMP") == true })
    }
}

/// Collects the User-Agent of every stubbed request from the transport's thread.
private final class UserAgentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String?] = []

    func record(_ value: String?) {
        lock.withLock { seen.append(value) }
    }

    var values: [String?] {
        lock.withLock { seen }
    }
}
