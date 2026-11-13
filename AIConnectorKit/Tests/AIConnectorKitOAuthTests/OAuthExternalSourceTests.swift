// The engine's second credential source, proved end to end without a network,
// a Keychain, or a subprocess.
//
// Four claims, each of which silently strands a listener if it is wrong:
//
//   1. PRECEDENCE. MacAMP's own blob wins; the borrowed one is consulted only when
//      this app holds nothing.
//   2. WRITE-BACK LANDS AT THE ORIGIN. A rotation of a borrowed credential updates
//      the OTHER application's copy, not ours.
//   3. A REFUSED WRITE-BACK ADOPTS. The refresh token is single-use, so a rotation
//      whose write-back failed must not leave the only live token in memory.
//   4. SIGN-OUT DOES NOT DELETE. A borrowed credential is suppressed, never
//      destroyed.
import AIConnectorKit
@testable import AIConnectorKitOAuth
import Foundation
import Testing

@Suite("OAuthExternalSourceTests")
struct OAuthExternalSourceTests {
    @Test("MacAMP's own credential outranks a borrowed one")
    func ownStoreWinsOverTheExternalSource() async throws {
        let store = InMemorySecretStore()
        let engine = Self.engine(store: store, source: Self.borrowedSource())
        try await engine.seed(OAuthFixture.credentials())

        let reading = try #require(await engine.storedCredentialReading())

        #expect(reading.credentials.accessToken == OAuthFixture.accessToken)
        #expect(reading.origin == .app)
        #expect(reading.origin.isExternal == false)
    }

    @Test("A borrowed credential is used when this app holds nothing")
    func externalSourceFillsTheGap() async throws {
        let engine = Self.engine(source: Self.borrowedSource())

        let reading = try #require(await engine.storedCredentialReading())

        #expect(reading.credentials.accessToken == ClaudeCLIFixture.accessToken)
        #expect(reading.origin.isExternal)
        #expect(await engine.hasStoredCredentials())
    }

    @Test("With no source at all the engine behaves exactly as before")
    func noSourceIsTheUnchangedBaseline() async throws {
        let engine = Self.engine()

        #expect(try await engine.storedCredentialReading() == nil)
        #expect(await engine.hasStoredCredentials() == false)
        await #expect(throws: ConnectorFailure.unconfigured) { try await engine.accessToken() }
    }

