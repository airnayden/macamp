// SubscriptionSignInTests — the two shell-side login surfaces, end to end and
// hermetic.
//
// Nothing here reaches a provider, a browser, or the real Keychain: the transport
// is scripted, `openURL` is captured, and every credential lives in an
// `InMemorySecretStore`. The loopback listener, though, is REAL — it binds a
// socket on a high test port and a raw client connects to it, because the whole
// point of that type is what happens at the socket and a mocked one would prove
// nothing.
//
// Three claims:
//
//   1. A Claude session BORROWED from the CLI reports itself distinctly, and
//      signing out of it does not delete it.
//   2. The ChatGPT login opens an authorize URL carrying all six scopes and the
//      endorsed extras, binds the port named in its own `redirect_uri`, and
//      completes when the redirect arrives.
//   3. Every exit path releases the socket.
import AIConnectorKit
import AIConnectorKitOAuth
import Darwin
import Foundation
@testable import MacAMP
import Testing

// MARK: - Claude CLI reuse

@Suite("Claude CLI session reuse", .serialized)
@MainActor
struct ClaudeCLISessionSignInTests {
    @Test("A borrowed CLI session reports itself distinctly from an in-app login")
    func borrowedSessionIsReportedDistinctly() async {
        let stack = ExternalOAuthComposition.makeClaudeStack(
            store: InMemorySecretStore(),
            transport: SilentTransport(),
            externalSource: SignInFixture.cliSource()
        )
        let model = ExternalOAuthComposition.makeSignInModel(stack)

        await model.refreshStatus()

        #expect(model.isSignedIn)
        #expect(model.isUsingCLISession)
        #expect(model.phase == .signedIn(tier: "max", viaCLI: true))
        #expect(
            SignInFixture.text(ClaudeSignInStatusRow.signedInMessage(tier: "max", viaCLI: true))
                == "Signed in via Claude CLI — max plan."
        )
        #expect(
            SignInFixture.text(ClaudeSignInStatusRow.signedInMessage(tier: "max", viaCLI: false))
                == "Signed in — max plan."
        )
    }

    @Test("An in-app login outranks a borrowed one and is NOT reported as CLI-sourced")
    func inAppLoginOutranksTheBorrowedSession() async throws {
        let store = InMemorySecretStore()
        let stack = ExternalOAuthComposition.makeClaudeStack(
            store: store,
            transport: SilentTransport(),
            externalSource: SignInFixture.cliSource()
        )
        try await stack.engine.seed(SignInFixture.ownCredentials)
        let model = ExternalOAuthComposition.makeSignInModel(stack)

        await model.refreshStatus()

        #expect(model.phase == .signedIn(tier: "pro", viaCLI: false))
        #expect(model.isUsingCLISession == false)
    }

    @Test("Signing out of a borrowed session never deletes the CLI's credential")
    func signingOutOfABorrowedSessionIsNonDestructive() async {
        let source = SignInFixture.cliSource()
        let stack = ExternalOAuthComposition.makeClaudeStack(
            store: InMemorySecretStore(),
            transport: SilentTransport(),
            externalSource: source
        )
        let model = ExternalOAuthComposition.makeSignInModel(stack)
        await model.refreshStatus()
        #expect(model.isUsingCLISession)

        await model.signOut()

        #expect(model.phase == .signedOut)
        // The other application is still signed in — which is the whole contract:
        // MacAMP borrowed the credential and has no business destroying it.
        #expect(await source.load() != nil)
    }
}

// MARK: - ChatGPT loopback login

