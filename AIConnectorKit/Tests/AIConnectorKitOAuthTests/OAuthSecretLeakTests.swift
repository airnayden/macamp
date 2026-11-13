// The leak proof. Every value that COULD carry credential material is rendered
// the way a careless caller would render it — `String(describing:)`, string
// interpolation, `localizedDescription`, `dump` — and checked against the exact
// placeholder secrets the fixtures used.
//
// The `test-token-` prefix is what makes this assertable: a real-looking
// placeholder could not be grepped for without also matching innocent text, and
// a leak would then pass unnoticed.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

@Suite("OAuthSecretLeakTests")
struct OAuthSecretLeakTests {
    /// Everything that must never appear in rendered output.
    private static let secrets = [
        OAuthFixture.accessToken,
        OAuthFixture.refreshToken,
        OAuthFixture.rotatedAccessToken,
        OAuthFixture.rotatedRefreshToken,
        OAuthFixture.authorizationCode,
        "test-token-",
    ]

    private func assertNoLeak(_ rendered: String, _ context: Comment) {
        for secret in Self.secrets {
            #expect(rendered.contains(secret) == false, context)
        }
    }

    /// Every case, listed by hand rather than derived: a new case added without a
    /// matching entry here should be a review question, and `CaseIterable` is not
    /// available on an enum with associated values.
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

    @Test("No OAuthFlowError renders any secret material")
    func flowErrorsAreSecretFree() {
        for error in Self.flowErrors {
            assertNoLeak(String(describing: error), "describing \(error)")
            assertNoLeak("\(error)", "interpolating \(error)")
            assertNoLeak(error.localizedDescription, "localizedDescription of \(error)")
            var dumped = ""
            dump(error, to: &dumped)
            assertNoLeak(dumped, "dump of \(error)")
        }
    }

    @Test("Every engine failure the OAuth path can raise is secret-free")
    func engineFailuresAreSecretFree() {
        let failures: [ConnectorFailure] = [.unconfigured, .authExpired, .timeout, .cancelled, .malformedResponse]
        for failure in failures {
            assertNoLeak(String(describing: failure), "describing \(failure)")
            assertNoLeak(failure.localizedDescription, "localizedDescription of \(failure)")
        }
    }

    @Test("Credentials redact both tokens under every rendering route")
    func credentialsRedactBothTokens() {
        let credentials = OAuthFixture.credentials()
        assertNoLeak(String(describing: credentials), "describing credentials")
        assertNoLeak("\(credentials)", "interpolating credentials")
        assertNoLeak(String(reflecting: credentials), "reflecting credentials")
        var dumped = ""
        dump(credentials, to: &dumped)
        assertNoLeak(dumped, "dump of credentials")

        // Still useful for diagnosis without the secrets.
        #expect(String(describing: credentials).contains("present"))
        #expect(String(describing: credentials).contains("max"))
    }

    @Test("An authorize request redacts the PKCE verifier and the state")
    func authorizeRequestRedactsItsSecrets() throws {
        let flow = ClaudeOAuthFlow(
            configuration: OAuthFixture.testConfiguration(),
            transport: FakeTokenTransport(),
            randomBytes: ScriptedRandomBytes([OAuthFixture.verifierEntropy, OAuthFixture.stateEntropy]).provider
        )
        let request = try flow.authorizeRequest()
        let rendered = String(describing: request) + String(reflecting: request)
        #expect(rendered.contains(request.codeVerifier) == false)
        #expect(rendered.contains(request.state) == false)
        #expect(rendered.contains("redacted"))
    }

    @Test("A refused exchange never echoes the authorization code or the verifier")
    func refusedExchangeNeverEchoesTheCode() async throws {
        // The fixture body deliberately ECHOES the code back, the way a real
        // OAuth error response does — the flow must still not carry it out.
        let echo = "{\"error\":\"invalid_grant\",\"code\":\"\(OAuthFixture.authorizationCode)\"}"
        let transport = FakeTokenTransport([.success(HTTPResponse(statusCode: 400, body: Data(echo.utf8)))])
        let flow = ClaudeOAuthFlow(
            configuration: OAuthFixture.testConfiguration(),
            transport: transport,
            randomBytes: ScriptedRandomBytes([OAuthFixture.verifierEntropy, OAuthFixture.stateEntropy]).provider
        )
        let request = try flow.authorizeRequest()

        do {
            _ = try await flow.exchange(
                code: OAuthFixture.authorizationCode,
                state: request.state,
                request: request
            )
            Issue.record("A 400 exchange must throw")
        } catch {
            assertNoLeak(String(describing: error), "describing the exchange failure")
            assertNoLeak(error.localizedDescription, "localizedDescription of the exchange failure")
            #expect(String(describing: error).contains(request.codeVerifier) == false)
        }
    }

    @Test("A failed refresh never echoes the refresh token")
    func failedRefreshNeverEchoesTheToken() async throws {
        let echo = "{\"error\":\"invalid_grant\",\"refresh_token\":\"\(OAuthFixture.refreshToken)\"}"
        let store = InMemorySecretStore()
        let transport = FakeTokenTransport([.success(HTTPResponse(statusCode: 400, body: Data(echo.utf8)))])
        let engine = OAuthCredentialEngine(
            store: store,
            configuration: OAuthFixture.testConfiguration(),
            transport: transport
        )
        try await engine.seed(OAuthFixture.credentials())

        do {
            _ = try await engine.forceRefresh()
            Issue.record("A 400 refresh must throw")
        } catch {
            assertNoLeak(String(describing: error), "describing the refresh failure")
            assertNoLeak(error.localizedDescription, "localizedDescription of the refresh failure")
        }
    }

    @Test("The decoded token response redacts its tokens too")
    func tokenResponseRedactsItsTokens() throws {
        let response = OAuthFixture.tokenResponse(
            accessToken: OAuthFixture.accessToken,
            refreshToken: OAuthFixture.refreshToken
        )
        let decoded = try OAuthTokenResponse.decode(response.body)
        assertNoLeak(String(describing: decoded), "describing the token response")
        #expect(decoded.accessToken == OAuthFixture.accessToken)
    }
}
