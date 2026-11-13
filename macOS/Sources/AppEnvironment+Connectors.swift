// AppEnvironment+Connectors — which AI provider answers, and how it is reached.
//
// Split out of `AppEnvironment+AI.swift` for one mechanical reason: that file is at
// the repo's CI-enforced 400-line ceiling (`file_length`, `swiftlint --strict`), and
// the connector composition does not fit inside it. The boundary is a real one
// either way — everything here is about SELECTING and CONFIGURING a provider, while
// the sibling file is about assembling the AI graph and keeping it live.
//
// ── SETTINGS ARE APP-WIDE, NOT PER-PROFILE ─────────────────────────────────────
//
// Neither `AppSettings` nor the Keychain is profile-scoped, so switching listener
// never changes which provider answers — only the library the request is
// interpreted against. That is a recorded decision of the `ai-provider-connectors`
// plan, which is why `rescopeAI(settings:)` rebuilds the route rather than
// re-scoping it, and why nothing below takes a `profileId`.
//
// ── A SELECTION IS A NEW GRAPH, NEVER A MUTATED ONE ────────────────────────────
//
// `ConnectorQueryParser`, `ConnectorNamer` and `ConnectorNarrator` are `struct`s
// with no mutable state, and `ConnectorRegistry` is a value type. So a provider,
// model or host change is expressed by BUILDING different conformers — which is
// what `observeIntelligenceToggle(settings:)` triggers, and what lets the
// Intelligence pane keep its no-`.onChange` contract.
//
// ── NOTHING HERE READS A SECRET ────────────────────────────────────────────────
//
// API keys are resolved at CALL time, from the Keychain, inside a closure. No key,
// token or host credential is ever read onto the launch path or held in memory by
// this composition — which is also what lets a key entered in Preferences work
// without a relaunch.
import AIConnectorBridge
import AIConnectorKit
import Foundation
import Persistence
import Services

#if MACAMP_EXTERNAL_OAUTH
    import AIConnectorKitOAuth
#endif

extension AppEnvironment {
    /// A one-way latch that ends one built graph's connector route.
    ///
    /// The ladder's connector task is UNSTRUCTURED and owned by PlayerCore, which
    /// cancels-and-ABANDONS it on its own deadline — deliberately, because a
    /// conformer parked in a continuation it never resumes cannot be awaited. The
    /// composition root therefore cannot reach that task, and replacing
    /// ``AppEnvironment/intelligence`` alone would leave the outgoing listener's
    /// provider request running.
    ///
    /// What the root CAN guarantee — and what a profile switch actually needs — is
    /// that the outgoing route performs NO FURTHER provider work. Every entry point
    /// into a connector call consults this latch first: the readiness predicate
    /// refuses (so the ladder falls straight through to the on-device tiers) and the
    /// model provider answers `nil` (so ``ConnectorQueryParser`` raises
    /// `.unconfigured` BEFORE any transport call, even part-way through a parse). An
    /// answer already on the wire can still arrive, but it lands in the outgoing
    /// ``ProposalStore``, which is no longer reachable from anywhere.
    ///
    /// `@MainActor` so ``cancel()`` is SYNCHRONOUS from `rescopeAI(settings:)` — an
    /// `actor` would flip asynchronously and could lose the race with the rebuild.
    @MainActor
    final class ConnectorSession {
        /// `false` once the graph that owns this session has been replaced.
        private(set) var isActive = true

        func cancel() {
            isActive = false
        }
    }

    /// The selected connector plus the two closures every conformer needs.
    ///
    /// Fully `Sendable`: an ``AIProviderConnector`` is, and the closures capture only
    /// `@MainActor` references, so the whole route crosses into a nonisolated parse.
    struct ConnectorRoute {
        let connector: any AIProviderConnector
        /// The listener's model id, or `nil` — which every conformer reads as
        /// ``ConnectorFailure/unconfigured`` and raises with ZERO provider calls.
        let model: @Sendable () async -> String?
        /// The connector tier's OWN predicate — see ``connectorReadiness(registry:connectorID:session:)``.
        let isReady: @Sendable () async -> Bool
    }

    /// Keychain slot every plain API key is stored under, inside its connector's own
    /// service namespace. One constant, so todo 15's config sheets write exactly
    /// where this composition reads.
    static let connectorAPIKeyAccount = "apiKey"

    /// `OpenAIConnector` publishes its id only per instance, so its Keychain
    /// namespace is named from this constant instead. Pinned by a test.
    static let openAIConnectorID = "openai"

    /// `OllamaConnector` publishes its id per instance too. Pinned by a test.
    static let ollamaConnectorID = "ollama"

