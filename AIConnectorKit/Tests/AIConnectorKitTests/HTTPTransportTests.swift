// HTTPTransportTests — the transport deadline fires instead of hanging.
//
// The deadline test drives a REAL `URLSessionTransport` against a stub
// `URLProtocol` that accepts a request and then says nothing, ever. That exercises
// the shipping code path — `URLSession`'s own timer, and this target's
// `URLError` → `ConnectorFailure` mapping — with zero network traffic, which a
// fake transport returning a canned `.timeout` could never prove.
import AIConnectorKit
import Foundation
import Testing

/// Accepts every request and never answers. `startLoading()` is deliberately
/// empty: it never calls its client, so only `URLSession`'s own deadline can end
/// the task.
///
/// Not `final`: `URLProtocol`'s factory entry points are `class func`s, and
/// SwiftLint's `static_over_final_class` rule would demand `static` on them the
/// moment the class were sealed — which is not how an override is spelled.
private class NeverRespondingURLProtocol: URLProtocol {
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {}

    override func stopLoading() {}
}

@Suite("HTTPTransportTests")
struct HTTPTransportTests {
    private static let probeURL = "https://connector.invalid/v1/models"

    /// Generous relative to the 0.5 s deadline under test, tight enough that a
    /// genuine hang fails the suite rather than wedging the run.
    private static let hangCeilingSeconds: TimeInterval = 10

    @Test("The shipped configuration carries the mandated deadlines")
    func shippedConfigurationCarriesTheMandatedDeadlines() {
        let configuration = URLSessionTransport.defaultConfiguration()

        #expect(URLSessionTransport.requestTimeout == 75)
        #expect(URLSessionTransport.resourceTimeout == 90)
        #expect(configuration.timeoutIntervalForRequest == 75)
        #expect(configuration.timeoutIntervalForResource == 90)
        // The tool loop's per-round deadline must be the BINDING bound: a
        // transport that fires first turns a legitimate long generation into
        // "did not answer in time" (measured 2026-09-09, 43-track playlist ask).
        #expect(URLSessionTransport.requestTimeout > ToolLoopEngine.defaultRoundDeadlineSeconds)
        #expect(URLSessionTransport.resourceTimeout > URLSessionTransport.requestTimeout)
        // The default `true` parks a request until connectivity returns, ignoring
        // the request timeout — that is a hang, not a deadline.
        #expect(configuration.waitsForConnectivity == false)
    }

    @Test("A never-responding endpoint fails with .timeout rather than hanging")
    func neverRespondingEndpointTimesOut() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeverRespondingURLProtocol.self]
        configuration.timeoutIntervalForRequest = 0.5
        configuration.timeoutIntervalForResource = 1
        configuration.waitsForConnectivity = false
        let transport = URLSessionTransport(configuration: configuration)
        let url = try #require(URL(string: Self.probeURL))
        let startedAt = Date()

        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await transport.send(URLRequest(url: url))
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        #expect(elapsed < Self.hangCeilingSeconds)
    }

    @Test("URLError codes map onto the taxonomy, unknown codes onto a stable token")
    func urlErrorCodesMapOntoTheTaxonomy() {
        #expect(URLSessionTransport.connectorFailure(for: URLError(.timedOut)) == .timeout)
        #expect(URLSessionTransport.connectorFailure(for: URLError(.cancelled)) == .cancelled)
        #expect(
            URLSessionTransport.connectorFailure(for: URLError(.cannotConnectToHost))
                == .unreachable(underlying: ConnectorFailure.DiagnosticToken.connectionRefused)
        )
        #expect(
            URLSessionTransport.connectorFailure(for: URLError(.cannotFindHost))
                == .unreachable(underlying: ConnectorFailure.DiagnosticToken.hostNotFound)
        )
        #expect(
            URLSessionTransport.connectorFailure(for: URLError(.notConnectedToInternet))
                == .unreachable(underlying: ConnectorFailure.DiagnosticToken.networkUnavailable)
        )
        #expect(
            URLSessionTransport.connectorFailure(for: URLError(.secureConnectionFailed))
                == .unreachable(underlying: ConnectorFailure.DiagnosticToken.secureConnectionFailed)
        )
        #expect(
            URLSessionTransport.connectorFailure(for: URLError(.badServerResponse))
                == .unreachable(underlying: ConnectorFailure.DiagnosticToken.transportFailure)
        )
    }

    @Test("The fake transport records requests and replays scripted responses in order")
    func fakeTransportRecordsAndReplaysInOrder() async throws {
        let first = HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        let transport = FakeHTTPTransport(scripts: [
            .success(first),
            .failure(.httpStatus(429, body: "slow down", providerMessage: nil)),
        ])
        let url = try #require(URL(string: Self.probeURL))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("test-token-abc", forHTTPHeaderField: "x-api-key")

        let response = try await transport.send(request)
        #expect(response == first)

        await #expect(throws: ConnectorFailure.httpStatus(429, body: "slow down", providerMessage: nil)) {
            _ = try await transport.send(request)
        }

        let recorded = await transport.recordedRequests
        #expect(recorded.count == 2)
        #expect(recorded.first?.httpMethod == "POST")
        #expect(recorded.first?.value(forHTTPHeaderField: "x-api-key") == "test-token-abc")
    }

    @Test("An unscripted call fails loudly instead of returning a canned success")
    func unscriptedCallFailsLoudly() async throws {
        let transport = FakeHTTPTransport()
        let url = try #require(URL(string: Self.probeURL))

        await #expect(throws: ConnectorFailure.unreachable(underlying: "fake-unscripted-request")) {
            _ = try await transport.send(URLRequest(url: url))
        }
    }

    @Test("The fake's never-respond mode reports a transport deadline, not a hang")
    func fakeNeverRespondModeReportsATransportDeadline() async throws {
        let transport = FakeHTTPTransport(scripts: [.neverRespond], simulatedRequestTimeout: 0.05)
        let url = try #require(URL(string: Self.probeURL))
        let startedAt = Date()

        await #expect(throws: ConnectorFailure.timeout) {
            _ = try await transport.send(URLRequest(url: url))
        }

        #expect(Date().timeIntervalSince(startedAt) < Self.hangCeilingSeconds)
    }

    @Test("Header lookup is case-insensitive, because providers disagree on casing")
    func headerLookupIsCaseInsensitive() {
        let response = HTTPResponse(statusCode: 429, headers: ["Retry-After": "30"])

        #expect(response.headerValue("retry-after") == "30")
        #expect(response.headerValue("RETRY-AFTER") == "30")
        #expect(response.headerValue("x-absent") == nil)
        #expect(response.isSuccess == false)
        #expect(HTTPResponse(statusCode: 204).isSuccess)
    }
}
