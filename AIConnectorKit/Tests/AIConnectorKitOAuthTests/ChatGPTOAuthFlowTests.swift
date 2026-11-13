// Hermetic proof of the ChatGPT/Codex PKCE grant. ZERO live network, ZERO real
// entropy, ZERO real clock — the same discipline as the Claude suites, and for
// the same reason: PKCE and rotation can only be asserted EXACTLY when every
// non-deterministic input is injected.
//
// Shared fixtures live in `ChatGPTOAuthTestSupport.swift`; the claim and engine
// suites live in `ChatGPTCredentialEngineTests.swift`.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import CryptoKit
import Foundation
import Testing

@Suite("ChatGPTOAuthConfigurationTests")
struct ChatGPTOAuthConfigurationTests {
    @Test("The researched ChatGPT default carries the constant set re-verified on 2026-08-24")
    func defaultConfigurationMatchesTheResearchedSet() {
        let configuration = OAuthEndpointConfiguration.chatGPTSubscription
        #expect(configuration.clientID == "app_EMoamEEZ73f0CkXaXp7hrann")
        #expect(configuration.authorizeURL.absoluteString == "https://auth.openai.com/oauth/authorize")
        #expect(configuration.tokenURL.absoluteString == "https://auth.openai.com/oauth/token")
        #expect(configuration.redirectURI == "http://localhost:1455/auth/callback")
        #expect(configuration.tokenBodyEncoding == .form)
        #expect(configuration.tokenRequestDeadline == 15)
    }

    @Test("The connector-invocation scopes ship, because omitting them yields 429 insufficient_quota")
    func connectorScopesAreShipped() {
        let scopes = OAuthEndpointConfiguration.chatGPTSubscription.scopes
        #expect(scopes == ["openid", "profile", "email", "offline_access",
                           "api.connectors.read", "api.connectors.invoke"])
    }

    @Test("The authorize extras match the endorsed client exactly")
    func authorizeExtrasMatchTheEndorsedFlow() {
        let configuration = OAuthEndpointConfiguration.chatGPTSubscription
        let extras = Dictionary(
            configuration.extraAuthorizeQueryItems.map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(extras["id_token_add_organizations"] == "true")
        #expect(extras["codex_cli_simplified_flow"] == "true")
        // `codex_cli_rs` selects the simplified consent screen the loopback
        // redirect is registered against. It was `macamp` until 2026-08-24, which
        // is precisely why the flow could not be completed then — see
        // `ChatGPTConnector.swift`'s determination header.
        #expect(extras["originator"] == OAuthEndpointConfiguration.chatGPTOriginator)
        #expect(extras["originator"] == "codex_cli_rs")
        // This token host does NOT fingerprint the agent, unlike Anthropic's.
        #expect(configuration.tokenRequestUserAgent == nil)
    }

    @Test("Only the two registered loopback ports exist, and both spell one redirect")
    func loopbackPortsAreTheRegisteredPair() {
        #expect(OAuthEndpointConfiguration.chatGPTPrimaryCallbackPort == 1455)
        #expect(OAuthEndpointConfiguration.chatGPTFallbackCallbackPort == 1457)
        #expect(
            OAuthEndpointConfiguration.chatGPTRedirectURI(port: 1455)
                == OAuthEndpointConfiguration.chatGPTSubscription.redirectURI
        )
        #expect(
            OAuthEndpointConfiguration.chatGPTRedirectURI(port: 1457)
                == "http://localhost:1457/auth/callback"
        )
    }

    @Test("Rebinding a flow to a port rewrites the redirect and nothing else")
    func reboundFlowChangesOnlyTheRedirect() {
        let original = ChatGPTOAuthFlow(configuration: ChatGPTFixture.testConfiguration())
        let rebound = original.boundToLoopback(port: 1457)

        #expect(rebound.configuration.redirectURI == "http://localhost:1457/auth/callback")
        #expect(rebound.configuration.clientID == original.configuration.clientID)
        #expect(rebound.configuration.scopes == original.configuration.scopes)
        #expect(rebound.configuration.authorizeURL == original.configuration.authorizeURL)
        #expect(rebound.configuration.extraAuthorizeQueryItems == original.configuration.extraAuthorizeQueryItems)
    }

    @Test("Claude's constants are provably absent from the ChatGPT default, and vice versa")
    func theTwoProviderDefaultsShareNothing() {
        let chatGPT = OAuthEndpointConfiguration.chatGPTSubscription
        let claude = OAuthEndpointConfiguration.claudeSubscription
        #expect(chatGPT.clientID != claude.clientID)
        #expect(chatGPT.authorizeURL != claude.authorizeURL)
        #expect(chatGPT.tokenURL != claude.tokenURL)
        // A ChatGPT authorize URL carrying Claude's `code=true` would mean the
        // wrong default leaked across; assert the shapes stay separate.
        #expect(chatGPT.extraAuthorizeQueryItems.contains { $0.name == "code" } == false)
    }
}

