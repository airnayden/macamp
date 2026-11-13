// AppEnvironment+AI — the gated local-AI object graph.
//
// "Zero cost when off" is enforced by CONSTRUCTION, not by early returns scattered
// through the services: with the master toggle off ``AppEnvironment/ai`` is `nil`,
// so no assistant, no mix generator, no analysis pass and no repository exists to
// read the database or schedule anything. Nothing has to remember to check a flag,
// because there is nothing there to check it.
//
// Turning the toggle back on rebuilds the graph in place — no relaunch. The trigger
// is `withObservationTracking`, the same event-driven, self-re-arming shape
// ``observeKaraokeReadiness()`` uses; there is no timer and no polling anywhere in
// this feature.
//
// SWITCHING OFF NEVER DELETES ANYTHING. Playlists this feature already materialised
// are ordinary `playlist` rows with a `generatedPlaylist` satellite; tearing the
// graph down simply stops anything from touching them, and the sidebar keeps
// listing them through the ordinary playlist query. That disposition is a recorded
// product decision, not an oversight.
//
// FoundationModels appears ONLY inside the `#if canImport` + `if #available`
// island, exactly as `AssistantAvailabilityProbe` does. On an SDK without the
// framework the symbol does not exist at all, so the composition falls through to
// the always-available `HeuristicQueryParser` tier and the app still builds.
//
// ── PROVIDER CONNECTORS ────────────────────────────────────────────────────────
//
// A selected connector is expressed by BUILDING DIFFERENT CONFORMERS, never by
// mutating live ones — `ConnectorQueryParser` and friends are `struct`s with no
// mutable state for exactly that reason. So a provider, model or host change is a
// change to the graph's SHAPE, and ``observeIntelligenceToggle(settings:)`` tracks
// those keys alongside the master toggle so selecting one rebuilds in place. That is
// what lets `IntelligencePreferencesPane` keep its no-`.onChange` contract: the
// binding alone is the trigger.
//
// Selection, registration and credential plumbing live in
// `AppEnvironment+Connectors.swift`, including why connector settings are APP-WIDE
// rather than per-profile.
import AIConnectorBridge
import AIConnectorKit
import Decoding
import Foundation
import Metadata
import Observation
import Persistence
import Services
import ViewModels

extension AppEnvironment {
    /// Every AI service the shell exposes, built as one unit or not at all.
    struct AIStack {
        /// The in-memory proposal queue. Never persisted.
        let proposals: ProposalStore
        /// Turns listener requests into reviewable proposals.
        let assistant: AssistantViewModel
        /// Materialised auto-mixes with lazy TTL refresh (no timers).
        let generatedPlaylists: GeneratedPlaylistService
        /// The opt-in audio-feature pass. Never auto-starts, and — alone in this
        /// stack — SURVIVES a profile switch: `trackAudioFeature` has no `profileId`,
        /// so a running pass is analysing the same files whoever is listening. See
        /// ``rescopeAI(settings:)``.
        let audioAnalysis: AudioAnalysisViewModel
        /// Writes the listening narrative behind the Stats insights card. Always a
        /// ``FallbackInsightNarrating``, so it can never fail — see
        /// ``makeInsightNarrator(connector:)``.
        let narrator: any InsightNarrating
        /// The connectors THIS BUILD offers, in picker order. Carried on the stack so
        /// the Intelligence pane reads the same registry the ladder routes through
        /// rather than building a second one that could disagree with it.
        let connectors: ConnectorRegistry
        /// Stops this build's connector route the moment the stack is replaced.
        let connectorSession: ConnectorSession
        /// The multi-turn conversation over the listener's own library. A NEW surface
        /// beside the single-shot ladder, never a replacement for it — see
        /// `AppEnvironment+LibraryChat.swift`.
        let chat: LibraryChatViewModel
        /// The registry the loopback MCP server publishes at the `.external` tier.
        /// A SECOND toolbox beside the chat's, over the same ``ProposalStore``, so a
        /// proposal an outside agent files lands in the running app's review queue
        /// while `chat.drainFiledProposals` stays about chat turns alone.
        let externalToolbox: LibraryToolbox
        /// The same registry plus the four control tools, published only while
        /// `AppSettings.externalAccessControlEnabled` is on. Chosen between at CALL
        /// time by ``AppEnvironment/currentExternalToolbox`` — the transport is
        /// stateless, so the published list must track the switch without a
        /// reconnect.
        let externalControlToolbox: LibraryToolbox
    }

