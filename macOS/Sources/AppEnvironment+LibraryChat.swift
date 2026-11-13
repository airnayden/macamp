// AppEnvironment+LibraryChat — the chat tier's composition.
//
// Three things live here and nowhere else:
//
//   1. The real ``LibraryToolbox``, built over real repositories, scoped to the
//      ACTIVE PROFILE. Every visibility rule the toolbox enforces is derived from
//      that one `profileId` (W1 composes `LibraryVisibility` inside the compiler), so
//      there is no second definition of "the tracks this profile can see" here.
//   2. The engine factory the chat view model calls lazily — routed by the SAME
//      `selectedConnectorID` the Intelligence pane persists, and gated at the commit
//      point by the library-browsing consent record.
//   3. The `ToolboxProposalFiling` witness, over the shell's own `ProposalStore`.
//
// ── LIFETIME IS THE AI GRAPH'S ───────────────────────────────────────────────
//
// The toolbox, the filer and the view model are built inside ``makeAI`` and die with
// it. A master-toggle flip, a provider change, a model change and a profile switch
// all rebuild the graph, so none of them can leave a conversation running against a
// stale scope — and ``rebuildAI``/``rescopeAI`` cancel the outgoing turn explicitly
// beside the existing `ConnectorSession.cancel()`.
//
// ── FOUNDATIONMODELS STAYS INSIDE ITS ISLAND ─────────────────────────────────
//
// Exactly as `makeAssistantBackends` does: the SDK appears only inside
// `#if canImport` + `if #available`, and what escapes is a ``LibraryChatEngine`` —
// two closures with no availability of their own. On an SDK without the framework
// the on-device route reports `.osTooOld` and the surface says so.
//
// No `URLSession` appears here; every byte leaves through a connector.
import AIConnectorBridge
import AIConnectorKit
import Foundation
import Persistence
import Services
import ViewModels

extension AppEnvironment {
    /// The connector route's two halves as one value.
    ///
    /// A value type for the reason ``AssistantRepositoryStack`` is one: passing both
    /// separately puts every factory below at six arguments, past SwiftLint's
    /// `function_parameter_count` ceiling, and the pair really is one thing — the
    /// connectors this build offers, plus the switch that retires them.
    struct ConnectorContext {
        let registry: ConnectorRegistry
        let session: ConnectorSession
        /// The tools the listener's own MCP servers publish, read at ENGINE-MINT
        /// time rather than captured at graph-build time — the same discipline
        /// ``makeChatEngine(settings:toolbox:connectors:)`` already applies to the
        /// route itself, and here it is what lets a refreshed supply reach the next
        /// conversation without the graph having to be rebuilt around it.
        ///
        /// Defaulted to none so every call site that has no supply — the previews,
        /// every suite that is not about MCP — keeps the pre-MCP list exactly.
        let externalTools: @MainActor () -> [AITool]

        init(
            registry: ConnectorRegistry,
            session: ConnectorSession,
            externalTools: @escaping @MainActor () -> [AITool] = { [] }
        ) {
            self.registry = registry
            self.session = session
            self.externalTools = externalTools
        }
    }

    /// The profile-scoped halves a chat is composed over.
    ///
    /// A value type for the same reason ``ConnectorContext`` is one: without it
    /// ``makeLibraryChat(settings:composition:connectors:)`` sits at six arguments,
    /// past SwiftLint's `function_parameter_count` ceiling. These four really are
    /// one thing — the library this conversation reads, the profile it is scoped
    /// to, the queue it files offers into, and the player it may drive.
    struct ChatComposition {
        let database: AppDatabase
        let profileId: Int64
        let proposals: ProposalStore
        /// The playback seam, BEFORE the grant is applied. `makeLibraryChat` reads
        /// `AppSettings.assistantPlaybackControlEnabled` and passes it on or drops
        /// it, so the decision lives at exactly one call site.
        let playback: (any ToolboxPlaybackControlling)?
    }

    /// The chat view model, wired to its own toolbox and proposal witness.
    ///
    /// The filer does not escape: it is retained by the toolbox it fills and by the
    /// drain closure, both of which live exactly as long as the view model.
    static func makeLibraryChat(
        settings: AppSettings,
        composition: ChatComposition,
        connectors: ConnectorContext
    ) -> LibraryChatViewModel {
        let filer = LibraryChatProposalFiler(store: composition.proposals)
        let reads = LibraryChatPlaylistContextRecorder()
        let toolbox = makeLibraryToolbox(
            database: composition.database,
            profileId: composition.profileId,
            proposals: filer,
            playlistReads: reads,
            // The grant is applied HERE, by handing the seam over or not, because a
            // FoundationModels session attaches its tools at `init` and can never be
            // given or denied one afterwards. That is also why flipping the switch is
            // tracked as graph SHAPE in `observeIntelligenceToggle` — the conversation
            // has to be rebuilt for the change to mean anything.
            playback: settings.assistantPlaybackControlEnabled ? composition.playback : nil
        )
        return LibraryChatViewModel(
            makeEngine: { @MainActor in
                makeChatEngine(settings: settings, toolbox: toolbox, connectors: connectors)
            },
            drainFiledProposals: { @MainActor in filer.drain() },
            drainPlaylistReads: { @MainActor in reads.drain() },
            // Resolved once per graph, not per turn: the enricher is a function of
            // the grant and the tier, and both are graph SHAPE — flipping either
            // rebuilds the whole stack (`observeIntelligenceToggle`), which is the
            // only way a cached engine stops answering with the old wiring.
            suggestionEnricher: suggestionEnricher(settings: settings, registry: connectors.registry)
        )
    }

