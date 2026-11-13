// AppEnvironment+WebSuggestions — what the web-suggestions grant contributes to a
// CLOUD conversation, and nothing else.
//
// ── TWO RECORDS, READ AS A CONJUNCTION, NEVER DERIVED FROM EACH OTHER ────────
//
// `AppSettings.webSuggestionsEnabled` is the switch; `webSuggestionsConsented` is
// the disclosure. ``AppSettings/webSuggestionsGrant`` below is the ONE place they
// are combined, and it reads both — a switch flipped by a listener who never saw the
// disclosure is not consent, and `WebSuggestionsSectionModel` is built so that state
// is reachable (it writes the switch and offers the sheet through separate paths).
// Deriving either record from the other here would quietly cancel that whole design.
//
// ── THE GRANT IS CLOUD-ONLY, ON BOTH HALVES ─────────────────────────────────
//
// Neither half may reach the on-device tier. ``makeChatEngine`` hands the supply to
// the connector route alone, and ``suggestionEnricher(settings:registry:)`` answers
// `nil` unless the route that will actually answer is `.ready(.connector)` — so an
// Apple Intelligence conversation publishes no web tool AND performs no link
// lookup. That is a consent claim, not an optimisation: the on-device tier's whole
// promise is that nothing leaves the Mac, and a "helpful" link resolution behind it
// would make the banner a false statement.
//
// ── COMPOSITION, NOT CONSTRUCTION ───────────────────────────────────────────
//
// Everything that speaks HTTP here is a KIT type — ``WebSearchTool``,
// ``YouTubeLinkResolver``, ``URLSessionTransport`` — assembled exactly as
// `AppEnvironment+Connectors.swift` assembles the connector registry. No
// `URLSession` is constructed in this file, and none may be: the transport home is
// `AIConnectorKit/Sources/AIConnectorKit/` (`scripts/check-ai-network-boundary.sh`).
//
// ── THE TWO KEYS ARE OPTIONAL, AND ARE READ AT CALL TIME ────────────────────
//
// Both tools work keyless. The providers below are closures over the Keychain, so a
// key pasted in Preferences reaches the next lookup with no relaunch, and a missing
// one is the expected state rather than a failure: ``WebSearchTool`` treats `nil` as
// "send a keyless request", and ``YouTubeLinkResolver`` treats a throwing provider
// as "take the keyless branch". The slots come from ``WebSuggestionsKeySlot`` so
// this composition reads exactly where that pane writes.
import AIConnectorKit
import Foundation
import Services

extension AppSettings {
    /// The web-suggestions grant: the switch AND the disclosure, as one value.
    ///
    /// The two reads are DELIBERATELY not written as `a && b`. This property is
    /// what `observeIntelligenceToggle` reads inside `withObservationTracking`, and
    /// `&&` short-circuits — with the switch off, the disclosure would never be
    /// touched, so accepting it would register no dependency and the graph would not
    /// rebuild. Reading both unconditionally is what makes either record's flip
    /// reach the next conversation.
    var webSuggestionsGrant: Bool {
        let isEnabled = webSuggestionsEnabled
        let isConsented = webSuggestionsConsented
        return isEnabled && isConsented
    }
}

extension AppEnvironment {
    /// What one cloud conversation is published with on top of its library tools.
    ///
    /// The two halves travel together because they are granted together and their
    /// failure modes are symmetric: instructing a model to search the web without
    /// the tool is the ungranted-tool hallucination `LibraryChatInstructions`
    /// documents, and publishing the tool without the instruction line leaves it
    /// unused. One value, one gate, both call sites fed from it.
    struct WebSuggestionsSupply {
        /// MacAMP's own non-library tools for this turn. Empty, or exactly
        /// ``WebSearchTool``.
        let tools: [AITool]
        /// Whether the model may draw on what it already knows about music.
        /// Follows the SETTING, never the tool list — see
        /// `LibraryChatInstructions`' header for why the two flags are independent.
        let musicKnowledgeEnabled: Bool

        /// The ungranted supply: no tool, no knowledge line. What every non-cloud
        /// caller and every ungranted cloud caller gets.
        static let none = WebSuggestionsSupply(tools: [], musicKnowledgeEnabled: false)
    }

    /// The grant, resolved for one engine mint.
    static func webSuggestionsSupply(settings: AppSettings) -> WebSuggestionsSupply {
        guard settings.webSuggestionsGrant else { return .none }
        return WebSuggestionsSupply(
            tools: [WebSearchTool(apiKeyProvider: optionalSecret(for: .search)).tool],
            musicKnowledgeEnabled: true
        )
    }

    /// Resolves video links for a landed row's suggestions, or `nil` when nobody
    /// may look one up.
    ///
    /// `nil` — rather than a closure that returns its input — is the honest answer,
    /// because `LibraryChatViewModel` schedules NOTHING when the enricher is absent:
    /// no task, no generation bookkeeping, no rewrite of a row it would only write
    /// back unchanged. The two refusals it encodes are the two this feature has:
    /// the listener did not grant the feature, and the tier that answers is the
    /// on-device one.
    static func suggestionEnricher(
        settings: AppSettings,
        registry: ConnectorRegistry
    ) -> (@Sendable ([AssistantChatSuggestion]) async -> [AssistantChatSuggestion])? {
        #if DEBUG
            // BEFORE the gate, for the same reason `makeChatEngine` substitutes its
            // connector before the routing switch: a UI-test process resolves
            // `.ready(.appleIntelligence)`, so the cloud-only arm below is unreachable
            // there and the video half of the suggestion surface would be untestable.
            // Compiled out of Release, and doubly gated inside the seam.
            if let scripted = ScriptedChatUITestSeam.scriptedSuggestionEnricher() { return scripted }
        #endif
        guard settings.webSuggestionsGrant,
              isConnectorChatRoute(settings: settings, registry: registry)
        else { return nil }
        let resolver = makeYouTubeLinkResolver()
        let proposer = videoLinkProposer(settings: settings, registry: registry)
        return { @Sendable suggestions in
            await Self.enriched(suggestions, using: resolver, proposer: proposer)
        }
    }