    /// The connectors this build offers, in the order the picker lists them.
    ///
    /// Registration is the ONLY place provider names appear: the kit's registry has
    /// no built-in list, so the App-Store binary registers three connectors and the
    /// non-App-Store one registers five, from the same type. A subscription connector
    /// whose OAuth product is not linked simply never registers, and a persisted
    /// selection naming it resolves to nothing rather than to a half-present feature.
    static func makeConnectorRegistry(settings: AppSettings) -> ConnectorRegistry {
        let transport = URLSessionTransport()
        let secrets = KeychainSecretStore()
        var registry = ConnectorRegistry()
        // The Ollama key is OPTIONAL — self-hosted needs none, Ollama Cloud does —
        // so the provider is always passed and simply resolves to nothing when the
        // Keychain slot is empty. See `OllamaConnector.authorized(_:)`.
        registry.register(OllamaConnector(
            host: ollamaHost(settings.ollamaHost),
            apiKey: connectorAPIKey(secrets, for: ollamaConnectorID),
            transport: transport
        ))
        registry.register(AnthropicConnector(
            auth: .apiKey(provider: connectorAPIKey(secrets, for: AnthropicConnector.connectorID)),
            transport: transport
        ))
        registry.register(OpenAIConnector(
            apiKey: connectorAPIKey(secrets, for: openAIConnectorID),
            transport: transport
        ))
        #if MACAMP_EXTERNAL_OAUTH
            // ONE stack per process, never one per rebuild: two `OAuthCredentialEngine`s
            // over the same Keychain slot each memoise their own in-flight refresh,
            // which defeats the single-flighting that stops a single-use refresh token
            // being spent twice — and the Preferences sign-in surface must seed the very
            // engine the connector reads. See ``ExternalOAuthStacks``.
            registry.register(ExternalOAuthStacks.claude.connector)
            registry.register(
                ExternalOAuthStacks.chatGPT.connector,
                disabledReason: disabledReason(of: ChatGPTConnector.registrationStatus)
            )
        #endif
        return registry
    }

    /// The selected connector's route, or `nil` when the listener has not chosen one
    /// — the shipped default, which is Apple Intelligence and zero network.
    static func connectorRoute(
        settings: AppSettings,
        registry: ConnectorRegistry,
        session: ConnectorSession
    ) -> ConnectorRoute? {
        // RESOLVED, never the raw string: an id no build registers — a newer release,
        // a link-gated OAuth connector — degrades to Apple Intelligence while the
        // stored value is left untouched, so it re-selects the moment it returns.
        guard let id = settings.resolvedConnectorID(among: registry.ids),
              let connector = registry.connector(id: id) else { return nil }
        return ConnectorRoute(
            connector: connector,
            model: { @Sendable in
                guard await session.isActive else { return nil }
                return await settings.selectedModel(for: id)
            },
            isReady: connectorReadiness(registry: registry, connectorID: id, session: session)
        )
    }

    /// The connector tier's availability predicate: the SELECTED connector's own
    /// ``ConnectorStatus/isReady``.
    ///
    /// Never `AssistantAvailability` / `AssistantAvailabilityProbe` — those describe
    /// Apple Intelligence, and a connector is precisely the thing that still works on
    /// a Mac which cannot run it at all. A cancelled session refuses BEFORE the probe,
    /// so the outgoing graph spends no round-trip after a profile switch.
    static func connectorReadiness(
        registry: ConnectorRegistry,
        connectorID: String,
        session: ConnectorSession
    ) -> @Sendable () async -> Bool {
        { @Sendable in
            guard await session.isActive else { return false }
            return await registry.probe(id: connectorID)?.isReady ?? false
        }
    }

    /// The library half of a connector prompt. ``ConnectorPromptContext/requestText``
    /// is ignored by the parser and replaced with the listener's own text, exactly as
    /// `FMAssistantBackend.contextProvider` works.
    ///
    /// The genre vocabulary is read UNCAPPED. `ConnectorPromptBuilder` caps what the
    /// prompt CARRIES (64), but the parser validates the provider's ANSWER against
    /// this list in full — so handing it the on-device tier's already-bounded 40 would
    /// reject genres the library really has.
    static func connectorContext(
        repository: TrackRepository,
        context: AssistantContextCache,
        profileId: Int64
    ) -> @Sendable () async -> ConnectorPromptContext {
        { @Sendable in
            let library = await context.context(profileId: profileId)
            let vocabulary = await (try? repository.distinctGenres(profileId: profileId).genres) ?? []
            return ConnectorPromptContext(
                requestText: "",
                genreNames: vocabulary,
                artistNames: library.artists,
                summary: library.summary
            )
        }
    }

    /// Reads one connector's API key from the Keychain at CALL time.
    ///
    /// A missing key throws, which both API-key connectors map to
    /// ``ConnectorFailure/unconfigured`` and raise BEFORE any request — so an
    /// unconfigured provider costs zero round-trips, which the registry probe relies
    /// on. Reading at call time rather than here is what lets a key entered in
    /// Preferences work without a relaunch.
    private static func connectorAPIKey(
        _ store: some SecretStore,
        for connectorID: String
    ) -> @Sendable () async throws -> String {
        let service = ConnectorSecretService.name(forConnectorID: connectorID)
        let account = connectorAPIKeyAccount
        return { @Sendable in try await store.require(service: service, account: account) }
    }

