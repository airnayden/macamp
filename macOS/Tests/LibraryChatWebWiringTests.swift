// LibraryChatWebWiringTests — the web-suggestions grant really reaches the cloud
// tier, really needs BOTH of its records, and really cannot reach anything else.
//
// ── WHY ORDER IS ASSERTED AS A LIST, NOT AS MEMBERSHIP ───────────────────────
//
// `Sequence<AITool>.tool(named:)` resolves to the FIRST match, so the merge's whole
// safety argument is positional: a set-membership assertion ("web_search is in
// there somewhere") passes for an implementation that puts the built-in tool ahead
// of the library's frozen names, which is precisely the failure the pinned order
// exists to prevent. Every claim below therefore compares the WHOLE name list to an
// expected list, in order.
//
// ── THE TWO RECORDS ARE ASSERTED SEPARATELY, ON PURPOSE ─────────────────────
//
// `webSuggestionsEnabled` and `webSuggestionsConsented` are independent stores
// (`WebSuggestionsSettingsTests` pins that at the defaults layer). The case that
// matters here is the reachable one in between: the switch on, the disclosure never
// accepted. An implementation that derived consent from enablement — or that read
// only the switch — publishes a web tool nobody agreed to, and passes every other
// case in this file.
//
// ── NOTHING HERE REACHES A NETWORK, A KEYCHAIN OR A PROVIDER ────────────────
//
// The connector is never asked anything: only CONSTRUCTION of the engine is needed
// to read back its tool list and instructions. The enricher is only ever checked
// for existence — it is never invoked, so no lookup is performed and the Keychain
// providers it closes over are never read.
import AIConnectorBridge
import AIConnectorKit
import AIConnectorMCP
import Foundation
@testable import MacAMP
import MCP
import Persistence
import Services
import Testing
import ViewModels

@Suite("Library chat web wiring", .serialized)
@MainActor
struct LibraryChatWebWiringTests {
    // MARK: The merged list

