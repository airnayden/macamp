// ConnectorFailureTotalityTests — the compile-time proof that the taxonomy is total.
//
// The classifier below carries NO `default:`. If a tenth case is ever added to
// `ConnectorFailure`, this FILE STOPS COMPILING and the whole target goes red —
// which is the entire point of a catch-all-free enum. Final-verification wave F2
// cites this test by name as the totality evidence; a text grep for `default:`
// would not be proof of anything.
import AIConnectorKit
import Foundation
import Testing

/// Maps every failure onto a machine token, exhaustively and without a catch-all.
private func diagnosticToken(for failure: ConnectorFailure) -> String {
    switch failure {
    case .unconfigured:
        "unconfigured"
    case let .unreachable(underlying):
        "unreachable:\(underlying)"
    case .timeout:
        "timeout"
    case let .httpStatus(code, body, providerMessage):
        "httpStatus:\(code):\(body ?? "-"):\(providerMessage ?? "-")"
    case .authExpired:
        "authExpired"
    case let .rateLimited(retryAfter):
        "rateLimited:\(retryAfter.map { "\($0)" } ?? "-")"
    case .malformedResponse:
        "malformedResponse"
    case .truncated:
        "truncated"
    case .cancelled:
        "cancelled"
    }
}

@Suite("ConnectorFailureTotalityTests")
struct ConnectorFailureTotalityTests {
    /// Every case, constructed. Held here rather than inline so the count
    /// assertion below has something to count.
    private static let everyCase: [ConnectorFailure] = [
        .unconfigured,
        .unreachable(underlying: ConnectorFailure.DiagnosticToken.connectionRefused),
        .timeout,
        .httpStatus(503, body: "service unavailable", providerMessage: "Service Unavailable"),
        .authExpired,
        .rateLimited(retryAfter: 30),
        .malformedResponse,
        .truncated,
        .cancelled,
    ]

    @Test("Every case is constructible and classified by a switch with no default:")
    func everyCaseIsMatchedExhaustively() {
        let tokens = Self.everyCase.map(diagnosticToken(for:))

        #expect(tokens == [
            "unconfigured",
            "unreachable:connection-refused",
            "timeout",
            "httpStatus:503:service unavailable:Service Unavailable",
            "authExpired",
            "rateLimited:30.0",
            "malformedResponse",
            "truncated",
            "cancelled",
        ])
    }

    @Test("The taxonomy has exactly the nine cases the plan specifies")
    func taxonomyHasNineDistinctCases() {
        #expect(Self.everyCase.count == 9)
        #expect(Set(Self.everyCase).count == 9)
    }

    @Test("A cut-off answer is its own case, never a malformed one")
    func truncationIsDistinctFromMalformed() {
        #expect(ConnectorFailure.truncated != .malformedResponse)
    }

    @Test("Associated values participate in equality, so tests can match exactly")
    func associatedValuesParticipateInEquality() {
        #expect(ConnectorFailure.httpStatus(429, body: nil, providerMessage: nil)
            != .httpStatus(429, body: "", providerMessage: nil))
        #expect(ConnectorFailure.httpStatus(500, body: "a", providerMessage: nil)
            != .httpStatus(500, body: "a", providerMessage: "a"))
        #expect(ConnectorFailure.httpStatus(500, body: "a", providerMessage: "a")
            == .httpStatus(500, body: "a", providerMessage: "a"))
        #expect(ConnectorFailure.rateLimited(retryAfter: nil) != .rateLimited(retryAfter: 0))
        #expect(
            ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.hostNotFound)
                != .unreachable(underlying: ConnectorFailure.DiagnosticToken.networkUnavailable)
        )
    }

    @Test("Optional payloads are genuinely optional, not empty-string sentinels")
    func optionalPayloadsStayOptional() {
        guard case let .httpStatus(code, body, providerMessage) = ConnectorFailure.httpStatus(
            418,
            body: nil,
            providerMessage: nil
        ) else {
            Issue.record("expected an httpStatus failure")
            return
        }
        #expect(code == 418)
        #expect(body == nil)
        #expect(providerMessage == nil)

        guard case let .rateLimited(retryAfter) = ConnectorFailure.rateLimited(retryAfter: nil) else {
            Issue.record("expected a rateLimited failure")
            return
        }
        #expect(retryAfter == nil)
    }

    @Test("A failure is throwable and catchable as itself")
    func failureRoundTripsThroughThrow() throws {
        func throwing() throws {
            throw ConnectorFailure.authExpired
        }

        #expect(throws: ConnectorFailure.authExpired) {
            try throwing()
        }
    }
}