    /// Checks a credential that has NOT been saved yet — what the Intelligence
    /// pane's setup sheet asks when the listener presses Test or Validate.
    ///
    /// It lives in the composition root rather than beside the sheet because
    /// transport construction does: `scripts/check-ai-network-boundary.sh` scans
    /// every `macOS/Sources/Preferences/Intelligence*` file for it, so the panes
    /// reach a provider only through a connector somebody else built. The registry's
    /// own instances cannot answer this question either — they resolve their
    /// credential from the Keychain at CALL time, so they would test the very value
    /// being replaced.
    ///
    /// A connector this shell has no constructor for answers
    /// ``ConnectorStatus/unconfigured``: honestly "nothing was checked" rather than
    /// a fabricated verdict.
    ///
    /// - Parameter secret: The OPTIONAL second credential some connectors accept
    ///   alongside `draft` — today only Ollama's Cloud key. Empty means "none",
    ///   which for Ollama is a valid, fully-configured state rather than a gap.
    static func draftProbe(connectorID: String, draft: String, secret: String = "") async -> ConnectorStatus {
        let transport = URLSessionTransport()
        switch connectorID {
        case ollamaConnectorID:
            // A blank address is not unconfigured — it MEANS the stock one, and a
            // blank key is not unconfigured either: self-hosted servers have none.
            let key = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            // Built through a named `@Sendable` closure and only then made
            // optional: Swift infers a NON-`@Sendable` function type for a closure
            // literal inside a `?:`, which the parameter refuses.
            let resolve: @Sendable () async throws -> String = { key }
            let keyProvider: (@Sendable () async throws -> String)? = key.isEmpty ? nil : resolve
            return await OllamaConnector(host: ollamaHost(draft), apiKey: keyProvider, transport: transport).probe()
        case AnthropicConnector.connectorID:
            guard !draft.isEmpty else { return .unconfigured }
            return await AnthropicConnector(auth: .apiKey(provider: { draft }), transport: transport).probe()
        case openAIConnectorID:
            guard !draft.isEmpty else { return .unconfigured }
            return await OpenAIConnector(apiKey: { draft }, transport: transport).probe()
        default:
            return .unconfigured
        }
    }

    /// The listener's Ollama host, or the connector's stock address.
    ///
    /// A blank or unparseable entry degrades to the default rather than to a dead
    /// route: the setting stores what was TYPED, so a half-finished host round-trips
    /// and validation belongs here, at the point one is turned into a URL.
    static func ollamaHost(_ raw: String?) -> URL {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              let url = URL(string: trimmed), url.scheme != nil, url.host != nil
        else { return OllamaConnector.defaultHost }
        return url
    }

    /// The `disabledReason` token a connector registers with, or `nil` when it is
    /// live. Reads the connector's OWN determination rather than restating it, so
    /// flipping that determination flips the registry entry with it.
    private static func disabledReason(of status: ConnectorStatus) -> String? {
        guard case let .disabled(reason) = status else { return nil }
        return reason
    }
}

#if MACAMP_EXTERNAL_OAUTH
    // `AIConnectorKitOAuth` ships neither conformance and `ConnectorRegistry` requires
    // one, so both are declared here — retroactively, and only in the build that links
    // the product at all.

    extension ClaudeSubscriptionConnector: @retroactive ConnectorProbing {
        /// Not-signed-in is answered WITHOUT a refresh or a request: the default probe
        /// would spend a store read and a token decode to learn what ``isSignedIn()``
        /// already knows, and an unconfigured connector must cost nothing.
        public func probe() async -> ConnectorStatus {
            guard await isSignedIn() else { return .unconfigured }
            return await probe(deadlineSeconds: ConnectorProbe.deadlineSeconds)
        }
    }

    extension ChatGPTConnector: @retroactive ConnectorProbing {
        /// The same cheap gate `ClaudeSubscriptionConnector` uses, and now for the
        /// same reason: since the 2026-08-24 flip this connector registers LIVE, so
        /// the default probe would spend a real HTTP round-trip on a Mac that was
        /// never signed in — a timeout on every appearance of the Intelligence pane.
        public func probe() async -> ConnectorStatus {
            guard await isSignedIn() else { return .unconfigured }
            return await probe(deadlineSeconds: ConnectorProbe.deadlineSeconds)
        }
    }

    /// The process-wide subscription stacks.
    ///
    /// `static let` so each engine is created exactly once, lazily and atomically —
    /// see ``AppEnvironment/makeConnectorRegistry(settings:)`` for why sharing one
    /// engine per provider is not optional.
    enum ExternalOAuthStacks {
        /// Engine, login flow and connector, handed out together because they are only
        /// correct together. Todo 15's sign-in sheet presents this same stack.
        static let claude = ExternalOAuthComposition.makeClaudeStack()

        /// The same three pieces for ChatGPT. The sign-in sheet must present THIS
        /// stack: a second engine over the same Keychain slot would seed a credential
        /// the registry's connector never reads.
        static let chatGPT = ExternalOAuthComposition.makeChatGPTStack()
    }
#endif
