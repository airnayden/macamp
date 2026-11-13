// The claim-extraction and credential-engine halves of the ChatGPT suite, split
// from `ChatGPTOAuthFlowTests.swift` to stay under SwiftLint's 400-line
// `file_length` ceiling (CI runs `--strict`).
//
// The engine under test here is todo 17's, UNMODIFIED — only the configuration
// and the account slot differ. Re-implementing rotation for a second provider is
// exactly what its provider-agnostic design exists to prevent, so these tests
// assert the REUSE rather than a ChatGPT-specific copy.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

@Suite("ChatGPTIdentityClaimTests")
struct ChatGPTIdentityClaimTests {
    @Test("The namespaced claims are read out of a well-formed JWT")
    func namespacedClaimsAreRead() {
        let token = ChatGPTFixture.identityToken()
        #expect(ChatGPTOAuthFlow.accountIdentifier(inJWT: token) == ChatGPTFixture.accountID)
        #expect(ChatGPTOAuthFlow.planType(inJWT: token) == "pro")
        #expect(ChatGPTOAuthFlow.expiry(inJWT: token) == ChatGPTFixture.epoch.addingTimeInterval(3600))
    }

    @Test("An opaque or malformed token yields nil rather than throwing")
    func opaqueTokensYieldNil() {
        // An opaque credential is a NORMAL outcome, not an error: the header is
        // omitted and the backend decides. Each of these is a distinct way the
        // parse can fail — wrong segment count, non-base64 payload, valid
        // base64 that is not a JSON object, and an empty string.
        for token in ["", ChatGPTFixture.accessToken, "a.b", "a.!!!.c", "a.\(expectedBase64URL(Data("[]".utf8))).c"] {
            #expect(ChatGPTOAuthFlow.accountIdentifier(inJWT: token) == nil)
            #expect(ChatGPTOAuthFlow.planType(inJWT: token) == nil)
            #expect(ChatGPTOAuthFlow.expiry(inJWT: token) == nil)
        }
    }

    @Test("A JWT whose namespace is present but missing the claim yields nil")
    func partialClaimsYieldNil() {
        let token = ChatGPTFixture.identityToken(accountID: nil, planType: "plus")
        #expect(ChatGPTOAuthFlow.accountIdentifier(inJWT: token) == nil)
        #expect(ChatGPTOAuthFlow.planType(inJWT: token) == "plus")
    }
}

@Suite("ChatGPTCredentialEngineReuseTests")
struct ChatGPTCredentialEngineReuseTests {
    private func makeEngine(
        store: InMemorySecretStore,
        transport: FakeTokenTransport,
        clock: TestClock
    ) -> OAuthCredentialEngine {
        // Todo 17's engine, UNMODIFIED — only the configuration and the account
        // slot differ. Re-implementing rotation for a second provider is exactly
        // what its provider-agnostic design exists to prevent.
        OAuthCredentialEngine(
            store: store,
            configuration: ChatGPTFixture.testConfiguration(),
            transport: transport,
            account: ChatGPTConnector.credentialAccount,
            now: clock.now
        )
    }

    private func credentials() -> OAuthCredentials {
        OAuthCredentials(
            accessToken: ChatGPTFixture.accessToken,
            refreshToken: ChatGPTFixture.refreshToken,
            expiresAt: ChatGPTFixture.epoch.addingTimeInterval(3600),
            subscriptionType: "pro",
            scopes: OAuthEndpointConfiguration.chatGPTSubscription.scopes
        )
    }

    @Test("The ChatGPT credential lands in its own account slot, not Claude's")
    func credentialsAreStoredUnderTheChatGPTAccount() async throws {
        let store = InMemorySecretStore()
        let engine = makeEngine(store: store, transport: FakeTokenTransport(), clock: TestClock())
        try await engine.seed(credentials())

        #expect(ChatGPTConnector.credentialAccount == "chatgpt")
        let stored = try await store.get(
            service: ConnectorOAuthInfo.keychainService,
            account: ChatGPTConnector.credentialAccount
        )
        #expect(stored != nil)
        let claudeSlot = try await store.get(
            service: ConnectorOAuthInfo.keychainService,
            account: OAuthCredentialEngine.claudeAccount
        )
        #expect(claudeSlot == nil, "The two providers must never share a credential slot")
    }

    @Test("An expired ChatGPT token refreshes over a form body and persists the rotated token")
    func expiredTokenRotatesOverAFormBody() async throws {
        let store = InMemorySecretStore()
        let transport = FakeTokenTransport([
            .success(ChatGPTFixture.tokenResponse(
                accessToken: ChatGPTFixture.rotatedAccessToken,
                refreshToken: ChatGPTFixture.rotatedRefreshToken
            )),
        ])
        let clock = TestClock()
        let engine = makeEngine(store: store, transport: transport, clock: clock)
        try await engine.seed(credentials())

        clock.advance(by: 3600)
        #expect(try await engine.accessToken() == ChatGPTFixture.rotatedAccessToken)

        let body = try #require(await transport.recordedBody(0))
        #expect(body.hasPrefix("grant_type=refresh_token&"))
        #expect(body.contains("refresh_token=\(ChatGPTFixture.refreshToken)"))
        #expect(body.contains("client_id=app_EMoamEEZ73f0CkXaXp7hrann"))
        #expect(await transport.recordedHeader("Content-Type", at: 0) == "application/x-www-form-urlencoded")

        let persisted = try #require(await engine.storedCredentials())
        #expect(persisted.refreshToken == ChatGPTFixture.rotatedRefreshToken)
        #expect(persisted.accessToken == ChatGPTFixture.rotatedAccessToken)
    }

    @Test("A refused ChatGPT refresh maps to authExpired and keeps the stored token")
    func refusedRefreshMapsToAuthExpired() async throws {
        let store = InMemorySecretStore()
        let transport = FakeTokenTransport([
            .success(HTTPResponse(statusCode: 401, body: Data("{\"error\":\"invalid_grant\"}".utf8))),
        ])
        let clock = TestClock()
        let engine = makeEngine(store: store, transport: transport, clock: clock)
        try await engine.seed(credentials())
        clock.advance(by: 3600)

        await #expect(throws: ConnectorFailure.authExpired) { try await engine.accessToken() }
        #expect(try await engine.storedCredentials()?.refreshToken == ChatGPTFixture.refreshToken)
    }
}
