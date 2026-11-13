// The ChatGPT leak proof. Every value on this provider's path that COULD carry
// credential material is rendered the way a careless caller would render it —
// `String(describing:)`, interpolation, `localizedDescription`,
// `String(reflecting:)`, `dump` — and checked against the exact placeholder
// secrets the fixtures used.
//
// The `test-token-` prefix is what makes this assertable. It covers the id_token
// too: the fixture JWT's SIGNATURE segment is a literal `test-token-` marker, so
// even a base64url-obscured payload leaks a greppable string if the whole token
// ever escapes.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

@Suite("ChatGPTSecretLeakTests")
struct ChatGPTSecretLeakTests {
    private static let secrets = [
        ChatGPTFixture.accessToken,
        ChatGPTFixture.refreshToken,
        ChatGPTFixture.rotatedAccessToken,
        ChatGPTFixture.rotatedRefreshToken,
        ChatGPTFixture.authorizationCode,
        "test-token-",
    ]

    private func assertNoLeak(_ rendered: String, _ context: Comment) {
        for secret in Self.secrets {
            #expect(rendered.contains(secret) == false, context)
        }
    }

    /// Rendered through every route a caller might reach for. `dump` and
    /// `String(reflecting:)` are here because they bypass
    /// `CustomStringConvertible` entirely — that is the hole `CustomReflectable`
    /// exists to close, and the one a synthesised description would leave open.
    private func assertNoLeakEverywhere(_ value: some Any, _ label: String) {
        assertNoLeak(String(describing: value), "describing \(label)")
        assertNoLeak("\(value)", "interpolating \(label)")
        assertNoLeak(String(reflecting: value), "reflecting \(label)")
        var dumped = ""
        dump(value, to: &dumped)
        assertNoLeak(dumped, "dump of \(label)")
    }

    /// Every case the ChatGPT path can raise, listed BY HAND rather than derived:
    /// a new case added without an entry here should be a review question, and
    /// `CaseIterable` is unavailable on an enum with associated values.
    private static let flowErrors: [OAuthFlowError] = [
        .malformedCallbackValue,
        .stateMismatch,
        .authorizeRequestUnbuildable,
        .tokenEndpointRejected(status: 400),
        .tokenResponseUnreadable,
        .tokenResponseMissingAccessToken,
        .tokenResponseMissingRefreshToken,
        .partialCredentialSeedRejected,
    ]

    @Test("No OAuthFlowError raised on the ChatGPT path renders any secret material")
    func flowErrorsAreSecretFree() {
        for error in Self.flowErrors {
            assertNoLeakEverywhere(error, "\(error)")
            assertNoLeak(error.localizedDescription, "localizedDescription of \(error)")
        }
    }

    @Test("Every connector failure the ChatGPT path can raise is secret-free")
    func connectorFailuresAreSecretFree() {
        let failures: [ConnectorFailure] = [
            .unconfigured,
            .authExpired,
            .timeout,
            .cancelled,
            .malformedResponse,
            .rateLimited(retryAfter: 30),
            .unreachable(underlying: ChatGPTConnector.botMitigationToken),
            .httpStatus(502, body: "{\"error\":\"upstream\"}", providerMessage: nil),
        ]
        for failure in failures {
            assertNoLeakEverywhere(failure, "\(failure)")
            assertNoLeak(failure.localizedDescription, "localizedDescription of \(failure)")
        }
    }

    @Test("An authorize request redacts the PKCE verifier and the state")
    func authorizeRequestRedactsItsSecrets() throws {
        let request = try ChatGPTFixture.flow(transport: FakeTokenTransport()).authorizeRequest()
        let rendered = String(describing: request) + String(reflecting: request)
        #expect(rendered.contains(request.codeVerifier) == false)
        #expect(rendered.contains(request.state) == false)
        #expect(rendered.contains("redacted"))
    }