    /// The provider that answers this conversation, ready to be asked for video
    /// ids — or `nil` when the route resolves to anything but a connector.
    ///
    /// Reads the SAME routing function the enricher's own gate and `makeChatEngine`
    /// read, so "which provider is answering" is decided once. The on-device tier
    /// never reaches here, which keeps the cloud-only promise the disclosure makes.
    static func videoLinkProposer(
        settings: AppSettings,
        registry: ConnectorRegistry
    ) -> ModelVideoLinkProposer? {
        guard case let .ready(.connector(id, _, model)) = chatAvailability(settings: settings, registry: registry),
              let connector = registry.connector(id: id)
        else {
            return nil
        }
        return ModelVideoLinkProposer(connector: connector, model: model)
    }
}

// MARK: - The gate

private extension AppEnvironment {
    /// Whether a CONNECTOR is the tier that would answer right now.
    ///
    /// Asked through ``chatAvailability(settings:registry:)`` — the same routing
    /// function ``makeChatEngine`` switches over — so "the enricher is cloud-only"
    /// and "the web tool is cloud-only" can never be decided by two rules that
    /// disagree.
    static func isConnectorChatRoute(settings: AppSettings, registry: ConnectorRegistry) -> Bool {
        if case .ready(.connector) = chatAvailability(settings: settings, registry: registry) { return true }
        return false
    }
}

// MARK: - Resolving

/// `internal`, not `private`: `ModelVideoLinkProposerTests` drives the model-first
/// ordering through these directly — how many searches a batch spends is the whole
/// point of the chain, and a rendered row cannot be inspected after the fact. Same
/// widening, for the same reason, as `LibraryChatMessageRow.activityText`.
extension AppEnvironment {
    /// `suggestions`, each carrying the link resolved for its own position.
    ///
    /// Every returned link passes ``YouTubeLinkResolver/validatedWatchURL(_:)``
    /// again on the way out. The resolver already answers with that function's own
    /// output, so this cannot change a link — it makes the WRITER gate structural
    /// rather than inherited, which is what the one-validator rule asks for.
    ///
    /// A batch that answered a different length is discarded whole: a positional
    /// merge over a list that changed size pairs the wrong rows, and
    /// `LibraryChatViewModel` would reject it anyway.
    static func enriched(
        _ suggestions: [AssistantChatSuggestion],
        using resolver: YouTubeLinkResolver,
        proposer: ModelVideoLinkProposer?
    ) async -> [AssistantChatSuggestion] {
        let requests = suggestions.map {
            YouTubeLinkResolver.Request(title: $0.title, artist: $0.artist)
        }
        var videos = await proposed(for: suggestions, requests: requests, using: resolver, proposer: proposer)
        // The search provider is spent ONLY on what the model could not supply —
        // which is what keeps a long answer inside its daily cap.
        let pending = videos.indices.filter { videos[$0] == nil }
        if pending.isEmpty == false {
            let searched = await resolver.resolve(pending.map { requests[$0] })
            if searched.count == pending.count {
                for (slot, video) in zip(pending, searched) {
                    videos[slot] = video
                }
            }
        }
        guard videos.count == suggestions.count else { return suggestions }
        return zip(suggestions, videos).map { suggestion, video in
            AssistantChatSuggestion(
                title: suggestion.title,
                artist: suggestion.artist,
                videoURL: video.flatMap { YouTubeLinkResolver.validatedWatchURL($0.url) }
            )
        }
    }

    /// The slots the PROVIDER's own ids filled, or all-empty when there is no
    /// provider to ask. Every id still passes the resolver's full gate.
    static func proposed(
        for suggestions: [AssistantChatSuggestion],
        requests: [YouTubeLinkResolver.Request],
        using resolver: YouTubeLinkResolver,
        proposer: ModelVideoLinkProposer?
    ) async -> [YouTubeLinkResolver.ResolvedVideo?] {
        guard let proposer else {
            return Array(repeating: nil, count: suggestions.count)
        }
        let identifiers = await proposer.proposedIDs(for: suggestions)
        return await resolver.verify(requests, proposedIDs: identifiers)
    }

    static func makeYouTubeLinkResolver() -> YouTubeLinkResolver {
        YouTubeLinkResolver(
            transport: URLSessionTransport(),
            youTubeAPIKey: requiredSecret(for: .video),
            searchAPIKey: requiredSecret(for: .search)
        )
    }
}

// MARK: - The two optional keys

private extension AppEnvironment {
    /// Reads `slot`'s key, or `nil` when none is stored. For a caller that treats
    /// an absent key as "go keyless" rather than as a failure.
    static func optionalSecret(for slot: WebSuggestionsKeySlot) -> @Sendable () async -> String? {
        let store = KeychainSecretStore()
        let service = slot.service
        let account = connectorAPIKeyAccount
        return { @Sendable in await (try? store.get(service: service, account: account)) ?? nil }
    }

    /// The same read, in the throwing shape ``YouTubeLinkResolver`` takes. A throw
    /// selects its keyless branch, so "no key" and "Keychain locked" both degrade
    /// to the mode that needs neither.
    static func requiredSecret(for slot: WebSuggestionsKeySlot) -> @Sendable () async throws -> String {
        let store = KeychainSecretStore()
        let service = slot.service
        let account = connectorAPIKeyAccount
        return { @Sendable in try await store.require(service: service, account: account) }
    }
}