    @Test("granted and with nothing else configured, the list is the library's own plus exactly web_search")
    func grantedWithoutServersAppendsOnlyTheWebTool() {
        let toolbox = Self.toolbox()
        let settings = Self.grantedSettings(#function)

        let engine = Self.engine(toolbox: toolbox, settings: settings)

        #expect(engine.tools.map(\.name) == Self.libraryNames(toolbox) + [WebSearchTool.toolName])
    }

    @Test("granted, the built-in tool sits after every library tool and before every mcp__ one")
    func grantedMergeIsPinnedInOrder() {
        let toolbox = Self.toolbox()
        let settings = Self.grantedSettings(#function)
        let external = Self.externalTools()

        let engine = Self.engine(toolbox: toolbox, settings: settings, external: external)

        let names = engine.tools.map(\.name)
        // The WHOLE list, in order — see the file header.
        #expect(names == Self.libraryNames(toolbox) + [WebSearchTool.toolName] + external.map(\.name))
        // And the same claim stated as the two boundaries it is really about, so a
        // failure says which side moved.
        let library = Self.libraryNames(toolbox)
        #expect(names.firstIndex(of: WebSearchTool.toolName) == library.count)
        #expect(names.firstIndex(where: { $0.hasPrefix(MCPToolProjection.namePrefix) }) == library.count + 1)
        // The built-in name is BARE. Acquiring the namespace would claim a
        // provenance it does not have — see `LibraryChatToolMerge`.
        #expect(WebSearchTool.toolName.hasPrefix(MCPToolProjection.namePrefix) == false)
    }

    @Test("granted, the instructions carry both the music-knowledge lines and the web workflow")
    func grantedInstructionsCarryTheKnowledgeLines() {
        let toolbox = Self.toolbox()
        let settings = Self.grantedSettings(#function)

        let engine = Self.engine(toolbox: toolbox, settings: settings)

        #expect(engine.instructions == LibraryChatInstructions.text(
            locale: .current,
            profile: .cloud,
            canControlPlayback: false,
            webWorkflowEnabled: true,
            musicKnowledgeEnabled: true
        ))
        #expect(engine.instructions.contains("your own knowledge of music"))
        #expect(engine.instructions.contains(WebSearchTool.toolName))
        #expect(engine.instructions != Self.ungrantedInstructions)
    }

    // MARK: The grant needs both records

    @Test("the switch alone grants nothing: no web tool, no knowledge lines, no enricher")
    func enabledWithoutConsentGrantsNothing() {
        let toolbox = Self.toolbox()
        let settings = Self.settings(#function)
        // The reachable in-between state: `WebSuggestionsSectionModel.setEnabled(true)`
        // offers the disclosure and writes NOTHING, so a listener can hold the switch
        // on with the record unwritten. See the file header.
        settings.webSuggestionsEnabled = true
        #expect(settings.webSuggestionsConsented == false)

        let engine = Self.engine(toolbox: toolbox, settings: settings)

        #expect(engine.tools.map(\.name) == Self.libraryNames(toolbox))
        #expect(engine.instructions == Self.ungrantedInstructions)
        #expect(engine.instructions.contains(WebSearchTool.toolName) == false)
        #expect(engine.instructions.contains("your own knowledge of music") == false)
        #expect(AppEnvironment.suggestionEnricher(settings: settings, registry: Self.registry()) == nil)
    }

    @Test("consent alone grants nothing either — the switch is still the switch")
    func consentWithoutTheSwitchGrantsNothing() {
        let toolbox = Self.toolbox()
        let settings = Self.settings(#function)
        settings.webSuggestionsConsented = true

        let engine = Self.engine(toolbox: toolbox, settings: settings)

        #expect(engine.tools.map(\.name) == Self.libraryNames(toolbox))
        #expect(engine.instructions == Self.ungrantedInstructions)
    }

    @Test("with the feature off the published list and instructions are byte-identical to today's")
    func settingOffChangesNothing() {
        let toolbox = Self.toolbox()
        let settings = Self.settings(#function)

        let engine = Self.engine(toolbox: toolbox, settings: settings)

        let baseline = LibraryToolAdapter.aiTools(toolbox, profile: .cloud)
        #expect(engine.tools.map(\.name) == baseline.map(\.name))
        #expect(engine.tools.map(\.description) == baseline.map(\.description))
        #expect(engine.instructions == Self.ungrantedInstructions)
    }

    // MARK: The on-device tier

    @Test("the on-device tier never receives the web tool, nor its lines, nor an enricher")
    func onDeviceGetsNeitherToolNorEnricher() {
        let toolbox = Self.toolbox()
        // GRANTED, and with no connector selected — so the only thing standing
        // between the on-device tier and the web is the route check itself.
        let settings = Self.grantedSettings(#function)
        settings.selectedConnectorID = nil

        #expect(LibraryToolbox.onDeviceToolNames.contains(WebSearchTool.toolName) == false)
        #expect(toolbox.tools(profile: .onDevice).map(\.name).contains(WebSearchTool.toolName) == false)
        #expect(LibraryChatInstructions.text(
            locale: .current,
            profile: .onDevice,
            webWorkflowEnabled: true,
            musicKnowledgeEnabled: true
        ) == LibraryChatInstructions.text(locale: .current, profile: .onDevice))
        #expect(AppEnvironment.suggestionEnricher(settings: settings, registry: Self.registry()) == nil)
    }

    // MARK: The enricher

    @Test("the enricher is minted for a granted connector route and for nothing else")
    func enricherIsCloudOnlyAndNeedsBothRecords() {
        let settings = Self.grantedSettings(#function)
        let registry = Self.registry()

        #expect(AppEnvironment.suggestionEnricher(settings: settings, registry: registry) != nil)

        // Retracting either record retires it, and so does losing the cloud route.
        settings.webSuggestionsConsented = false
        #expect(AppEnvironment.suggestionEnricher(settings: settings, registry: registry) == nil)

        settings.webSuggestionsConsented = true
        settings.webSuggestionsEnabled = false
        #expect(AppEnvironment.suggestionEnricher(settings: settings, registry: registry) == nil)

        settings.webSuggestionsEnabled = true
        settings.selectedConnectorID = nil
        #expect(AppEnvironment.suggestionEnricher(settings: settings, registry: registry) == nil)
    }

    // MARK: Rebuild on flip

    @Test("flipping either record re-mints the conversation graph")
    func flippingTheGrantRebuildsTheGraph() async {
        let settings = Self.settings(#function)
        let environment = AppEnvironment.preview()
        environment.connectAI(settings: settings)
        let first = environment.intelligence?.chat
        #expect(first != nil)

        settings.webSuggestionsConsented = true
        await Self.settle()
        let second = environment.intelligence?.chat
        #expect(second !== first)

        settings.webSuggestionsEnabled = true
        await Self.settle()
        // A cached engine would keep answering with the old tool list, so the
        // observation has to survive its own first firing — the same re-arming
        // claim `AIGatingWiringTests` makes for the master toggle.
        #expect(environment.intelligence?.chat !== second)
    }
}

// MARK: - Fixtures

private extension LibraryChatWebWiringTests {
    static let suitePrefix = "com.example.macamp.tests.libraryChatWebWiring"
    static let serverName = "Somebody Else's Server"

    /// The instructions this call site composed before the feature existed. Every
    /// ungranted case is asserted against it byte for byte, which is the honest form
    /// of "no web lines and no knowledge lines".
    static let ungrantedInstructions = LibraryChatInstructions.text(
        locale: .current,
        profile: .cloud,
        canControlPlayback: false
    )

    static func engine(
        toolbox: LibraryToolbox,
        settings: AppSettings,
        external: [AITool] = []
    ) -> ConnectorChatEngine {
        AppEnvironment.makeConnectorChatEngine(
            connector: SilentWebConnector(),
            model: "unreached",
            toolbox: toolbox,
            connectors: AppEnvironment.ConnectorContext(
                registry: ConnectorRegistry(),
                session: AppEnvironment.ConnectorSession(),
                externalTools: { external }
            ),
            web: AppEnvironment.webSuggestionsSupply(settings: settings)
        )
    }

    static func libraryNames(_ toolbox: LibraryToolbox) -> [String] {
        LibraryToolAdapter.aiTools(toolbox, profile: .cloud).map(\.name)
    }

    /// Two tools from somebody else's server, projected through the REAL projection
    /// so the namespacing this suite reads is production's own.
    static func externalTools() -> [AITool] {
        MCPToolProjection.tools(
            serverName: serverName,
            published: ["fetch", "crawl"].map {
                MCP.Tool(name: $0, description: "Somebody else's tool.", inputSchema: .object([:]))
            }
        ) { _, _ in "" }
    }

    /// A registry holding one tool-calling connector under ``connectorID``, so
    /// `chatAvailability` can resolve a cloud route at all.
    static func registry() -> ConnectorRegistry {
        var registry = ConnectorRegistry()
        registry.register(SilentWebConnector())
        return registry
    }

    /// Both records written, a tool-calling connector selected with a model, and its
    /// library-browsing disclosure accepted — the one state that grants everything.
    static func grantedSettings(_ function: String) -> AppSettings {
        let settings = Self.settings(function)
        settings.webSuggestionsConsented = true
        settings.webSuggestionsEnabled = true
        let id = SilentWebConnector.connectorID
        settings.selectedConnectorID = id
        settings.setSelectedModel("unreached", for: id)
        settings.recordLibraryBrowsingConsent(forConnectorID: id)
        return settings
    }

    /// A settings store on a volatile, per-test suite so nothing leaks into the
    /// developer's real preferences or between cases.
    static func settings(_ function: String) -> AppSettings {
        let suite = "\(suitePrefix).\(function)"
        guard let store = UserDefaults(suiteName: suite) else { return AppSettings(defaults: .standard) }
        store.removePersistentDomain(forName: suite)
        return AppSettings(defaults: store)
    }

    static func toolbox() -> LibraryToolbox {
        AppEnvironment.makeLibraryToolbox(
            database: AppEnvironment.preview().database,
            profileId: ProfileRecord.guestID,
            proposals: LibraryChatProposalFiler(store: ProposalStore())
        )
    }

    /// Lets the observation's main-actor hop run. `withObservationTracking` reports
    /// a change BEFORE the write lands, so the rebuild is deliberately deferred to a
    /// `Task`; yielding is what makes that deterministic without a sleep.
    static func settle() async {
        for _ in 0 ..< 8 {
            await Task.yield()
        }
    }
}

// MARK: - Fake provider

/// A tool-calling connector that is never asked anything: this suite only ever
/// CONSTRUCTS engines and reads back what they were built with.
private struct SilentWebConnector: ToolCallingConnector, ConnectorProbing {
    /// Nonisolated so the protocol's own `id` can reach it — the suite above is
    /// `@MainActor`, and a connector is asked its id from anywhere.
    static let connectorID = "macamp.tests.webWiring"

    var id: String {
        Self.connectorID
    }

    var displayName: String {
        "Silent Web"
    }

    var authDescriptor: AuthDescriptor {
        .subscription
    }

    func listModels() async throws -> [ModelInfo] {
        []
    }

    func structuredCompletion(
        schema _: JSONSchemaObject,
        instructions _: String,
        prompt _: String,
        model _: String
    ) async throws -> Data {
        Data("{}".utf8)
    }

    func completion(instructions _: String, prompt _: String, model _: String) async throws -> String {
        ""
    }

    func chatTurn(_: ToolTurnRequest) async throws -> ToolTurnResponse {
        ToolTurnResponse(text: "")
    }
}