    /// The library registry, over real repositories, scoped to one profile — plus
    /// the four control tools when, and only when, `playback` is non-`nil`.
    ///
    /// `tracks` is the CONCRETE `TrackRepository` because W1's reads are
    /// concrete-extension APIs — the documented exception, not an oversight (W1 note 3).
    ///
    /// - Parameter playlistReads: Told which playlist `get_playlist` served. Defaulted
    ///   to none, so the MCP composition — which has no turn to attribute a read to —
    ///   keeps exactly the toolbox it built before. Installing it gates NOTHING: the
    ///   answer a model receives is byte-identical either way.
    static func makeLibraryToolbox(
        database: AppDatabase,
        profileId: Int64,
        proposals: any ToolboxProposalFiling,
        playlistReads: (any ToolboxPlaylistReadObserving)? = nil,
        playback: (any ToolboxPlaybackControlling)? = nil
    ) -> LibraryToolbox {
        LibraryToolbox(context: LibraryToolboxContext(
            tracks: TrackRepository(database),
            playlists: PlaylistRepository(database),
            digests: ListeningDigestBuilder(database),
            reader: ToolboxLibraryReader(database),
            proposals: proposals,
            playback: playback,
            profileId: profileId,
            playlistReadObserver: playlistReads
        ))
    }

    /// The tier that answers, or the reason there is none.
    ///
    /// Read at CALL time, not at graph-build time, so a listener who accepts the
    /// disclosure or finishes preparing the on-device model gets a conversation
    /// without leaving the pane.
    @MainActor
    static func makeChatEngine(
        settings: AppSettings,
        toolbox: LibraryToolbox,
        connectors: ConnectorContext
    ) -> Result<LibraryChatEngine, LibraryChatFailure> {
        #if DEBUG
            // BEFORE the switch, not inside its `.ready(.connector)` arm: in a UI-test
            // process `selectedConnectorID` is nil, so that arm is unreachable and a
            // substitution made there would never run. Everything below the connector
            // — the real tool loop, the real merged tools, the real filer — is
            // untouched; only the MODEL is scripted. See ``ScriptedChatUITestSeam``.
            if let scripted = ScriptedChatUITestSeam.connector() {
                return .success(connectorChatEngine(
                    connector: scripted,
                    model: ScriptedChatUITestSeam.model,
                    toolbox: toolbox,
                    connectors: connectors,
                    web: webSuggestionsSupply(settings: settings)
                ))
            }
        #endif
        switch chatAvailability(settings: settings, registry: connectors.registry) {
        case let .ready(.connector(id, _, model)):
            // Belt and braces behind the surface's own gate: `chatAvailability` has
            // already refused an unconsented provider, and this is still the single
            // commit point — the same discipline `IntelligenceConnectorConfigModel.save()`
            // applies to the payload disclosure.
            guard settings.hasLibraryBrowsingConsent(forConnectorID: id),
                  let connector = connectors.registry.connector(id: id) as? any ToolCallingConnector
            else { return .failure(.consentRequired) }
            return .success(connectorChatEngine(
                connector: connector,
                model: model,
                toolbox: toolbox,
                connectors: connectors,
                // ONLY on this arm. The on-device case below is deliberately not
                // offered a supply at all, so no future edit can hand it one by
                // forgetting a flag — see `AppEnvironment+WebSuggestions.swift`.
                web: webSuggestionsSupply(settings: settings)
            ))
        case .ready(.appleIntelligence):
            return onDeviceChatEngine(toolbox: toolbox, intelligenceEnabled: settings.intelligenceEnabled)
        case let .appleIntelligenceUnavailable(reason):
            return .failure(.unavailable(reason))
        case .intelligenceOff:
            return .failure(.unavailable(.intelligenceDisabled))
        case .consentRequired, .consentDeclined:
            return .failure(.consentRequired)
        case .providerCannotChat, .providerNeedsModel:
            return .failure(.answerFailed)
        }
    }

    /// The chat routing decision for the current settings, resolved against this
    /// build's registry. The surface reads the same function for its empty states.
    @MainActor
    static func chatAvailability(
        settings: AppSettings,
        registry: ConnectorRegistry,
        isConsentDeclined: Bool = false
    ) -> LibraryChatAvailability {
        LibraryChatRouting.availability(
            intelligenceEnabled: settings.intelligenceEnabled,
            selection: chatConnectorSelection(settings: settings, registry: registry),
            hasBrowsingConsent: settings.selectedConnectorID
                .map { settings.hasLibraryBrowsingConsent(forConnectorID: $0) } ?? false,
            isConsentDeclined: isConsentDeclined,
            appleIntelligence: AssistantAvailabilityProbe.current(
                intelligenceEnabled: settings.intelligenceEnabled
            )
        )
    }

