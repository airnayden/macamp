import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

@Suite("OAuthCredentialEngineStorageTests")
struct OAuthCredentialEngineStorageTests {
    @Test("A seed persists the whole blob in exactly one write")
    func seedPersistsTheWholeBlobInOneWrite() async throws {
        let store = InMemorySecretStore()
        let engine = OAuthCredentialEngine(store: store, configuration: OAuthFixture.testConfiguration())

        try await engine.seed(OAuthFixture.credentials())

        #expect(await store.writeCount == 1)
        #expect(await store.storedSecretCount == 1)
        let restored = try #require(await engine.storedCredentials())
        #expect(restored == OAuthFixture.credentials())
    }

    @Test("A partial seed is refused and nothing is written")
    func partialSeedIsRefused() async throws {
        let store = InMemorySecretStore()
        let engine = OAuthCredentialEngine(store: store, configuration: OAuthFixture.testConfiguration())

        await #expect(throws: OAuthFlowError.partialCredentialSeedRejected) {
            try await engine.seed(OAuthFixture.credentials(refreshToken: ""))
        }
        await #expect(throws: OAuthFlowError.partialCredentialSeedRejected) {
            try await engine.seed(OAuthFixture.credentials(accessToken: ""))
        }
        #expect(await store.writeCount == 0)
    }

    @Test("An engine with nothing stored is unconfigured, not expired")
    func unconfiguredEngineReportsUnconfigured() async throws {
        let engine = OAuthCredentialEngine(
            store: InMemorySecretStore(),
            configuration: OAuthFixture.testConfiguration()
        )
        #expect(try await engine.storedCredentials() == nil)
        #expect(await engine.hasStoredCredentials() == false)
        await #expect(throws: ConnectorFailure.unconfigured) { try await engine.accessToken() }
    }

    @Test("A stored blob that cannot be decoded demands a fresh login")
    func corruptStoredBlobDemandsANewLogin() async throws {
        let store = InMemorySecretStore()
        try await store.set(
            "not-json",
            service: ConnectorOAuthInfo.keychainService,
            account: OAuthCredentialEngine.claudeAccount
        )
        let engine = OAuthCredentialEngine(store: store, configuration: OAuthFixture.testConfiguration())
        await #expect(throws: ConnectorFailure.authExpired) { try await engine.storedCredentials() }
    }

    @Test("Signing out removes the credential and is idempotent")
    func signOutRemovesTheCredential() async throws {
        let store = InMemorySecretStore()
        let engine = OAuthCredentialEngine(store: store, configuration: OAuthFixture.testConfiguration())
        try await engine.seed(OAuthFixture.credentials())

        try await engine.signOut()
        try await engine.signOut()

        #expect(await store.storedSecretCount == 0)
        #expect(await engine.hasStoredCredentials() == false)
    }
}

@Suite("OAuthCredentialEngineRefreshTests")
struct OAuthCredentialEngineRefreshTests {
    private func makeEngine(
        store: InMemorySecretStore,
        transport: FakeTokenTransport,
        clock: TestClock
    ) -> OAuthCredentialEngine {
        OAuthCredentialEngine(
            store: store,
            configuration: OAuthFixture.testConfiguration(),
            transport: transport,
            now: clock.now
        )
    }

    @Test("A still-fresh token is returned with no network call at all")
    func freshTokenCostsNoNetworkCall() async throws {
        let store = InMemorySecretStore()
        let transport = FakeTokenTransport()
        let engine = makeEngine(store: store, transport: transport, clock: TestClock())
        try await engine.seed(OAuthFixture.credentials())

        #expect(try await engine.accessToken() == OAuthFixture.accessToken)
        #expect(await transport.recordedRequests.isEmpty)
    }

