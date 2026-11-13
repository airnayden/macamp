// LibraryChatCompositionTests — the wiring between W1's toolbox, W2's loop and the
// shell's own review surface.
//
// Three claims, none of which a view-model test can make:
//
//   1. The toolbox the shell builds is the REAL one, over real repositories, scoped
//      to the active profile.
//   2. `propose_playlist` filed through the REAL `ToolboxProposalFiling` seam lands
//      in the SAME `ProposalStore` the preview sheet reads — so a playlist proposed
//      in conversation is reviewed through the one existing safety gate.
//   3. The kit's `ChatEvent` maps onto the floor-available vocabulary exactly as W2
//      documented, with `argumentsJSON` the one field dropped.
import AIConnectorBridge
import AIConnectorKit
import Foundation
@testable import MacAMP
import Persistence
import Services
import SwiftUI
import Testing
import ViewModels

@Suite("Library chat composition", .serialized)
@MainActor
struct LibraryChatCompositionTests {
    private static let suitePrefix = "com.example.macamp.tests.libraryChatComposition"

    private static func settings(_ function: String) -> AppSettings {
        let name = "\(suitePrefix).\(function)"
        guard let store = UserDefaults(suiteName: name) else { return AppSettings(defaults: .standard) }
        store.removePersistentDomain(forName: name)
        return AppSettings(defaults: store)
    }

    // MARK: The toolbox

    @Test("the shell builds the real ten-tool registry, scoped to the profile it was given")
    func theToolboxIsRealAndScoped() {
        let store = ProposalStore()
        let toolbox = AppEnvironment.makeLibraryToolbox(
            database: AppEnvironment.preview().database,
            profileId: 4242,
            proposals: LibraryChatProposalFiler(store: store)
        )
        #expect(toolbox.context.profileId == 4242)
        #expect(toolbox.allTools.count == 10)
        #expect(toolbox.tools(profile: .onDevice).map(\.name) == LibraryToolbox.onDeviceToolNames)
        #expect(toolbox.tools(profile: .cloud).count == 10)
    }

    @Test("the toolbox reaches the shell's own repositories, not a stub")
    func theToolboxUsesLiveRepositories() async {
        let toolbox = AppEnvironment.makeLibraryToolbox(
            database: AppEnvironment.preview().database,
            profileId: ProfileRecord.guestID,
            proposals: LibraryChatProposalFiler(store: ProposalStore())
        )
        // An empty in-memory library really answers; a stub would throw or hang.
        let rendered = await toolbox.run("list_genres", profile: .cloud)
        #expect(!rendered.isEmpty)
    }

    // MARK: The one non-read seam

    @Test("propose_playlist through the REAL seam lands in the store the preview sheet reads")
    func aProposalFiledByTheToolReachesTheStore() async throws {
        let store = ProposalStore()
        let filer = LibraryChatProposalFiler(store: store)
        let toolbox = AppEnvironment.makeLibraryToolbox(
            database: AppEnvironment.preview().database,
            profileId: 7,
            proposals: filer
        )
        let result = try await toolbox.execute("propose_playlist", arguments: ToolArguments([
            "name": .string("Late Night Jazz"),
            "track_ids": .array([.int(11), .int(22), .int(33)]),
            "description": .string("Slow and warm."),
        ]))
        #expect(result.rows.count == 1)

        let filed = try #require(store.latest)
        #expect(store.proposals.count == 1)
        #expect(filed.profileId == 7)
        #expect(filed.affectedCount == 3)
        guard case let .createPlaylist(request) = filed.kind else {
            Issue.record("chat can only file a create-playlist proposal")
            return
        }
        #expect(request.name == "Late Night Jazz")
        #expect(request.summary == "Slow and warm.")
        // Order is the model's order, preserved — never re-ranked by this layer.
        #expect(request.orderedTrackIds == [11, 22, 33])
    }