    /// The resolved connector selection, or `nil` for the Apple Intelligence default.
    ///
    /// RESOLVED against the registry for the same reason `connectorRoute` resolves:
    /// an id no build registers degrades to the on-device default while the stored
    /// value is left untouched.
    @MainActor
    static func chatConnectorSelection(
        settings: AppSettings,
        registry: ConnectorRegistry
    ) -> LibraryChatConnectorSelection? {
        guard let id = settings.resolvedConnectorID(among: registry.ids),
              let descriptor = registry.descriptor(id: id) else { return nil }
        return LibraryChatConnectorSelection(
            id: id,
            displayName: descriptor.displayName,
            supportsToolCalling: registry.connector(id: id) is any ToolCallingConnector,
            model: settings.selectedModel(for: id)
        )
    }

    /// The cloud tier's configured conversation: the library's own tools first,
    /// MacAMP's own built-in tools next, the listener's MCP servers' last.
    ///
    /// Internal, and separate from the private `connectorChatEngine`, because
    /// ``LibraryChatEngine`` is two opaque closures — the merged list and the
    /// instructions it was built with cannot be read back through it. A wiring test
    /// asserting "every frozen name once and first, every external name namespaced,
    /// the web lines only once those tools really merged" needs the value that still
    /// carries both, so this is where the composition actually happens.
    ///
    /// - Parameter web: The web-suggestions grant. Defaulted to
    ///   ``WebSuggestionsSupply/none`` so every fixture that predates the feature —
    ///   and every caller that is not the connector route — composes exactly the
    ///   list it composed before.
    @MainActor
    static func makeConnectorChatEngine(
        connector: any ToolCallingConnector,
        model: String,
        toolbox: LibraryToolbox,
        connectors: ConnectorContext,
        web: WebSuggestionsSupply = .none
    ) -> ConnectorChatEngine {
        let external = connectors.externalTools()
        return ConnectorChatEngine(
            connector: connector,
            model: model,
            tools: LibraryChatToolMerge.merged(
                library: LibraryToolAdapter.aiTools(toolbox, profile: .cloud),
                builtIn: web.tools,
                external: external
            ),
            instructions: LibraryChatInstructions.text(
                locale: .current,
                profile: .cloud,
                canControlPlayback: toolbox.context.playback != nil,
                // Turned on by the presence of the tools themselves, never by the
                // setting that permits them: a model told to search the web with
                // tools it was not given is the ungranted-tool hallucination
                // `LibraryChatInstructions`' header documents. BOTH web-capable
                // lists count — reading `external` alone would grant `web_search`
                // without the line that tells the model how to use it.
                webWorkflowEnabled: (web.tools + external).isEmpty == false,
                // The listener's SETTING, not the tool list. See
                // `LibraryChatInstructions`' header for why these two are
                // independent gates rather than one.
                musicKnowledgeEnabled: web.musicKnowledgeEnabled
            )
        )
    }
}

// MARK: - The two tiers

private extension AppEnvironment {
    @MainActor
    static func connectorChatEngine(
        connector: any ToolCallingConnector,
        model: String,
        toolbox: LibraryToolbox,
        connectors: ConnectorContext,
        web: WebSuggestionsSupply
    ) -> LibraryChatEngine {
        let session = connectors.session
        let conversation = ConnectorChatConversation(
            engine: makeConnectorChatEngine(
                connector: connector,
                model: model,
                toolbox: toolbox,
                connectors: connectors,
                web: web
            ),
            isActive: { @Sendable in await session.isActive }
        )
        return conversation.engineValue
    }

    /// The on-device tier, or the availability reason it is not there.
    static func onDeviceChatEngine(
        toolbox: LibraryToolbox,
        intelligenceEnabled: Bool
    ) -> Result<LibraryChatEngine, LibraryChatFailure> {
        #if canImport(FoundationModels)
            if #available(macOS 26, iOS 26, *) {
                switch LibraryChatSession.make(toolbox: toolbox, intelligenceEnabled: intelligenceEnabled) {
                case let .success(chatSession):
                    return .success(LibraryChatEngine(
                        prewarm: { await chatSession.prewarm() },
                        send: { text in
                            let turn = try await chatSession.send(text)
                            return LibraryChatReply(turn: turn)
                        },
                        // The smaller on-device model is the one most likely to
                        // describe a playlist instead of filing one, so it opts in
                        // for the same reason the cloud tier does — see
                        // `ConnectorChatConversation.engineValue`.
                        supportsCorrectiveFollowUp: true
                    ))
                case let .failure(unavailable):
                    return .failure(.unavailable(unavailable.reason))
                }
            }
        #endif
        return .failure(.unavailable(.osTooOld))
    }
}