@Suite("ChatGPTOAuthFlowAuthorizeTests")
struct ChatGPTOAuthFlowAuthorizeTests {
    private func queryItems(_ url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    @Test("The authorize URL carries every OAuth parameter plus the configured extras")
    func authorizeURLCarriesEveryRequiredParameter() throws {
        let configuration = ChatGPTFixture.testConfiguration()
        let request = try ChatGPTFixture.flow(
            transport: FakeTokenTransport(),
            configuration: configuration
        ).authorizeRequest()
        let items = Dictionary(
            queryItems(request.url).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )

        #expect(items["client_id"] == configuration.clientID)
        #expect(items["response_type"] == "code")
        #expect(items["redirect_uri"] == "http://localhost:1455/auth/callback")
        #expect(items["scope"] == configuration.scopes.joined(separator: " "))
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == request.state)
        #expect(items["id_token_add_organizations"] == "true")
        #expect(items["codex_cli_simplified_flow"] == "true")
        #expect(items["originator"] == "codex_cli_rs")
        // All SIX scopes, in order. The four-scope string other clients ship
        // authenticates and then fails at USE time with 429 insufficient_quota.
        #expect(items["scope"] == "openid profile email offline_access "
            + "api.connectors.read api.connectors.invoke")
    }

    @Test("The configuration's extra query items lead the standard OAuth ones")
    func extraQueryItemsLeadTheStandardParameters() throws {
        let request = try ChatGPTFixture.flow(transport: FakeTokenTransport()).authorizeRequest()
        #expect(queryItems(request.url).first?.name == "id_token_add_organizations")
        #expect(queryItems(request.url).last?.name == "state")
    }

    @Test("code_challenge is the unpadded base64url SHA-256 of the verifier string")
    func codeChallengeIsTheS256DigestOfTheVerifier() throws {
        let request = try ChatGPTFixture.flow(transport: FakeTokenTransport()).authorizeRequest()

        // RFC 7636 §4.2 hashes the ASCII of the base64url VERIFIER STRING, not
        // the entropy behind it. Recomputed with an independent encoder.
        #expect(request.codeVerifier == expectedBase64URL(ChatGPTFixture.verifierEntropy))
        let digest = Data(SHA256.hash(data: Data(request.codeVerifier.utf8)))
        let challenge = queryItems(request.url).first { $0.name == "code_challenge" }?.value
        #expect(challenge == expectedBase64URL(digest))
        #expect(challenge?.contains("=") == false)
        #expect(challenge?.contains("+") == false)
        #expect(challenge?.contains("/") == false)
    }

    @Test("The verifier draws 64 bytes and the state draws an independent 32")
    func verifierAndStateDrawTheUpstreamEntropyBudget() throws {
        let entropy = ScriptedRandomBytes([ChatGPTFixture.verifierEntropy, ChatGPTFixture.stateEntropy])
        let flow = ChatGPTOAuthFlow(
            configuration: ChatGPTFixture.testConfiguration(),
            transport: FakeTokenTransport(),
            randomBytes: entropy.provider,
            now: TestClock().now
        )
        let request = try flow.authorizeRequest()

        // 64 is upstream's budget and differs from Claude's 32 — a copied
        // constant would show up right here.
        #expect(entropy.requestedCounts == [64, 32])
        #expect(request.codeVerifier.count == 86)
        #expect(request.state == expectedBase64URL(ChatGPTFixture.stateEntropy))
        let digest = Data(SHA256.hash(data: Data(request.codeVerifier.utf8)))
        #expect(request.state != expectedBase64URL(digest))
    }

    @Test("A real login draws unpredictable, distinct values on every attempt")
    func systemEntropyIsDistinctPerAttempt() throws {
        let flow = ChatGPTOAuthFlow(
            configuration: ChatGPTFixture.testConfiguration(),
            transport: FakeTokenTransport()
        )
        let first = try flow.authorizeRequest()
        let second = try flow.authorizeRequest()
        #expect(first.codeVerifier != second.codeVerifier)
        #expect(first.state != second.state)
        #expect(first.state.count == 43)
    }
}