    /// Builds the AI graph, or `nil` when the master toggle is off.
    ///
    /// - Parameter profileId: the active profile at build time. A profile switch
    ///   rebuilds the graph through ``rescopeAI(settings:)`` — the genre vocabulary
    ///   handed to the parser is profile-scoped, and re-reading it lazily would need a
    ///   main-actor hop from inside a nonisolated async closure.
    /// - Parameter analysis: an already-running audio-feature pass to adopt instead of
    ///   building a fresh one. Only a profile switch passes it.
    /// - Parameter seams: the two things the graph is built over but does not own.
    static func makeAI(
        settings: AppSettings,
        database: AppDatabase,
        profileId: Int64,
        seams: AIStackSeams,
        carryingOver analysis: AudioAnalysisViewModel? = nil
    ) -> AIStack? {
        guard settings.intelligenceEnabled else { return nil }
        let mixGenerator = MixGeneratorService(database)
        let proposals = ProposalStore()
        let external = makeExternalToolboxes(
            database: database,
            profileId: profileId,
            proposals: proposals,
            playback: seams.playback
        )
        let registry = makeConnectorRegistry(settings: settings)
        let session = ConnectorSession()
        let backends = makeAssistantBackends(
            settings: settings,
            database: database,
            profileId: profileId,
            registry: registry,
            session: session
        )
        return AIStack(
            proposals: proposals,
            assistant: makeAssistant(
                settings: settings,
                database: database,
                proposals: proposals,
                backends: backends,
                mixGenerator: mixGenerator
            ),
            generatedPlaylists: GeneratedPlaylistService(
                database,
                generator: mixGenerator,
                aiSettings: settings
            ),
            audioAnalysis: analysis ?? makeAudioAnalysis(database: database),
            // The SAME narration conformer the assistant stack carries, so one
            // composition decides which tier narrates and the Stats card benefits
            // from a selected connector without a second selection rule.
            narrator: makeInsightNarrator(connector: backends.narrating),
            connectors: registry,
            connectorSession: session,
            chat: makeLibraryChat(
                settings: settings,
                composition: ChatComposition(
                    database: database,
                    profileId: profileId,
                    proposals: proposals,
                    playback: seams.playback
                ),
                connectors: seams.connectorContext(registry: registry, session: session)
            ),
            externalToolbox: external.reading,
            externalControlToolbox: external.controlling
        )
    }

    /// The opt-in audio-feature pass, built fresh.
    ///
    /// Extracted from ``makeAI`` so that function stays inside SwiftLint's
    /// `function_body_length` ceiling; the construction itself is unchanged.
    static func makeAudioAnalysis(database: AppDatabase) -> AudioAnalysisViewModel {
        AudioAnalysisViewModel(
            service: AudioAnalysisService(
                database: database,
                extractor: AudioFeatureExtractor(decoderProvider: SFBDecoderProvider())
            ),
            database: database
        )
    }

