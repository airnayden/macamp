// WithDeadlineTests — the outer deadline bounds work a transport timeout cannot see.
//
// The load-bearing case is an operation that performs NO transport call at all: an
// async credential provider, a Keychain read against a locked keychain, or a token
// refresh. `URLSessionConfiguration`'s timeouts are blind to every one of those,
// so the assistant's single-in-flight busy latch would be held indefinitely
// without this helper.
//
// "Cancels the loser" is asserted, not assumed: the operation records that it
// observed cancellation, so a helper that merely stopped WAITING for the loser
// while it ran on in the background would fail this suite.
import AIConnectorKit
import Foundation
import Testing

/// Records that the bounded operation observed cooperative cancellation.
private actor CancellationWitness {
    private(set) var didObserveCancellation = false

    func record() {
        didObserveCancellation = true
    }
}

@Suite("WithDeadlineTests")
struct WithDeadlineTests {
    /// Longer than any deadline under test — the operation only ends by cancellation.
    private static let neverSeconds: TimeInterval = 30

    /// A passing run finishes in well under a second; this only stops a regression
    /// from wedging the suite.
    private static let hangCeilingSeconds: TimeInterval = 10

    @Test("A never-returning operation that touches no transport is bounded and cancelled")
    func neverReturningOperationIsBoundedAndCancelled() async throws {
        let witness = CancellationWitness()
        let transport = FakeHTTPTransport()
        let startedAt = Date()

        await #expect(throws: ConnectorFailure.timeout) {
            try await withDeadline(seconds: 0.2) { () async throws -> Int in
                do {
                    try await Task.sleep(for: .seconds(Self.neverSeconds))
                } catch {
                    await witness.record()
                    throw error
                }
                return 0
            }
        }

        #expect(Date().timeIntervalSince(startedAt) < Self.hangCeilingSeconds)

        // The loser was cancelled, not abandoned.
        let observedCancellation = await witness.didObserveCancellation
        #expect(observedCancellation)

        // And it never went near the network — this is the layer a transport
        // timeout cannot reach.
        let recorded = await transport.recordedRequests
        #expect(recorded.isEmpty)
    }

    @Test("An operation that finishes in time returns its value")
    func operationThatFinishesInTimeReturnsItsValue() async throws {
        let value = try await withDeadline(seconds: Self.hangCeilingSeconds) { () async throws -> Int in
            try await Task.sleep(for: .milliseconds(10))
            return 42
        }

        #expect(value == 42)
    }

    @Test("An operation's own failure propagates unchanged, never laundered into .timeout")
    func operationFailurePropagatesUnchanged() async {
        await #expect(throws: ConnectorFailure.httpStatus(503, body: "service unavailable", providerMessage: nil)) {
            try await withDeadline(seconds: Self.hangCeilingSeconds) { () async throws -> Int in
                throw ConnectorFailure.httpStatus(503, body: "service unavailable", providerMessage: nil)
            }
        }
    }

    @Test("A non-positive budget fails immediately rather than waiting forever")
    func nonPositiveBudgetFailsImmediately() async {
        await #expect(throws: ConnectorFailure.timeout) {
            try await withDeadline(seconds: 0) { () async throws -> Int in
                try await Task.sleep(for: .seconds(Self.neverSeconds))
                return 0
            }
        }

        await #expect(throws: ConnectorFailure.timeout) {
            try await withDeadline(seconds: -5) { () async throws -> Int in
                try await Task.sleep(for: .seconds(Self.neverSeconds))
                return 0
            }
        }
    }

    @Test("The deadline also bounds a slow transport call, and only one is issued")
    func deadlineBoundsASlowTransportCall() async throws {
        let slow = HTTPResponse(statusCode: 200, body: Data("{}".utf8))
        let transport = FakeHTTPTransport(scripts: [.delayed(slow, seconds: Self.neverSeconds)])
        let url = try #require(URL(string: "https://connector.invalid/v1/models"))
        let startedAt = Date()

        await #expect(throws: ConnectorFailure.timeout) {
            try await withDeadline(seconds: 0.2) {
                try await transport.send(URLRequest(url: url))
            }
        }

        #expect(Date().timeIntervalSince(startedAt) < Self.hangCeilingSeconds)
        let recorded = await transport.recordedRequests
        #expect(recorded.count == 1)
    }

    @Test("Deadlines nest: the inner budget wins when it is the tighter one")
    func deadlinesNest() async {
        await #expect(throws: ConnectorFailure.timeout) {
            try await withDeadline(seconds: Self.hangCeilingSeconds) { () async throws -> Int in
                try await withDeadline(seconds: 0.1) { () async throws -> Int in
                    try await Task.sleep(for: .seconds(Self.neverSeconds))
                    return 0
                }
            }
        }
    }
}
