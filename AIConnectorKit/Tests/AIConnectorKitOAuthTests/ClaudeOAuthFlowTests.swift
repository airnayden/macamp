import AIConnectorKit
@testable import AIConnectorKitOAuth
import CryptoKit
import Foundation
import Testing

@Suite("ClaudeOAuthConfigurationTests")
struct ClaudeOAuthConfigurationTests {
    @Test("The researched Claude default carries the constant set verified on 2026-08-21")
    func defaultConfigurationMatchesTheResearchedSet() {
        let configuration = OAuthEndpointConfiguration.claudeSubscription
        #expect(configuration.clientID == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(configuration.authorizeURL.absoluteString == "https://claude.ai/oauth/authorize")
        #expect(configuration.tokenURL.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(configuration.redirectURI == "https://platform.claude.com/oauth/code/callback")
        #expect(configuration.extraAuthorizeQueryItems == [URLQueryItem(name: "code", value: "true")])
        #expect(configuration.tokenBodyEncoding == .json)
        #expect(configuration.scopes.contains("user:inference"))
        #expect(configuration.scopes.count == 6)
    }

    @Test("Every stale host the plan proposed is provably absent from the shipped default")
    func staleHostsAreNotShipped() {
        let configuration = OAuthEndpointConfiguration.claudeSubscription
        let hosts = [
            configuration.authorizeURL.absoluteString,
            configuration.tokenURL.absoluteString,
            configuration.redirectURI,
        ].joined(separator: " ")
        // `console.anthropic.com` was renamed; `api.anthropic.com` serves the
        // Messages API and returns 400/401 for an OAuth grant; `claude.com/cai`
        // now fails post-redirect validation. All three are recorded in the
        // evidence file as known-failing.
        #expect(hosts.contains("console.anthropic.com") == false)
        #expect(hosts.contains("api.anthropic.com") == false)
        #expect(hosts.contains("claude.com/cai") == false)
    }

    @Test("The token-exchange deadline is capped at 15 seconds")
    func exchangeDeadlineIsFifteenSeconds() {
        #expect(OAuthEndpointConfiguration.claudeSubscription.tokenRequestDeadline == 15)
    }
}

@Suite("ClaudeOAuthFlowAuthorizeTests")
struct ClaudeOAuthFlowAuthorizeTests {
    private func makeFlow(
        configuration: OAuthEndpointConfiguration = OAuthFixture.testConfiguration(),
        entropy: ScriptedRandomBytes
    ) -> ClaudeOAuthFlow {
        ClaudeOAuthFlow(
            configuration: configuration,
            transport: FakeTokenTransport(),
            randomBytes: entropy.provider,
            now: TestClock().now
        )
    }

    private func queryItems(_ url: URL) -> [URLQueryItem] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    @Test("The authorize URL carries every OAuth parameter plus the configured extras")
    func authorizeURLCarriesEveryRequiredParameter() throws {
        var configuration = OAuthFixture.testConfiguration()
        configuration.extraAuthorizeQueryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "fixture_extra", value: "present"),
        ]
        let entropy = ScriptedRandomBytes([OAuthFixture.verifierEntropy, OAuthFixture.stateEntropy])
        let request = try makeFlow(configuration: configuration, entropy: entropy).authorizeRequest()
        let items = Dictionary(
            queryItems(request.url).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )

        #expect(items["client_id"] == configuration.clientID)
        #expect(items["response_type"] == "code")
        #expect(items["redirect_uri"] == configuration.redirectURI)
        #expect(items["scope"] == configuration.scopes.joined(separator: " "))
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == request.state)
        #expect(items["code"] == "true")
        #expect(items["fixture_extra"] == "present")
        #expect(items["code_challenge"]?.isEmpty == false)
    }

    @Test("The configuration's extra query items lead the standard OAuth ones")
    func extraQueryItemsLeadTheStandardParameters() throws {
        let entropy = ScriptedRandomBytes([OAuthFixture.verifierEntropy, OAuthFixture.stateEntropy])
        let request = try makeFlow(entropy: entropy).authorizeRequest()
        #expect(queryItems(request.url).first?.name == "code")
        #expect(queryItems(request.url).last?.name == "state")
    }

    @Test("code_challenge is the unpadded base64url SHA-256 of the verifier string")
    func codeChallengeIsTheS256DigestOfTheVerifier() throws {
        let entropy = ScriptedRandomBytes([OAuthFixture.verifierEntropy, OAuthFixture.stateEntropy])
        let request = try makeFlow(entropy: entropy).authorizeRequest()

        // Recomputed here with an independent encoder: RFC 7636 §4.2 hashes the
        // ASCII of the base64url VERIFIER STRING, not the entropy behind it.
        #expect(request.codeVerifier == expectedBase64URL(OAuthFixture.verifierEntropy))
        let digest = Data(SHA256.hash(data: Data(request.codeVerifier.utf8)))
        let challenge = queryItems(request.url).first { $0.name == "code_challenge" }?.value
        #expect(challenge == expectedBase64URL(digest))
        #expect(challenge?.contains("=") == false)
        #expect(challenge?.contains("+") == false)
        #expect(challenge?.contains("/") == false)
    }

    @Test("Verifier and state each draw 32 independent bytes")
    func verifierAndStateDrawIndependentEntropy() throws {
        let entropy = ScriptedRandomBytes([OAuthFixture.verifierEntropy, OAuthFixture.stateEntropy])
        let request = try makeFlow(entropy: entropy).authorizeRequest()

        #expect(entropy.requestedCounts == [32, 32])
        #expect(request.state == expectedBase64URL(OAuthFixture.stateEntropy))
        #expect(request.state != request.codeVerifier)
        // The state must not be any transform of the verifier a naive
        // implementation would reach for.
        let digest = Data(SHA256.hash(data: Data(request.codeVerifier.utf8)))
        #expect(request.state != expectedBase64URL(digest))
    }

    @Test("A real login draws unpredictable, distinct values on every attempt")
    func systemEntropyIsDistinctPerAttempt() throws {
        let flow = ClaudeOAuthFlow(configuration: OAuthFixture.testConfiguration(), transport: FakeTokenTransport())
        let first = try flow.authorizeRequest()
        let second = try flow.authorizeRequest()
        #expect(first.codeVerifier != second.codeVerifier)
        #expect(first.state != second.state)
        #expect(first.codeVerifier.count == 43)
        #expect(first.state.count == 43)
    }
}