    /// The natural-language ladder: the heuristic tier always, the FoundationModels
    /// tier only when the SDK carries the framework AND the OS is new enough, and the
    /// connector tier only when the listener selected a connector this build offers.
    ///
    /// With nothing selected the returned stack is byte-for-byte the pre-connector
    /// one — `connectorParser` stays `nil`, so the ladder never even consults
    /// `connectorAvailability` and the local-only default makes zero network calls.
    static func makeAssistantBackends(
        settings: AppSettings,
        database: AppDatabase,
        profileId: Int64,
        registry: ConnectorRegistry,
        session: ConnectorSession
    ) -> AssistantBackendStack {
        #if DEBUG
            // The hermetic XCUITest fixture library carries no genre and no year, so the
            // real parser tiers correctly match nothing. See `AssistantUITestSeam`.
            if let fakeParser = AssistantUITestSeam.fakeParser {
                return AssistantBackendStack(fallbackParser: fakeParser)
            }
        #endif
        let repository = TrackRepository(database)
        let context = makeAssistantContextCache(database: database, repository: repository)
        var stack = AssistantBackendStack(
            fallbackParser: HeuristicQueryParser(
                knownGenres: { try await repository.distinctGenres(profileId: profileId).genres }
            )
        )
        #if canImport(FoundationModels)
            // DEPRECATED: the Apple Intelligence tier is retired (see
            // `AppleIntelligenceRetirement`); this block is dead code until it is deleted.
            if #available(macOS 26, iOS 26, *), !AppleIntelligenceRetirement.isRetired {
                stack.modelParser = FMAssistantBackend(
                    contextProvider: { await context.context(profileId: profileId) }
                )
                stack.naming = FMPlaylistNaming()
            }
        #endif
        guard let route = connectorRoute(settings: settings, registry: registry, session: session) else {
            return stack
        }
        stack.connectorParser = ConnectorQueryParser(
            connector: route.connector,
            model: route.model,
            contextProvider: connectorContext(repository: repository, context: context, profileId: profileId)
        )
        stack.connectorAvailability = route.isReady
        stack.naming = ConnectorNamer(connector: route.connector, model: route.model)
        stack.narrating = ConnectorNarrator(connector: route.connector, model: route.model)
        return stack
    }

    /// The bounded prompt context, memoised per `(profile, digest version, hour)`.
    ///
    /// The genre vocabulary is the model's allowed answer set, so it comes from the
    /// library. Artists and the free-text summary come from the profile's
    /// ``ListeningDigest`` — the aggregate Todo 17 recorded as missing, which the v15
    /// statistics pipeline now measures — and a digest is a full history scan, so it
    /// is cached rather than rebuilt for every keystroke-driven parse.
    static func makeAssistantContextCache(
        database: AppDatabase,
        repository: TrackRepository
    ) -> AssistantContextCache {
        AssistantContextCache(
            genres: { profileId in
                await (try? repository.distinctGenres(profileId: profileId).genres) ?? []
            },
            digests: ListeningDigestBuilder(database)
        )
    }
}

// MARK: - Live toggle plumbing

extension AppEnvironment {
    /// Builds the AI graph for `settings` and keeps it in step with the master toggle.
    ///
    /// Called once from ``live(settings:)``; tests call it directly on a
    /// ``preview()`` environment to drive the toggle without a relaunch.
    func connectAI(settings: AppSettings) {
        connectMCPTools(settings: settings)
        rebuildAI(settings: settings)
        observeIntelligenceToggle(settings: settings)
        observeProfileSwitch(settings: settings)
        connectExternalAccess(settings: settings)
    }

    /// The seams every graph is built over. Both outlive it, so both are read
    /// through this rather than stored on the stack that gets replaced.
    var aiStackSeams: AIStackSeams {
        AIStackSeams(
            playback: playbackControl,
            externalTools: { [weak self] in self?.mcpTools?.tools ?? [] }
        )
    }

    /// Constructs or tears down the graph to match the master toggle and the current
    /// connector selection.
    ///
    /// Switching OFF must leave nothing behind, including a running analysis pass, so
    /// this path deliberately carries nothing over — that is ``rescopeAI(settings:)``'s
    /// job, and only for a profile switch.
    func rebuildAI(settings: AppSettings) {
        intelligence?.connectorSession.cancel()
        intelligence?.chat.cancelInFlight()
        intelligence = Self.makeAI(
            settings: settings,
            database: database,
            profileId: profileService.activeProfile.id ?? ProfileRecord.guestID,
            seams: aiStackSeams
        )
        handleAIGraphRebuilt()
    }

