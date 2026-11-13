// ExternalOAuthComposition — the one place the subscription stack is assembled,
// and the integration point the macOS composition root wires against.
//
// ── THE GUARD BELOW IS DELIBERATE ─────────────────────────────────────────────
//
// This folder is a buildable folder on `macampMac`, the ONE macOS app target,
// which defines MACAMP_EXTERNAL_OAUTH. The flag and the folder must travel
// together: code under `Sources/` names this folder's types from inside
// `#if MACAMP_EXTERNAL_OAUTH`, so a target that compiles the folder WITHOUT the
// flag silently drops every call site — the login UI is built and then never
// reachable. Failing the build with a sentence naming the fix is strictly better.
#if !MACAMP_EXTERNAL_OAUTH
    #error("""
    macOS/ExternalOAuth is attached to a target that does not define MACAMP_EXTERNAL_OAUTH. \
    The flag and this folder must travel together, or the login UI compiles but no \
    call site can reach it. See macOS/Project.swift.
    """)
#endif

import AIConnectorKit
import AIConnectorKitOAuth
import Foundation

/// Builds the Claude subscription stack: credential engine, login flow, connector.
///
/// ── WHAT THE macOS COMPOSITION ROOT WIRES (plan todo 13) ──────────────────────
///
/// `macOS/Sources/AppEnvironment+AI.swift` compiles into BOTH app targets, so it
/// can only name anything in this folder from inside the flag:
///
/// ```swift
/// #if MACAMP_EXTERNAL_OAUTH
///     let claude = ExternalOAuthComposition.makeClaudeStack()
///     registry.register(claude.connector)
/// #endif
/// ```
///
/// and the Preferences surface presents ``ClaudeSignInView`` with
/// ``makeSignInModel(_:)`` over the SAME stack — the engine must be shared, or
/// the connector would read a credential the login never seeded.
///
/// ── WHY THE STACK IS ONE VALUE ────────────────────────────────────────────────
///
/// Engine, flow and connector are handed out together because they are only
/// correct together: the flow SEEDS the engine, the connector READS it, and two
/// engines over the same Keychain slot would each cache their own in-flight
/// refresh — defeating the single-flighting that keeps the provider's single-use
/// refresh token from being spent twice.
enum ExternalOAuthComposition {
    /// Registry id of the connector this stack produces.
    static let claudeConnectorID = ClaudeSubscriptionConnector.connectorID

    /// Registry id of the ChatGPT connector this composition produces.
    static let chatGPTConnectorID = "chatgpt"

    /// One signed-in-or-not Claude subscription, in three cooperating pieces.
    struct ClaudeStack {
        /// Owns the stored credential and every rotation of it.
        let engine: OAuthCredentialEngine
        /// Mints the authorize URL and performs the code exchange.
        let flow: ClaudeOAuthFlow
        /// The `AIProviderConnector` the registry receives.
        let connector: ClaudeSubscriptionConnector
    }

    /// The same three pieces for ChatGPT.
    struct ChatGPTStack {
        let engine: OAuthCredentialEngine
        let flow: ChatGPTOAuthFlow
        let connector: ChatGPTConnector
    }

    /// - Parameters:
    ///   - store: Credential storage. The Keychain in production; tests and
    ///     previews pass `InMemorySecretStore`.
    ///   - configuration: Endpoints and parameters. The researched Claude set by
    ///     default — every constant in it is injectable because the surface is
    ///     unofficial and moves.
    ///   - transport: The single network seam, shared by the login exchange, the
    ///     engine's refreshes and the connector's API calls.
    ///   - externalSource: A Claude Code CLI login already on this Mac, consulted
    ///     ONLY when MacAMP holds no credential of its own. Pass `nil` — as the
    ///     preview stack does — to switch reuse off entirely; that keeps a preview
    ///     or a test from ever running `/usr/bin/security` against a real Keychain.
    ///     Read `ClaudeCLICredentialStore`'s header before touching this: reuse of
    ///     Claude Code tokens is against Anthropic's terms and exists here only at
    ///     the owner's explicit request, for their own machine.
    static func makeClaudeStack(
        store: any SecretStore = KeychainSecretStore(),
        configuration: OAuthEndpointConfiguration = .claudeSubscription,
        transport: any HTTPTransport = URLSessionTransport(),
        externalSource: (any ExternalCredentialSource)? = ClaudeCLICredentialStore()
    ) -> ClaudeStack {
        let engine = OAuthCredentialEngine(
            store: store,
            configuration: configuration,
            transport: transport,
            externalSource: externalSource
        )
        return ClaudeStack(
            engine: engine,
            flow: ClaudeOAuthFlow(configuration: configuration, transport: transport),
            connector: ClaudeSubscriptionConnector(engine: engine, transport: transport)
        )
    }

    /// Builds the ChatGPT subscription stack.
    ///
    /// No `externalSource`: there is no other application on this Mac whose
    /// ChatGPT credential MacAMP is entitled to reuse. Reuse is a Claude-only
    /// accommodation, made at the owner's explicit request — see
    /// ``ClaudeCLICredentialStore``.
    ///
    /// The engine's `account:` is ``ChatGPTConnector/credentialAccount``, a
    /// DIFFERENT slot in the same Keychain service, so the two subscriptions never
    /// evict each other.
    static func makeChatGPTStack(
        store: any SecretStore = KeychainSecretStore(),
        configuration: OAuthEndpointConfiguration = .chatGPTSubscription,
        transport: any HTTPTransport = URLSessionTransport()
    ) -> ChatGPTStack {
        let engine = OAuthCredentialEngine(
            store: store,
            configuration: configuration,
            transport: transport,
            account: ChatGPTConnector.credentialAccount
        )
        return ChatGPTStack(
            engine: engine,
            flow: ChatGPTOAuthFlow(configuration: configuration, transport: transport),
            connector: ChatGPTConnector(
                bearerToken: { try await engine.accessToken() },
                signedIn: { await engine.hasStoredCredentials() },
                transport: transport
            )
        )
    }

    @MainActor
    static func makeSignInModel(_ stack: ClaudeStack) -> ClaudeSignInModel {
        ClaudeSignInModel(flow: stack.flow, engine: stack.engine)
    }

    @MainActor
    static func makeSignInModel(_ stack: ChatGPTStack) -> ChatGPTSignInModel {
        ChatGPTSignInModel(flow: stack.flow, engine: stack.engine)
    }

    /// An inert stack for `#Preview`: nothing is stored, CLI reuse is off, and
    /// opening the approval page is a no-op — so a preview can never reach the
    /// Keychain, a subprocess, or a browser.
    @MainActor
    static func previewSignInModel() -> ClaudeSignInModel {
        let stack = makeClaudeStack(store: InMemorySecretStore(), externalSource: nil)
        return ClaudeSignInModel(flow: stack.flow, engine: stack.engine, openURL: { _ in })
    }

    /// An inert ChatGPT stack for `#Preview`. `ports: []` matters as much as the
    /// no-op `openURL`: a preview that bound 1455 would steal the port from a real
    /// sign-in running in the same Xcode session.
    @MainActor
    static func previewChatGPTSignInModel() -> ChatGPTSignInModel {
        let stack = makeChatGPTStack(store: InMemorySecretStore())
        return ChatGPTSignInModel(flow: stack.flow, engine: stack.engine, ports: [], openURL: { _ in })
    }
}