@Suite("ChatGPTOAuthFlowExchangeTests")
struct ChatGPTOAuthFlowExchangeTests {
    @Test("A loopback callback URL is split into code and state")
    func loopbackCallbackURLIsParsed() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTFixture.tokenResponse())])
        let flow = ChatGPTFixture.flow(transport: transport)
        let request = try flow.authorizeRequest()
        let callback = try #require(URL(
            string: "http://localhost:1455/auth/callback"
                + "?code=\(ChatGPTFixture.authorizationCode)&state=\(request.state)"
        ))

        let session = try await flow.exchange(callbackURL: callback, request: request)
        #expect(session.credentials.accessToken == ChatGPTFixture.accessToken)
        let body = try #require(await transport.recordedBody(0))
        #expect(body.contains("code=\(ChatGPTFixture.authorizationCode)"))
    }

    @Test("A callback carrying an error is refused before any network call")
    func errorCallbackIsRefusedWithoutTouchingTheNetwork() async throws {
        let transport = FakeTokenTransport()
        let flow = ChatGPTFixture.flow(transport: transport)
        let request = try flow.authorizeRequest()
        let callback = try #require(URL(
            string: "http://localhost:1455/auth/callback?error=access_denied&state=\(request.state)"
        ))

        await #expect(throws: OAuthFlowError.malformedCallbackValue) {
            try await flow.exchange(callbackURL: callback, request: request)
        }
        #expect(await transport.recordedRequests.isEmpty)
    }

    @Test("A callback whose state does not match is rejected before any network call")
    func stateMismatchIsRejectedWithoutTouchingTheNetwork() async throws {
        let transport = FakeTokenTransport()
        let flow = ChatGPTFixture.flow(transport: transport)
        let request = try flow.authorizeRequest()

        await #expect(throws: OAuthFlowError.stateMismatch) {
            try await flow.exchange(
                code: ChatGPTFixture.authorizationCode,
                state: "test-token-chatgpt-foreign-state",
                request: request
            )
        }
        let count = await transport.recordedRequests.count
        #expect(count == 0, "A code arriving with a foreign state must never be redeemed")
    }

    @Test("A callback missing code or state is rejected")
    func malformedCallbackIsRejected() async throws {
        let flow = ChatGPTFixture.flow(transport: FakeTokenTransport())
        let request = try flow.authorizeRequest()
        let bases = [
            "http://localhost:1455/auth/callback?state=\(request.state)",
            "http://localhost:1455/auth/callback?code=\(ChatGPTFixture.authorizationCode)",
            "http://localhost:1455/auth/callback",
        ]
        for base in bases {
            let callback = try #require(URL(string: base))
            await #expect(throws: OAuthFlowError.malformedCallbackValue) {
                try await flow.exchange(callbackURL: callback, request: request)
            }
        }
        await #expect(throws: OAuthFlowError.malformedCallbackValue) {
            try await flow.exchange(code: "  ", state: request.state, request: request)
        }
    }

    @Test("The exchange POSTs a form-urlencoded body with no state field")
    func exchangeBuildsTheObservedFormBody() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTFixture.tokenResponse())])
        let flow = ChatGPTFixture.flow(transport: transport)
        let request = try flow.authorizeRequest()
        _ = try await flow.exchange(
            code: ChatGPTFixture.authorizationCode,
            state: request.state,
            request: request
        )

        let body = try #require(await transport.recordedBody(0))
        #expect(body.hasPrefix("grant_type=authorization_code&"))
        #expect(body.contains("code=\(ChatGPTFixture.authorizationCode)"))
        #expect(body.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
        #expect(body.contains("code_verifier=\(request.codeVerifier)"))
        // Percent-encoded because `:` and `/` are not in the allowed set.
        #expect(body.contains("redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"))
        // Upstream does not echo `state` on the exchange, and neither does this.
        #expect(body.contains("state=") == false)
        #expect(await transport.recordedHeader("Content-Type", at: 0) == "application/x-www-form-urlencoded")
        // No forged Codex user agent.
        #expect(await transport.recordedHeader("User-Agent", at: 0) == nil)
    }

    @Test("A successful exchange yields a credential plus the id_token identity")
    func exchangeYieldsCredentialsAndIdentity() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTFixture.tokenResponse())])
        let flow = ChatGPTFixture.flow(transport: transport)
        let request = try flow.authorizeRequest()
        let session = try await flow.exchange(
            code: ChatGPTFixture.authorizationCode,
            state: request.state,
            request: request
        )

        #expect(session.credentials.accessToken == ChatGPTFixture.accessToken)
        #expect(session.credentials.refreshToken == ChatGPTFixture.refreshToken)
        #expect(session.credentials.subscriptionType == "pro")
        #expect(session.credentials.scopes == flow.configuration.scopes)
        #expect(session.accountID == ChatGPTFixture.accountID)
    }

    @Test("Expiry comes from the access token's exp claim, because the response carries no expires_in")
    func expiryIsReadFromTheAccessTokenClaim() async throws {
        let jwt = ChatGPTFixture.identityToken(expiresAt: ChatGPTFixture.epoch.addingTimeInterval(900))
        let transport = FakeTokenTransport([
            .success(ChatGPTFixture.tokenResponse(accessToken: jwt, identityToken: jwt)),
        ])
        let flow = ChatGPTFixture.flow(transport: transport)
        let request = try flow.authorizeRequest()
        let session = try await flow.exchange(
            code: ChatGPTFixture.authorizationCode,
            state: request.state,
            request: request
        )

        #expect(session.credentials.expiresAt == ChatGPTFixture.epoch.addingTimeInterval(900))
    }

    @Test("An opaque access token falls back to the configured default lifetime")
    func opaqueTokenFallsBackToTheConfiguredLifetime() async throws {
        let transport = FakeTokenTransport([
            .success(ChatGPTFixture.tokenResponse(identityToken: nil)),
        ])
        let clock = TestClock()
        let flow = ChatGPTFixture.flow(transport: transport, clock: clock)
        let request = try flow.authorizeRequest()
        let session = try await flow.exchange(
            code: ChatGPTFixture.authorizationCode,
            state: request.state,
            request: request
        )

        #expect(session.credentials.expiresAt == ChatGPTFixture.epoch.addingTimeInterval(28800))
        #expect(session.accountID == nil)
        #expect(session.credentials.subscriptionType == nil)
    }

    @Test("An exchange with no refresh token is refused rather than seeded")
    func exchangeWithoutARefreshTokenIsRejected() async throws {
        let transport = FakeTokenTransport([.success(ChatGPTFixture.tokenResponse(refreshToken: nil))])
        let flow = ChatGPTFixture.flow(transport: transport)
        let request = try flow.authorizeRequest()
        await #expect(throws: OAuthFlowError.tokenResponseMissingRefreshToken) {
            try await flow.exchange(
                code: ChatGPTFixture.authorizationCode,
                state: request.state,
                request: request
            )
        }
    }

    @Test("A refused exchange reports the status and nothing more")
    func refusedExchangeReportsOnlyTheStatus() async throws {
        let transport = FakeTokenTransport([
            .success(HTTPResponse(statusCode: 400, body: Data("{\"error\":\"invalid_grant\"}".utf8))),
        ])
        let flow = ChatGPTFixture.flow(transport: transport)
        let request = try flow.authorizeRequest()
        await #expect(throws: OAuthFlowError.tokenEndpointRejected(status: 400)) {
            try await flow.exchange(
                code: ChatGPTFixture.authorizationCode,
                state: request.state,
                request: request
            )
        }
    }

    @Test("A 2xx body that is not a token response is unreadable, not silently empty")
    func unreadableResponseIsRejected() async throws {
        let transport = FakeTokenTransport([
            .success(HTTPResponse(statusCode: 200, body: Data("<html>challenge</html>".utf8))),
            .success(HTTPResponse(statusCode: 200, body: Data("{\"token_type\":\"Bearer\"}".utf8))),
        ])
        let flow = ChatGPTFixture.flow(transport: transport)
        let request = try flow.authorizeRequest()
        await #expect(throws: OAuthFlowError.tokenResponseUnreadable) {
            try await flow.exchange(
                code: ChatGPTFixture.authorizationCode,
                state: request.state,
                request: request
            )
        }
        await #expect(throws: OAuthFlowError.tokenResponseMissingAccessToken) {
            try await flow.exchange(
                code: ChatGPTFixture.authorizationCode,
                state: request.state,
                request: request
            )
        }
    }

    @Test("The exchange is bounded by the configured deadline")
    func exchangeIsBoundedByTheConfiguredDeadline() async throws {
        let transport = FakeTokenTransport([.neverRespond])
        let flow = ChatGPTFixture.flow(
            transport: transport,
            configuration: ChatGPTFixture.testConfiguration(deadline: 0.2)
        )
        let request = try flow.authorizeRequest()
        await #expect(throws: ConnectorFailure.timeout) {
            try await flow.exchange(
                code: ChatGPTFixture.authorizationCode,
                state: request.state,
                request: request
            )
        }
    }
}