    /// Rebuilds the graph around a NEW active profile.
    ///
    /// Everything profile-scoped is replaced — a fresh ``ProposalStore``, an assistant
    /// reading the incoming profile's genre vocabulary, a generated-playlist service
    /// scoped to it. The audio-analysis pass is CARRIED OVER instead, because dropping
    /// its view model would deallocate the service whose run loop holds only a `weak
    /// self`, silently ending a pass that has nothing to do with profiles.
    ///
    /// The outgoing ``ConnectorSession`` is cancelled FIRST, so a connector request
    /// the previous listener started performs no further provider work. Connector
    /// SETTINGS are app-wide and survive untouched — see this file's header.
    func rescopeAI(settings: AppSettings) {
        intelligence?.connectorSession.cancel()
        intelligence?.chat.cancelInFlight()
        intelligence = Self.makeAI(
            settings: settings,
            database: database,
            profileId: profileService.activeProfile.id ?? ProfileRecord.guestID,
            seams: aiStackSeams,
            carryingOver: intelligence?.audioAnalysis
        )
        handleAIGraphRebuilt()
    }

    /// Re-arms itself on every change, so the graph tracks the toggle for the whole
    /// process lifetime. `onChange` fires BEFORE the write lands, hence the main-actor
    /// hop before re-reading.
    private func observeIntelligenceToggle(settings: AppSettings) {
        withObservationTracking {
            _ = settings.intelligenceEnabled
            // Connector routing is graph SHAPE, not state inside the graph, so it is
            // tracked here rather than pushed from the pane — which is what preserves
            // `IntelligencePreferencesPane`'s no-`.onChange` contract.
            //
            // `selectedConnectorModels` is read WHOLE rather than through
            // `selectedModel(for:)`: the dictionary is the single stored property
            // `@Observable` instruments, and reading it covers every model change —
            // including one made before its connector is selected.
            _ = settings.selectedConnectorID
            _ = settings.selectedConnectorModels
            _ = settings.ollamaHost
            // The playback grant is graph SHAPE too, and unavoidably so: a
            // FoundationModels session attaches its tools at `init`, so the only way
            // a flipped switch can reach a conversation is a rebuilt one.
            _ = settings.assistantPlaybackControlEnabled
            // Same reason one tier up, both records — see `AppSettings.webSuggestionsGrant`.
            _ = settings.webSuggestionsGrant
        } onChange: { [weak self, weak settings] in
            Task { @MainActor in
                guard let self, let settings else { return }
                self.rebuildAI(settings: settings)
                self.observeIntelligenceToggle(settings: settings)
            }
        }
    }

    /// Rebuilds the graph for the incoming profile on a real profile switch.
    ///
    /// `onActiveProfileChanged` is a single-owner slot ``wireProfileSwitch(environment:)``
    /// already claimed from `init`, so this CHAINS after it — and running LAST is what
    /// makes it correct, because the orchestrator's `rescope` re-points every
    /// profile-owned reader first.
    ///
    /// Replacing the whole ``AIStack`` is also what resets the in-memory
    /// ``ProposalStore``, so the incoming profile can never see proposals the outgoing
    /// one left pending. Already-materialised mixes are untouched: they are ordinary
    /// `playlist` rows carrying their own `profileId`.
    private func observeProfileSwitch(settings: AppSettings) {
        let previous = profileService.onActiveProfileChanged
        profileService.onActiveProfileChanged = { [weak self, weak settings] profile in
            previous?(profile)
            guard let self, let settings else { return }
            rescopeAI(settings: settings)
        }
    }
}