    @Test("An expired token refreshes, and the ROTATED refresh token is persisted")
    func expiredTokenRotatesAndPersistsTheNewRefreshToken() async throws {
        let store = InMemorySecretStore()
        let transport = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(
                accessToken: OAuthFixture.rotatedAccessToken,
                refreshToken: OAuthFixture.rotatedRefreshToken
            )),
        ])
        let clock = TestClock()
        let engine = makeEngine(store: store, transport: transport, clock: clock)
        try await engine.seed(OAuthFixture.credentials())

        clock.advance(by: 3600)
        #expect(try await engine.accessToken() == OAuthFixture.rotatedAccessToken)

        let persisted = try #require(await engine.storedCredentials())
        #expect(persisted.refreshToken == OAuthFixture.rotatedRefreshToken)
        #expect(persisted.accessToken == OAuthFixture.rotatedAccessToken)
        #expect(persisted.expiresAt == OAuthFixture.epoch.addingTimeInterval(3600 + 28800))
        // Preserved from the seed — the response carried neither.
        #expect(persisted.subscriptionType == "max")
        #expect(persisted.scopes == ["user:profile", "user:inference"])
    }

    @Test("A refresh response WITHOUT a refresh token keeps the stored one")
    func refreshWithoutARotatedTokenKeepsTheStoredOne() async throws {
        let store = InMemorySecretStore()
        let transport = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(accessToken: OAuthFixture.rotatedAccessToken, refreshToken: nil)),
        ])
        let clock = TestClock()
        let engine = makeEngine(store: store, transport: transport, clock: clock)
        try await engine.seed(OAuthFixture.credentials())

        clock.advance(by: 3600)
        _ = try await engine.accessToken()

        let persisted = try #require(await engine.storedCredentials())
        #expect(
            persisted.refreshToken == OAuthFixture.refreshToken,
            "Absent means UNCHANGED — never null the credential out"
        )
        #expect(persisted.accessToken == OAuthFixture.rotatedAccessToken)
    }

    @Test("The refresh body carries the stored refresh token and the client id")
    func refreshBodyCarriesTheStoredRefreshToken() async throws {
        let store = InMemorySecretStore()
        let transport = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(
                accessToken: OAuthFixture.rotatedAccessToken,
                refreshToken: OAuthFixture.rotatedRefreshToken
            )),
        ])
        let engine = makeEngine(store: store, transport: transport, clock: TestClock())
        try await engine.seed(OAuthFixture.credentials())
        _ = try await engine.forceRefresh()

        let body = try #require(await transport.recordedBody(0))
        #expect(body.contains("\"grant_type\":\"refresh_token\""))
        #expect(body.contains("\"refresh_token\":\"\(OAuthFixture.refreshToken)\""))
        #expect(body.contains("\"client_id\":\"9d1c250a-e61b-44d9-88ed-5944d1962f5e\""))
        #expect(body.contains("\"scope\":\"user:profile user:inference\""))
    }

    @Test("A provider that refuses the refresh maps to authExpired")
    func refusedRefreshMapsToAuthExpired() async throws {
        let store = InMemorySecretStore()
        let transport = FakeTokenTransport([
            .success(HTTPResponse(statusCode: 401, body: Data("{\"error\":\"invalid_grant\"}".utf8))),
            .success(HTTPResponse(statusCode: 200, body: Data("{\"token_type\":\"Bearer\"}".utf8))),
        ])
        let clock = TestClock()
        let engine = makeEngine(store: store, transport: transport, clock: clock)
        try await engine.seed(OAuthFixture.credentials())
        clock.advance(by: 3600)

        await #expect(throws: ConnectorFailure.authExpired) { try await engine.accessToken() }
        // A 2xx carrying no access token is equally unrecoverable.
        await #expect(throws: ConnectorFailure.authExpired) { try await engine.accessToken() }
        // The dead session was NOT overwritten, so a later successful refresh
        // still has the original token to present.
        #expect(try await engine.storedCredentials()?.refreshToken == OAuthFixture.refreshToken)
    }

    @Test("An unreachable provider is NOT reported as an expired session")
    func transportFailurePropagatesUnchanged() async throws {
        let store = InMemorySecretStore()
        let transport = FakeTokenTransport([
            .failure(.unreachable(underlying: ConnectorFailure.DiagnosticToken.networkUnavailable)),
        ])
        let clock = TestClock()
        let engine = makeEngine(store: store, transport: transport, clock: clock)
        try await engine.seed(OAuthFixture.credentials())
        clock.advance(by: 3600)

        let expected = ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.networkUnavailable)
        await #expect(throws: expected) { try await engine.accessToken() }
    }

    @Test("forceRefresh bypasses the expiry check")
    func forceRefreshBypassesTheExpiryCheck() async throws {
        let store = InMemorySecretStore()
        let transport = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(
                accessToken: OAuthFixture.rotatedAccessToken,
                refreshToken: OAuthFixture.rotatedRefreshToken
            )),
        ])
        let engine = makeEngine(store: store, transport: transport, clock: TestClock())
        try await engine.seed(OAuthFixture.credentials())

        #expect(try await engine.forceRefresh() == OAuthFixture.rotatedAccessToken)
        #expect(await transport.recordedRequests.count == 1)
    }

    @Test("A token inside the expiry buffer refreshes rather than being handed out")
    func tokenInsideTheExpiryBufferRefreshes() async throws {
        let store = InMemorySecretStore()
        let transport = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(
                accessToken: OAuthFixture.rotatedAccessToken,
                refreshToken: OAuthFixture.rotatedRefreshToken
            )),
        ])
        let clock = TestClock()
        let engine = makeEngine(store: store, transport: transport, clock: clock)
        try await engine.seed(OAuthFixture.credentials())

        // 30 s of life left, inside the 60 s buffer: still "valid", already stale.
        clock.advance(by: 3570)
        #expect(try await engine.accessToken() == OAuthFixture.rotatedAccessToken)
    }

    @Test("Concurrent callers share exactly one refresh, so the rotating token is presented once")
    func concurrentCallersShareOneRefresh() async throws {
        let store = InMemorySecretStore()
        let transport = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(
                accessToken: OAuthFixture.rotatedAccessToken,
                refreshToken: OAuthFixture.rotatedRefreshToken
            )),
        ])
        let clock = TestClock()
        let engine = makeEngine(store: store, transport: transport, clock: clock)
        try await engine.seed(OAuthFixture.credentials())
        clock.advance(by: 3600)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { try await engine.accessToken() }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }

        #expect(tokens == Array(repeating: OAuthFixture.rotatedAccessToken, count: 8))
        #expect(
            await transport.recordedRequests.count == 1,
            "A second concurrent refresh would present an already-invalidated token"
        )
    }
}
