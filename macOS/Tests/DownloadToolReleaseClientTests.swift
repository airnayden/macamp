import Foundation
@testable import MacAMP
import os
import Services
import Testing

@Suite("Release transport bounds", .serialized)
struct DownloadToolReleaseClientTests {
    @Test("overflow cancels before the remaining body arrives", arguments: [nil, "1"] as [String?])
    func overflowStopsTransport(contentLength: String?) async throws {
        let fixture = try ReleaseResponseFixture(contentLength: contentLength, firstChunk: 9)
        let client = makeClient(fixture)

        await #expect(throws: DownloadError.updateFailed(detail: "release payload exceeded the size ceiling")) {
            try await client.fetchData(from: fixture.url)
        }

        #expect(await fixture.waitForCancellation())
        #expect(!fixture.state.withLock { $0.tailDelivered })
    }

    @Test("an oversized declared length is refused before the body")
    func declaredOverflowStopsTransport() async throws {
        let fixture = try ReleaseResponseFixture(contentLength: "100", firstChunk: 1)
        let client = makeClient(fixture)

        await #expect(throws: DownloadError.updateFailed(detail: "release payload exceeded the size ceiling")) {
            try await client.fetchData(from: fixture.url)
        }

        #expect(await fixture.waitForCancellation())
        #expect(!fixture.state.withLock { $0.firstDelivered })
    }

    @Test("HTTP errors stop the body at the response headers")
    func httpErrorStopsTransport() async throws {
        let fixture = try ReleaseResponseFixture(status: 503, firstChunk: 1)
        let client = makeClient(fixture)

        await #expect(throws: DownloadError.updateFailed(detail: "release feed answered HTTP 503")) {
            try await client.fetchData(from: fixture.url)
        }

        #expect(await fixture.waitForCancellation())
        #expect(!fixture.state.withLock { $0.firstDelivered })
    }

    @Test("a body exactly at the limit is returned intact")
    func exactLimitSucceeds() async throws {
        let fixture = try ReleaseResponseFixture(firstChunk: 4)
        let client = makeClient(fixture)

        let data = try await client.fetchData(from: fixture.url)

        #expect(data == Data(repeating: 42, count: 8))
        #expect(fixture.state.withLock { $0.tailDelivered })
    }

    @Test("cancellation while waiting for more bytes remains cancellation")
    func cancellationPropagates() async throws {
        let fixture = try ReleaseResponseFixture(firstChunk: 4)
        let client = makeClient(fixture)
        let fetch = Task { try await client.fetchData(from: fixture.url) }
        for _ in 0 ..< 100 where !fixture.state.withLock({ $0.firstDelivered }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.state.withLock { $0.firstDelivered })

        fetch.cancel()

        await #expect(throws: CancellationError.self) { try await fetch.value }
        #expect(await fixture.waitForCancellation())
        #expect(!fixture.state.withLock { $0.tailDelivered })
    }

    @Test("non-HTTPS URLs are still refused")
    func rejectsInsecureURL() async throws {
        let fixture = try ReleaseResponseFixture(firstChunk: 4)
        let client = makeClient(fixture)
        let url = try #require(URL(string: "http://release.invalid/asset"))

        await #expect(throws: DownloadError.updateFailed(detail: "refusing a non-HTTPS release URL")) {
            try await client.fetchData(from: url)
        }

        #expect(!fixture.state.withLock { $0.firstDelivered })
    }

    private func makeClient(_ fixture: ReleaseResponseFixture) -> DownloadToolReleaseClient {
        ReleaseResponseProtocol.fixture.withLock { $0 = fixture }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseResponseProtocol.self]
        return DownloadToolReleaseClient(session: URLSession(configuration: configuration), maximumResponseBytes: 8)
    }
}

private final class ReleaseResponseFixture: Sendable {
    struct State {
        var cancelled = false
        var firstDelivered = false
        var tailDelivered = false
    }

    let state = OSAllocatedUnfairLock(initialState: State())
    let contentLength: String?
    let status: Int
    let firstChunk: Int
    let url: URL

    init(contentLength: String? = nil, status: Int = 200, firstChunk: Int) throws {
        url = try #require(URL(string: "https://release.invalid/asset"))
        self.contentLength = contentLength
        self.status = status
        self.firstChunk = firstChunk
    }

    func waitForCancellation() async -> Bool {
        for _ in 0 ..< 100 {
            if state.withLock({ $0.cancelled }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private class ReleaseResponseProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = OSAllocatedUnfairLock<ReleaseResponseFixture?>(initialState: nil)
    private let activeFixture = OSAllocatedUnfairLock<ReleaseResponseFixture?>(initialState: nil)

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var headers = ["Content-Type": "application/octet-stream"]
        if let length = Self.fixture.withLock({ $0?.contentLength }) { headers["Content-Length"] = length }
        guard let fixture = Self.fixture.withLock({ $0 }), let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1",
                  headerFields: headers
              ) else { return }
        activeFixture.withLock { $0 = fixture }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            guard !fixture.state.withLock({ $0.cancelled }) else { return }
            fixture.state.withLock { $0.firstDelivered = true }
            client?.urlProtocol(self, didLoad: Data(repeating: 42, count: fixture.firstChunk))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in
                guard !fixture.state.withLock({ $0.cancelled }) else { return }
                fixture.state.withLock { $0.tailDelivered = true }
                client?.urlProtocol(self, didLoad: Data(repeating: 42, count: 4))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {
        activeFixture.withLock { $0 }?.state.withLock { $0.cancelled = true }
    }
}
