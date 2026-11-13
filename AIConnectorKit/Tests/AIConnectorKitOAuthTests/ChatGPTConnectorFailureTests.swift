// ChatGPTConnectorFailureTests — the non-2xx taxonomy, split out of
// `ChatGPTConnectorTests.swift`.
//
// Split for one mechanical reason: `file_length` is capped at 400 under
// `swiftlint --strict`, and the 2026-08-24 live-flip assertions pushed the parent
// suite past it.
//
// The claim worth isolating is the FIRST one below: a Cloudflare managed challenge
// and an expired session are both HTTP 403, and reporting the wrong one costs the
// listener a pointless re-login for a credential that was never the problem.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

@Suite("ChatGPTConnectorFailureMappingTests")
struct ChatGPTConnectorFailureMappingTests {
    @Test("401 and a plain 403 are an expired session")
    func unauthorizedMapsToAuthExpired() async throws {
        for status in [401, 403] {
            let transport = FakeTokenTransport([
                .success(ChatGPTConnectorFixture.json("{\"error\":\"unauthorized\"}", statusCode: status)),
            ])
            await #expect(throws: ConnectorFailure.authExpired) {
                try await ChatGPTConnectorFixture.connector(transport: transport).listModels()
            }
        }
    }

    @Test("A Cloudflare managed challenge is unreachable, NOT an expired session")
    func botMitigationIsNotReportedAsAnExpiredSession() async throws {
        // Telling a listener to sign in again would be a lie that costs them a
        // pointless re-login: the credential is fine, the edge network is not
        // convinced this is a browser. This is finding (1) behind the disabled
        // determination, asserted rather than asserted-in-prose.
        let labelled = FakeTokenTransport([
            .success(HTTPResponse(
                statusCode: 403,
                headers: ["cf-mitigated": "challenge", "Content-Type": "text/html"],
                body: Data("<!DOCTYPE html>Just a moment...".utf8)
            )),
        ])
        let expected = ConnectorFailure.unreachable(underlying: ChatGPTConnector.botMitigationToken)
        await #expect(throws: expected) {
            try await ChatGPTConnectorFixture.connector(transport: labelled).listModels()
        }

        // Unlabelled HTML behind a 403 is the same event without the header.
        let unlabelled = FakeTokenTransport([
            .success(HTTPResponse(
                statusCode: 403,
                headers: ["Content-Type": "text/html; charset=UTF-8"],
                body: Data("<html>Attention Required!</html>".utf8)
            )),
        ])
        await #expect(throws: expected) {
            try await ChatGPTConnectorFixture.connector(transport: unlabelled).listModels()
        }
    }

    @Test("429 carries the retry-after when the provider sent a parseable one")
    func rateLimitCarriesRetryAfter() async throws {
        let transport = FakeTokenTransport([
            .success(HTTPResponse(
                statusCode: 429,
                headers: ["Retry-After": "30"],
                body: Data("{\"error\":\"insufficient_quota\"}".utf8)
            )),
        ])
        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: 30)) {
            try await ChatGPTConnectorFixture.connector(transport: transport).listModels()
        }

        // An HTTP-date value reads as absent rather than as a bad duration.
        let dated = FakeTokenTransport([
            .success(HTTPResponse(statusCode: 429, headers: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"])),
        ])
        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: nil)) {
            try await ChatGPTConnectorFixture.connector(transport: dated).listModels()
        }
    }

    @Test("A pre-stream quota refusal carries resets_in_seconds, exactly as the mid-stream one does")
    func preStreamQuotaRefusalCarriesTheResetDuration() async throws {
        // MEASURED 2026-09-06 against the live backend: this endpoint answers a
        // spent quota with a 429 that has NO `Retry-After` header and puts the
        // duration in the BODY. `streamFailure` already reads that field for the
        // mid-stream form of the SAME condition, so reading only the header here
        // reported one quota as two different failures.
        let transport = FakeTokenTransport([
            .success(ChatGPTConnectorFixture.json(
                """
                {"error":{"type":"usage_limit_reached","message":"The usage limit has been reached",
                 "plan_type":"plus","resets_at":1788765639,"eligible_promo":null,"resets_in_seconds":52532}}
                """,
                statusCode: 429
            )),
        ])
        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: 52532)) {
            try await ChatGPTConnectorFixture.connector(transport: transport).listModels()
        }
    }

    @Test("An explicit Retry-After header still wins over the body's duration")
    func theRetryAfterHeaderOutranksTheBody() async throws {
        let transport = FakeTokenTransport([
            .success(HTTPResponse(
                statusCode: 429,
                headers: ["Retry-After": "30"],
                body: Data(#"{"error":{"type":"usage_limit_reached","resets_in_seconds":52532}}"#.utf8)
            )),
        ])
        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: 30)) {
            try await ChatGPTConnectorFixture.connector(transport: transport).listModels()
        }
    }

    @Test("A 429 that names no duration anywhere still reports nil rather than inventing one")
    func aDurationlessQuotaRefusalStaysNil() async throws {
        let transport = FakeTokenTransport([
            .success(ChatGPTConnectorFixture.json(#"{"error":"insufficient_quota"}"#, statusCode: 429)),
        ])
        await #expect(throws: ConnectorFailure.rateLimited(retryAfter: nil)) {
            try await ChatGPTConnectorFixture.connector(transport: transport).listModels()
        }
    }

    @Test("Any other status keeps the code and a truncated body, never the request")
    func otherStatusesKeepTheCodeAndBody() async throws {
        let transport = FakeTokenTransport([
            .success(ChatGPTConnectorFixture.json("{\"error\":\"upstream\"}", statusCode: 502)),
        ])
        await #expect(throws: ConnectorFailure.httpStatus(
            502,
            body: "{\"error\":\"upstream\"}",
            providerMessage: nil
        )) {
            try await ChatGPTConnectorFixture.connector(transport: transport).listModels()
        }
    }

    @Test("A transport failure propagates unchanged rather than collapsing into authExpired")
    func transportFailuresPropagateUnchanged() async throws {
        let expected = ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.networkUnavailable)
        let transport = FakeTokenTransport([.failure(expected)])
        await #expect(throws: expected) {
            try await ChatGPTConnectorFixture.connector(transport: transport).listModels()
        }
    }
}