    @Test("Rotating a borrowed credential writes back to its origin, not to our store")
    func rotationWritesBackToTheOrigin() async throws {
        let store = InMemorySecretStore()
        let source = Self.borrowedSource()
        let transport = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(
                accessToken: ClaudeCLIFixture.rotatedAccessToken,
                refreshToken: ClaudeCLIFixture.rotatedRefreshToken
            )),
        ])
        let engine = Self.engine(store: store, transport: transport, source: source)

        // The borrowed fixture is already expired, so the first read refreshes.
        #expect(try await engine.accessToken() == ClaudeCLIFixture.rotatedAccessToken)

        let written = await source.writtenCredentials
        #expect(written.count == 1)
        #expect(written.first?.refreshToken == ClaudeCLIFixture.rotatedRefreshToken)
        // Our own store stays EMPTY: adopting a credential we successfully wrote
        // back would flip precedence and hide the other app's later rotations.
        #expect(try await store.get(
            service: ConnectorOAuthInfo.keychainService,
            account: OAuthCredentialEngine.claudeAccount
        ) == nil)
    }

    @Test("A refused write-back adopts the rotated credential rather than losing it")
    func refusedWriteBackAdopts() async throws {
        let store = InMemorySecretStore()
        let source = Self.borrowedSource(writeSucceeds: false)
        let transport = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(
                accessToken: ClaudeCLIFixture.rotatedAccessToken,
                refreshToken: ClaudeCLIFixture.rotatedRefreshToken
            )),
        ])
        let engine = Self.engine(store: store, transport: transport, source: source)

        #expect(try await engine.accessToken() == ClaudeCLIFixture.rotatedAccessToken)

        // The presented refresh token is dead everywhere now, so the replacement
        // must survive this process. Precedence makes us the owner from here on.
        let reading = try #require(await engine.storedCredentialReading())
        #expect(reading.origin == .app)
        #expect(reading.credentials.refreshToken == ClaudeCLIFixture.rotatedRefreshToken)
    }

    @Test("Signing out suppresses a borrowed credential without deleting it")
    func signOutSuppressesRatherThanDeletes() async throws {
        let source = Self.borrowedSource()
        let engine = Self.engine(source: source)
        #expect(await engine.hasStoredCredentials())

        try await engine.signOut()

        #expect(await engine.hasStoredCredentials() == false)
        #expect(try await engine.storedCredentialReading() == nil)
        // The other application's login is untouched — a fresh engine over the
        // SAME source finds it again, which is what a relaunch does.
        #expect(await Self.engine(source: source).hasStoredCredentials())
    }

    @Test("Signing in here clears the suppression latch")
    func seedingClearsSuppression() async throws {
        let engine = Self.engine(source: Self.borrowedSource())
        try await engine.signOut()

        try await engine.seed(OAuthFixture.credentials())

        let reading = try #require(await engine.storedCredentialReading())
        #expect(reading.origin == .app)
    }

    @Test("A borrowed credential's refresh carries the fingerprinted axios agent")
    func refreshPinsTheFingerprintedUserAgent() async throws {
        // NOT cosmetic and NOT a guess: the token host fingerprints `User-Agent`
        // and answers HTTP 429 to a client that does not look like the reference
        // implementation's HTTP stack (jarvis, live-validated). A well-meaning
        // "identify ourselves honestly" edit here rate-limits every refresh.
        let transport = FakeTokenTransport([
            .success(OAuthFixture.tokenResponse(
                accessToken: ClaudeCLIFixture.rotatedAccessToken,
                refreshToken: nil
            )),
        ])
        let engine = Self.engine(transport: transport, source: Self.borrowedSource())

        _ = try await engine.accessToken()

        #expect(await transport.recordedHeader("User-Agent", at: 0) == "axios/1.13.6")
        #expect(await transport.recordedHeader("Content-Type", at: 0) == "application/json")
        let body = try #require(await transport.recordedBody(0))
        #expect(body.contains("\"grant_type\":\"refresh_token\""))
        #expect(body.contains("\"client_id\":\"9d1c250a-e61b-44d9-88ed-5944d1962f5e\""))
        // The CLI blob's OWN scopes are echoed, not the configured authorize set.
        #expect(body.contains("\"scope\":\"user:profile user:inference\""))
    }

    @Test("The engine's real token endpoint is the platform host")
    func tokenEndpointIsThePlatformHost() {
        #expect(
            OAuthEndpointConfiguration.claudeSubscription.tokenURL.absoluteString
                == "https://platform.claude.com/v1/oauth/token"
        )
        #expect(OAuthEndpointConfiguration.claudeSubscription.tokenRequestUserAgent == "axios/1.13.6")
    }

    @Test("A reading never renders its tokens, through any route")
    func readingsRedactTheirTokens() {
        let reading = StoredCredentialReading(credentials: OAuthFixture.credentials(), origin: .app)
        let rendered = [
            String(describing: reading),
            String(reflecting: reading),
            Self.dumped(reading),
            String(describing: ExternalCredentialReading(
                credentials: OAuthFixture.credentials(),
                origin: .keychainFixture
            )),
            Self.dumped(ExternalCredentialReading(
                credentials: OAuthFixture.credentials(),
                origin: .keychainFixture
            )),
        ]

        for text in rendered {
            #expect(text.contains("test-token-") == false)
        }
    }
}

// MARK: - Builders

private extension OAuthExternalSourceTests {
    /// A borrowed credential that is ALREADY EXPIRED, so the first token read
    /// exercises the refresh-and-write-back path rather than a cache hit.
    static func borrowedSource(writeSucceeds: Bool = true) -> StubExternalCredentialSource {
        StubExternalCredentialSource(
            reading: ExternalCredentialReading(
                credentials: OAuthCredentials(
                    accessToken: ClaudeCLIFixture.accessToken,
                    refreshToken: ClaudeCLIFixture.refreshToken,
                    expiresAt: OAuthFixture.epoch.addingTimeInterval(-3600),
                    subscriptionType: "max",
                    scopes: ["user:profile", "user:inference"]
                ),
                origin: .keychainFixture
            ),
            writeSucceeds: writeSucceeds
        )
    }

    static func engine(
        store: InMemorySecretStore = InMemorySecretStore(),
        transport: FakeTokenTransport = FakeTokenTransport(),
        source: (any ExternalCredentialSource)? = nil
    ) -> OAuthCredentialEngine {
        OAuthCredentialEngine(
            store: store,
            configuration: OAuthFixture.testConfiguration(),
            transport: transport,
            now: TestClock().now,
            externalSource: source
        )
    }

    static func dumped(_ value: some Any) -> String {
        var text = ""
        dump(value, to: &text)
        return text
    }
}