@Suite("ClaudeOAuthFlowExchangeTests")
struct ClaudeOAuthFlowExchangeTests {
    private func makeFlow(
        transport: FakeTokenTransport,
        configuration: OAuthEndpointConfiguration = OAuthFixture.testConfiguration()
    ) -> ClaudeOAuthFlow {
        ClaudeOAuthFlow(
            configuration: configuration,
            transport: transport,
            randomBytes: ScriptedRandomBytes([OAuthFixture.verifierEntropy, OAuthFixture.stateEntropy]).provider,
            now: TestClock().now
        )
    }

    @Test("A callback whose state does not match is rejected before any network call")
    func stateMismatchIsRejectedWithoutTouchingTheNetwork() async throws {
        let transport = FakeTokenTransport()
        let flow = makeFlow(transport: transport)
        let request = try flow.authorizeRequest()

        await #expect(throws: OAuthFlowError.stateMismatch) {
            try await flow.exchange(
                pastedValue: "\(OAuthFixture.authorizationCode)#test-token-foreign-state",
                request: request
            )
        }
        let count = await transport.recordedRequests.count
        #expect(count == 0, "A code arriving with a foreign state must never be redeemed")
    }

    @Test("A paste that is not code#state is rejected")
    func malformedPasteIsRejected() async throws {
        let flow = makeFlow(transport: FakeTokenTransport())
        let request = try flow.authorizeRequest()
        for pasted in ["", "no-separator-here", "#\(request.state)", "\(OAuthFixture.authorizationCode)#"] {
            await #expect(throws: OAuthFlowError.malformedCallbackValue) {
                try await flow.exchange(pastedValue: pasted, request: request)
            }
        }
    }

    @Test("The exchange POSTs the configured JSON body with the fingerprinted user agent")
    func exchangeBuildsTheConfiguredJSONBody() async throws {
        let transport = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(
                accessToken: OAuthFixture.accessToken,
                refreshToken: OAuthFixture.refreshToken
            )),
        ])
        let flow = makeFlow(transport: transport)
        let request = try flow.authorizeRequest()
        _ = try await flow.exchange(
            pastedValue: "\(OAuthFixture.authorizationCode)#\(request.state)",
            request: request
        )

        let body = try #require(await transport.recordedBody(0))
        #expect(body.contains("\"grant_type\":\"authorization_code\""))
        #expect(body.contains("\"code\":\"\(OAuthFixture.authorizationCode)\""))
        #expect(body.contains("\"code_verifier\":\"\(request.codeVerifier)\""))
        #expect(body.contains("\"state\":\"\(request.state)\""))
        #expect(body.contains("\"client_id\":\"\(flow.configuration.clientID)\""))
        #expect(await transport.recordedHeader("Content-Type", at: 0) == "application/json")
        #expect(await transport.recordedHeader("User-Agent", at: 0) == "axios/1.13.6")
    }

    @Test("Switching the configured encoding to form changes the body, not the flow")
    func exchangeHonoursFormEncoding() async throws {
        let transport = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(
                accessToken: OAuthFixture.accessToken,
                refreshToken: OAuthFixture.refreshToken
            )),
        ])
        let flow = makeFlow(transport: transport, configuration: OAuthFixture.testConfiguration(bodyEncoding: .form))
        let request = try flow.authorizeRequest()
        _ = try await flow.exchange(
            pastedValue: "\(OAuthFixture.authorizationCode)#\(request.state)",
            request: request
        )

        let body = try #require(await transport.recordedBody(0))
        #expect(body.hasPrefix("grant_type=authorization_code&"))
        #expect(body.contains("code_verifier=\(request.codeVerifier)"))
        #expect(await transport.recordedHeader("Content-Type", at: 0) == "application/x-www-form-urlencoded")
    }

    @Test("A successful exchange yields a complete credential blob")
    func exchangeYieldsAFullCredentialBlob() async throws {
        let transport = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(
                accessToken: OAuthFixture.accessToken,
                refreshToken: OAuthFixture.refreshToken,
                expiresIn: 28800,
                subscriptionType: "max"
            )),
        ])
        let clock = TestClock()
        let flow = ClaudeOAuthFlow(
            configuration: OAuthFixture.testConfiguration(),
            transport: transport,
            randomBytes: ScriptedRandomBytes([OAuthFixture.verifierEntropy, OAuthFixture.stateEntropy]).provider,
            now: clock.now
        )
        let request = try flow.authorizeRequest()
        let credentials = try await flow.exchange(
            code: OAuthFixture.authorizationCode,
            state: request.state,
            request: request
        )

        #expect(credentials.accessToken == OAuthFixture.accessToken)
        #expect(credentials.refreshToken == OAuthFixture.refreshToken)
        #expect(credentials.expiresAt == OAuthFixture.epoch.addingTimeInterval(28800))
        #expect(credentials.subscriptionType == "max")
        #expect(credentials.scopes == flow.configuration.scopes)
    }

    @Test("An exchange with no refresh token is refused rather than seeded")
    func exchangeWithoutARefreshTokenIsRejected() async throws {
        let transport = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(accessToken: OAuthFixture.accessToken, refreshToken: nil)),
        ])
        let flow = makeFlow(transport: transport)
        let request = try flow.authorizeRequest()
        await #expect(throws: OAuthFlowError.tokenResponseMissingRefreshToken) {
            try await flow.exchange(code: OAuthFixture.authorizationCode, state: request.state, request: request)
        }
    }

    @Test("A refused exchange reports the status and nothing more")
    func refusedExchangeReportsOnlyTheStatus() async throws {
        let transport = FakeTokenTransport([
            .success(HTTPResponse(statusCode: 400, body: Data("{\"error\":\"invalid_grant\"}".utf8))),
        ])
        let flow = makeFlow(transport: transport)
        let request = try flow.authorizeRequest()
        await #expect(throws: OAuthFlowError.tokenEndpointRejected(status: 400)) {
            try await flow.exchange(code: OAuthFixture.authorizationCode, state: request.state, request: request)
        }
    }

    @Test("A 2xx body that is not a token response is unreadable, not silently empty")
    func unreadableResponseIsRejected() async throws {
        let transport = FakeTokenTransport([
            .success(HTTPResponse(statusCode: 200, body: Data("<html>not json</html>".utf8))),
            .success(HTTPResponse(statusCode: 200, body: Data("{\"token_type\":\"Bearer\"}".utf8))),
        ])
        let flow = makeFlow(transport: transport)
        let request = try flow.authorizeRequest()
        await #expect(throws: OAuthFlowError.tokenResponseUnreadable) {
            try await flow.exchange(code: OAuthFixture.authorizationCode, state: request.state, request: request)
        }
        await #expect(throws: OAuthFlowError.tokenResponseMissingAccessToken) {
            try await flow.exchange(code: OAuthFixture.authorizationCode, state: request.state, request: request)
        }
    }

    @Test("The exchange is bounded by the configured deadline")
    func exchangeIsBoundedByTheConfiguredDeadline() async throws {
        let transport = FakeTokenTransport([.neverRespond])
        let flow = makeFlow(
            transport: transport,
            configuration: OAuthFixture.testConfiguration(deadline: 0.2)
        )
        let request = try flow.authorizeRequest()
        await #expect(throws: ConnectorFailure.timeout) {
            try await flow.exchange(code: OAuthFixture.authorizationCode, state: request.state, request: request)
        }
    }
}