@Suite("ChatGPT subscription sign-in", .serialized)
@MainActor
struct ChatGPTSignInTests {
    @Test("Beginning sign-in opens the endorsed authorize URL and binds its own port")
    func signInOpensTheAuthorizeURLAndBindsThePort() async throws {
        let port = SignInFixture.freePort()
        let opened = OpenedURLRecorder()
        let model = SignInFixture.chatGPTModel(ports: [port], opened: opened)

        await model.beginSignIn()
        defer { model.cancel() }

        #expect(model.phase == .awaitingBrowser)
        let url = try #require(opened.captured)
        let items = SignInFixture.queryItems(url)
        #expect(url.host == "auth.openai.com")
        #expect(url.path == "/oauth/authorize")
        #expect(items["scope"] == "openid profile email offline_access "
            + "api.connectors.read api.connectors.invoke")
        #expect(items["redirect_uri"] == "http://localhost:\(port)/auth/callback")
        #expect(items["originator"] == "codex_cli_rs")
        #expect(items["id_token_add_organizations"] == "true")
        #expect(items["codex_cli_simplified_flow"] == "true")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["client_id"] == "app_EMoamEEZ73f0CkXaXp7hrann")
        // The socket really is listening — a second bind on the same port fails.
        #expect(SignInFixture.canBind(port) == false)
    }

    @Test("The redirect completes the login and seeds the shared engine")
    func theRedirectCompletesTheLogin() async throws {
        let port = SignInFixture.freePort()
        let opened = OpenedURLRecorder()
        let store = InMemorySecretStore()
        let stack = SignInFixture.chatGPTStack(store: store)
        let model = ChatGPTSignInModel(
            flow: stack.flow,
            engine: stack.engine,
            ports: [port],
            openURL: { opened.captured = $0 }
        )

        await model.beginSignIn()
        let authorizeURL = try #require(opened.captured)
        let state = try #require(SignInFixture.queryItems(authorizeURL)["state"])
        SignInFixture.deliverCallback(port: port, query: "code=test-token-shell-code&state=\(state)")

        try await SignInFixture.settle { model.isSignedIn }

        #expect(model.phase == .signedIn(tier: "pro"))
        // Seeded into the SAME store the registry's connector reads.
        let blob = try await store.get(
            service: ConnectorOAuthInfo.keychainService,
            account: ChatGPTConnector.credentialAccount
        )
        #expect(blob != nil)
        #expect(await stack.connector.isSignedIn())
        // The port is released once the login finishes.
        #expect(SignInFixture.canBind(port))
    }

    @Test("A callback bearing a foreign state is refused and nothing is stored")
    func aForeignStateIsRefused() async throws {
        let port = SignInFixture.freePort()
        let store = InMemorySecretStore()
        let stack = SignInFixture.chatGPTStack(store: store)
        let model = ChatGPTSignInModel(flow: stack.flow, engine: stack.engine, ports: [port], openURL: { _ in })

        await model.beginSignIn()
        SignInFixture.deliverCallback(port: port, query: "code=test-token-shell-code&state=not-our-attempt")

        try await SignInFixture.settle { model.phase == .failed(.staleAttempt) }

        #expect(try await store.get(
            service: ConnectorOAuthInfo.keychainService,
            account: ChatGPTConnector.credentialAccount
        ) == nil)
    }

    @Test("Cancelling releases the socket and reports signed out")
    func cancellingReleasesTheSocket() async throws {
        let port = SignInFixture.freePort()
        let model = SignInFixture.chatGPTModel(ports: [port], opened: OpenedURLRecorder())

        await model.beginSignIn()
        #expect(SignInFixture.canBind(port) == false)

        model.cancel()

        #expect(model.phase == .signedOut)
        try await SignInFixture.settle { SignInFixture.canBind(port) }
    }

    @Test("No usable port is a named failure, not a silent hang")
    func noUsablePortIsANamedFailure() async throws {
        // The two loopback ports are registered server-side, so falling back to an
        // arbitrary free one would bind a socket the provider never connects to.
        // Refusing loudly is the only honest outcome.
        let port = SignInFixture.freePort()
        let squatter = try LoopbackCallbackListener.bind(preferredPorts: [port])
        defer { Task { await squatter.cancel() } }
        let model = SignInFixture.chatGPTModel(ports: [port], opened: OpenedURLRecorder())

        await model.beginSignIn()

        #expect(model.phase == .failed(.portUnavailable))
    }

    @Test("The listener falls back to the second port when the first is taken")
    func theListenerFallsBackToTheSecondPort() throws {
        let taken = SignInFixture.freePort()
        let spare = SignInFixture.freePort()
        let squatter = try LoopbackCallbackListener.bind(preferredPorts: [taken])
        defer { Task { await squatter.cancel() } }

        let listener = try LoopbackCallbackListener.bind(preferredPorts: [taken, spare])
        defer { Task { await listener.cancel() } }

        #expect(listener.port == spare)
    }
}

// MARK: - Loopback listener

@Suite("Loopback callback listener", .serialized)
struct LoopbackCallbackListenerTests {
    @Test("One GET is captured as a URL, then the socket closes")
    func oneRequestIsCaptured() async throws {
        let port = SignInFixture.freePort()
        let listener = try LoopbackCallbackListener.bind(preferredPorts: [port])
        let captured = Task { try await listener.waitForCallback() }

        SignInFixture.deliverCallback(port: port, query: "code=abc&state=xyz")

        let url = try await captured.value
        #expect(url.path == "/auth/callback")
        #expect(SignInFixture.queryItems(url)["code"] == "abc")
        #expect(SignInFixture.queryItems(url)["state"] == "xyz")
        try await SignInFixture.settle { SignInFixture.canBind(port) }
    }

    @Test("Cancelling an unanswered wait throws cancelled and frees the port")
    func cancellingAnUnansweredWait() async throws {
        let port = SignInFixture.freePort()
        let listener = try LoopbackCallbackListener.bind(preferredPorts: [port])
        let waiting = Task { try await listener.waitForCallback() }

        try await Task.sleep(for: .milliseconds(50))
        await listener.cancel()

        await #expect(throws: LoopbackCallbackListener.Failure.cancelled) { try await waiting.value }
        try await SignInFixture.settle { SignInFixture.canBind(port) }
    }
}