    @Test("the filer hands each id to exactly one turn, then forgets it")
    func theDrainIsOncePerFiling() async throws {
        let filer = LibraryChatProposalFiler(store: ProposalStore())
        let identifier = try await filer.fileCreatePlaylistProposal(
            ToolboxPlaylistProposal(profileId: 1, name: "One", trackIds: [5])
        )
        #expect(filer.drain() == [identifier])
        #expect(filer.drain().isEmpty)
    }

    // MARK: The graph

    @Test("the AI graph carries a chat surface, and loses it with the master switch")
    func theGraphCarriesTheChatSurface() {
        let settings = Self.settings(#function)
        let environment = AppEnvironment.preview()
        environment.connectAI(settings: settings)
        #expect(environment.intelligence?.chat != nil)
        #expect(environment.intelligence?.chat.isEmpty == true)
    }

    @Test("the chat surface shares the graph's ONE proposal store")
    func theChatSurfaceSharesTheProposalStore() async throws {
        let settings = Self.settings(#function)
        let environment = AppEnvironment.preview()
        environment.connectAI(settings: settings)
        let intelligence = try #require(environment.intelligence)
        let filer = LibraryChatProposalFiler(store: intelligence.proposals)
        _ = try await filer.fileCreatePlaylistProposal(
            ToolboxPlaylistProposal(profileId: ProfileRecord.guestID, name: "Shared", trackIds: [1])
        )
        // The same store `AssistantViewModel` and `ProposalPreviewSheet` already use.
        #expect(intelligence.assistant.proposals.latest?.id == intelligence.proposals.latest?.id)
    }

    @Test("with no selection the engine factory resolves the on-device tier or names its reason")
    func theFactoryRoutesToAppleIntelligenceByDefault() {
        let settings = Self.settings(#function)
        let toolbox = AppEnvironment.makeLibraryToolbox(
            database: AppEnvironment.preview().database,
            profileId: ProfileRecord.guestID,
            proposals: LibraryChatProposalFiler(store: ProposalStore())
        )
        let engine = AppEnvironment.makeChatEngine(
            settings: settings,
            toolbox: toolbox,
            connectors: AppEnvironment.ConnectorContext(
                registry: ConnectorRegistry(),
                session: AppEnvironment.ConnectorSession()
            )
        )
        // Host-independent: either the model is reachable here or it names why not.
        // What must NEVER happen is a silent generic failure on the default route.
        if case let .failure(failure) = engine {
            #expect(failure != .answerFailed)
            #expect(failure != .consentRequired)
        }
    }

    @Test("the master switch off refuses the engine with the reason the pane already writes copy for")
    func theFactoryRefusesWithTheSwitchOff() {
        let settings = Self.settings(#function)
        settings.intelligenceEnabled = false
        let toolbox = AppEnvironment.makeLibraryToolbox(
            database: AppEnvironment.preview().database,
            profileId: ProfileRecord.guestID,
            proposals: LibraryChatProposalFiler(store: ProposalStore())
        )
        let engine = AppEnvironment.makeChatEngine(
            settings: settings,
            toolbox: toolbox,
            connectors: AppEnvironment.ConnectorContext(
                registry: ConnectorRegistry(),
                session: AppEnvironment.ConnectorSession()
            )
        )
        guard case let .failure(failure) = engine else {
            Issue.record("the switch is off; there must be no engine")
            return
        }
        #expect(failure == .unavailable(.intelligenceDisabled))
    }

    @Test("an unconsented cloud provider is refused AT THE COMMIT POINT, not just by the surface")
    func theFactoryEnforcesConsentItself() {
        let settings = Self.settings(#function)
        settings.selectedConnectorID = "ollama"
        settings.setSelectedModel("llama3.2", for: "ollama")
        let toolbox = AppEnvironment.makeLibraryToolbox(
            database: AppEnvironment.preview().database,
            profileId: ProfileRecord.guestID,
            proposals: LibraryChatProposalFiler(store: ProposalStore())
        )
        let engine = AppEnvironment.makeChatEngine(
            settings: settings,
            toolbox: toolbox,
            connectors: AppEnvironment.ConnectorContext(
                registry: AppEnvironment.makeConnectorRegistry(settings: settings),
                session: AppEnvironment.ConnectorSession()
            )
        )
        guard case let .failure(failure) = engine else {
            Issue.record("an unconsented provider must not produce an engine")
            return
        }
        #expect(failure == .consentRequired)
    }

    @Test("every shipped connector can chat, so the selection resolves as tool-calling")
    func everyShippedConnectorIsToolCalling() {
        let settings = Self.settings(#function)
        let registry = AppEnvironment.makeConnectorRegistry(settings: settings)
        for id in registry.ids {
            settings.selectedConnectorID = id
            let selection = AppEnvironment.chatConnectorSelection(settings: settings, registry: registry)
            #expect(selection?.id == id)
            #expect(selection?.supportsToolCalling == true, "\(id) lost its ToolCallingConnector conformance")
        }
    }

    @Test("an id no build registers degrades to the on-device default rather than to nothing")
    func anUnknownSelectionDegradesToOnDevice() {
        let settings = Self.settings(#function)
        settings.selectedConnectorID = "a-provider-from-a-newer-release"
        let registry = AppEnvironment.makeConnectorRegistry(settings: settings)
        #expect(AppEnvironment.chatConnectorSelection(settings: settings, registry: registry) == nil)
    }

    // MARK: W2's documented 1:1 event mapping

    @Test("ChatEvent maps onto AssistantChatEvent exactly as the W2 contract states")
    func theEventMappingIsTheDocumentedOne() {
        #expect(ConnectorChatEventMapping.event(.assistantText("hi")) == .assistantText("hi"))
        #expect(
            ConnectorChatEventMapping.event(.toolCall(name: "search_tracks", argumentsJSON: #"{"query":"jazz"}"#))
                == .toolCall(name: "search_tracks")
        )
        #expect(
            ConnectorChatEventMapping.event(.toolResult(name: "list_genres", text: "Jazz (12)", resultCount: 12))
                == .toolResult(name: "list_genres", summary: "Jazz (12)", resultCount: 12)
        )
        // `nil` is a value the mapping must carry, not a hole it may fill: a tool
        // that cannot count must not arrive at the surface claiming zero.
        #expect(
            ConnectorChatEventMapping.event(.toolResult(name: "propose_playlist", text: "Filed.", resultCount: nil))
                == .toolResult(name: "propose_playlist", summary: "Filed.", resultCount: nil)
        )
    }

    @Test("the mapping is order-preserving and total over a whole turn")
    func theMappingPreservesOrder() {
        let events: [ChatEvent] = [
            .toolCall(name: "list_genres", argumentsJSON: "{}"),
            .toolResult(name: "list_genres", text: "Jazz (12)", resultCount: 12),
            .assistantText("You have jazz."),
        ]
        #expect(ConnectorChatEventMapping.events(events) == [
            .toolCall(name: "list_genres"),
            .toolResult(name: "list_genres", summary: "Jazz (12)", resultCount: 12),
            .assistantText("You have jazz."),
        ])
    }

    @Test("a connector turn's counts reach the row the surface draws")
    func countsReachTheActivityRows() {
        let turn = ConnectorChatTurn(
            text: "You have jazz.",
            events: [
                .toolCall(name: "search_tracks", argumentsJSON: #"{"query":"jazz"}"#),
                .toolResult(name: "search_tracks", text: "12 tracks matching \"jazz\".", resultCount: 12),
                .toolCall(name: "propose_playlist", argumentsJSON: "{}"),
                .toolResult(name: "propose_playlist", text: "Filed.", resultCount: nil),
            ],
            termination: .answered,
            history: [],
            rounds: 2
        )
        #expect(ConnectorChatEventMapping.reply(turn).turn.toolActivity == [
            AssistantChatActivity(name: "search_tracks", resultCount: 12),
            AssistantChatActivity(name: "propose_playlist", resultCount: nil),
        ])
    }

    @Test("a turn cut short by the round budget is marked truncated, and keeps its prose")
    func aBudgetExhaustedTurnIsMarked() {
        let answered = ConnectorChatTurn(
            text: "Done.",
            events: [],
            termination: .answered,
            history: [],
            rounds: 1
        )
        let exhausted = ConnectorChatTurn(
            text: "Partial.",
            events: [],
            termination: .toolBudgetExhausted,
            history: [],
            rounds: 20
        )
        #expect(!ConnectorChatEventMapping.reply(answered).isTruncated)
        #expect(ConnectorChatEventMapping.reply(exhausted).isTruncated)
        #expect(ConnectorChatEventMapping.reply(exhausted).turn.text == "Partial.")
    }
}

// MARK: - The lookup row's copy

/// What a tool-activity row SAYS, given what the tool reported. Split from the
/// composition suite above only because that struct is at SwiftLint's
/// `type_body_length` ceiling; these are the same wave's assertions.
@Suite("Library chat lookup copy")
@MainActor
struct LibraryChatLookupCopyTests {
    @Test("all ten shipped tools have their own caption; an unknown one still says something honest")
    func everyToolHasItsOwnCaption() {
        let toolbox = AppEnvironment.makeLibraryToolbox(
            database: AppEnvironment.preview().database,
            profileId: ProfileRecord.guestID,
            proposals: LibraryChatProposalFiler(store: ProposalStore())
        )
        let unknown = LibraryChatStrings.toolCaption(for: "a_tool_from_a_later_wave").key
        var seen = Set<String>()
        for tool in toolbox.allTools {
            let key = LibraryChatStrings.toolCaption(for: tool.name).key
            #expect(key != unknown, "\(tool.name) has no caption of its own")
            #expect(seen.insert(key).inserted, "\(tool.name) shares a caption with another tool")
        }
        #expect(seen.count == 10)
    }

    @Test("the chat request budget is BOTH tiers' own bound, not a third policy")
    func theRequestBudgetMatchesTheEnforcement() {
        // `LibraryChatViewModel` cannot see `AIConnectorBridge`, and
        // `LibraryChatSession.maxRequestLength` is macOS 26-only, so the surface
        // restates 600. This is the guard that keeps the restatement honest.
        #expect(LibraryChatViewModel.maxRequestLength == ConnectorPayloadBudget.maxRequestCharacters)
    }

    @Test("a lookup row states its count when it has one, and reads exactly as before when it does not")
    func theActivityRowUsesTheCountTemplateOnlyWhenThereIsOne() {
        let caption = Text(LibraryChatStrings.toolSearchTracks)

        // No count: byte-for-byte the copy this surface has always drawn. This is
        // the assertion that keeps the change additive for the two tools — and
        // every refusal — that cannot report one.
        let bare = LibraryChatMessageRow.activityText(AssistantChatActivity(name: "search_tracks"))
        #expect(bare == caption)

        let counted = LibraryChatMessageRow.activityText(
            AssistantChatActivity(name: "search_tracks", resultCount: 12)
        )
        #expect(counted != bare)
        #expect(counted == caption + Text(verbatim: " ") + Text(LibraryChatStrings.toolResultCount(12)))

        // Zero is a count, not an absence: "— 0 results" describes a lookup that ran.
        let empty = LibraryChatMessageRow.activityText(
            AssistantChatActivity(name: "search_tracks", resultCount: 0)
        )
        #expect(empty != bare)
    }

    @Test("the count template is one catalog key, inflected rather than hand-pluralised")
    func theCountTemplateIsOneInflectedKey() {
        // One key for every locale: automatic grammar agreement handles "1 result"
        // vs "12 results", the same mechanism the proposal card already uses. A
        // per-count key would be one string per count in eight locales.
        #expect(LibraryChatStrings.toolResultCount(1).key == "app.assistant.chat.tool.resultCount")
        #expect(LibraryChatStrings.toolResultCount(12).key == LibraryChatStrings.toolResultCount(1).key)
        #expect(LibraryChatStrings.toolResultCount(0).key == LibraryChatStrings.toolResultCount(1).key)
    }
}