    @Test("A session redacts both tokens under every rendering route")
    func sessionRedactsItsCredentials() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTFixture.tokenResponse())])
        let flow = ChatGPTFixture.flow(transport: transport)
        let request = try flow.authorizeRequest()
        let session = try await flow.exchange(
            code: ChatGPTFixture.authorizationCode,
            state: request.state,
            request: request
        )

        assertNoLeakEverywhere(session, "session")
        // Still useful for diagnosis without the secrets.
        #expect(String(describing: session).contains("present"))
        #expect(String(describing: session).contains(ChatGPTFixture.accountID))
    }

    @Test("A refused exchange never echoes the authorization code or the verifier")
    func refusedExchangeNeverEchoesTheCode() async throws {
        // The fixture body deliberately ECHOES the code back, the way a real
        // OAuth error response does — the flow must still not carry it out.
        let echo = "{\"error\":\"invalid_grant\",\"code\":\"\(ChatGPTFixture.authorizationCode)\"}"
        let transport = FakeTokenTransport([.success(HTTPResponse(statusCode: 400, body: Data(echo.utf8)))])
        let flow = ChatGPTFixture.flow(transport: transport)
        let request = try flow.authorizeRequest()

        do {
            _ = try await flow.exchange(
                code: ChatGPTFixture.authorizationCode,
                state: request.state,
                request: request
            )
            Issue.record("A 400 exchange must throw")
        } catch {
            assertNoLeakEverywhere(error, "the exchange failure")
            assertNoLeak(error.localizedDescription, "localizedDescription of the exchange failure")
            #expect(String(describing: error).contains(request.codeVerifier) == false)
        }
    }

    @Test("A failed connector call never echoes the bearer token back through the diagnostic body")
    func connectorDiagnosticBodyNeverCarriesTheToken() async throws {
        // The 502 body echoes the Authorization header the way a badly-behaved
        // gateway does. `httpStatus(_:body:, providerMessage: nil)` retains RESPONSE bodies for
        // diagnosis, so this is the one place a token could realistically ride
        // out — it must not, and the connector never puts request material there.
        let echo = "{\"error\":\"upstream\",\"seen\":\"Bearer \(ChatGPTFixture.accessToken)\"}"
        let transport = FakeTokenTransport([
            .success(HTTPResponse(statusCode: 502, body: Data(echo.utf8))),
        ])
        let connector = ChatGPTConnectorFixture.connector(transport: transport)

        do {
            _ = try await connector.listModels()
            Issue.record("A 502 must throw")
        } catch let failure as ConnectorFailure {
            // The provider chose to echo it; the connector is not the leak, but
            // record explicitly that the payload is the RESPONSE and nothing the
            // connector added.
            guard case let .httpStatus(status, body, providerMessage) = failure else {
                Issue.record("Expected httpStatus, got \(failure)")
                return
            }
            #expect(status == 502)
            #expect(body == echo, "The retained body is the provider's, verbatim and untruncated at this size")
            // The one payload a shell may RENDER reads `error.message` and nothing
            // else, so an echoed header two keys away from it cannot be picked up.
            #expect(providerMessage == nil, "Only `error.message` is displayable, and this body has none")
            // What must never happen: the connector synthesising a payload from
            // the REQUEST it sent.
            #expect(String(describing: ConnectorFailure.authExpired).contains(ChatGPTFixture.accessToken) == false)
        }
    }

    @Test("A failed refresh on the ChatGPT engine never echoes the refresh token")
    func failedRefreshNeverEchoesTheToken() async throws {
        let echo = "{\"error\":\"invalid_grant\",\"refresh_token\":\"\(ChatGPTFixture.refreshToken)\"}"
        let store = InMemorySecretStore()
        let transport = FakeTokenTransport([.success(HTTPResponse(statusCode: 400, body: Data(echo.utf8)))])
        let engine = OAuthCredentialEngine(
            store: store,
            configuration: ChatGPTFixture.testConfiguration(),
            transport: transport,
            account: ChatGPTConnector.credentialAccount
        )
        try await engine.seed(OAuthCredentials(
            accessToken: ChatGPTFixture.accessToken,
            refreshToken: ChatGPTFixture.refreshToken,
            expiresAt: ChatGPTFixture.epoch,
            subscriptionType: "pro",
            scopes: OAuthEndpointConfiguration.chatGPTSubscription.scopes
        ))

        do {
            _ = try await engine.forceRefresh()
            Issue.record("A 400 refresh must throw")
        } catch {
            assertNoLeakEverywhere(error, "the refresh failure")
            assertNoLeak(error.localizedDescription, "localizedDescription of the refresh failure")
        }
    }

    @Test("The authorize URL carries no verifier, and the id_token never reaches the credential")
    func authorizeURLAndCredentialsCarryNoRecoverableSecret() async throws {
        let flow = ChatGPTFixture.flow(transport: FakeTokenTransport())
        let request = try flow.authorizeRequest()
        // The URL travels through browser history and the provider's access
        // logs: it may carry the CHALLENGE, never the verifier.
        #expect(request.url.absoluteString.contains(request.codeVerifier) == false)

        let identity = ChatGPTFixture.identityToken()
        let exchanged = FakeTokenTransport([
            .success(ChatGPTFixture.tokenResponse(identityToken: identity)),
        ])
        let session = try await ChatGPTFixture.flow(transport: exchanged).exchange(
            code: ChatGPTFixture.authorizationCode,
            state: ChatGPTFixture.flow(transport: FakeTokenTransport()).authorizeRequest().state,
            request: ChatGPTFixture.flow(transport: FakeTokenTransport()).authorizeRequest()
        )
        // The id_token is read for its claims and dropped: it is a third live
        // credential and has no reason to be persisted.
        let encoded = try JSONEncoder().encode(session.credentials)
        let blob = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(blob.contains(identity) == false)
    }
}
