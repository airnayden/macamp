// AIConnectorCompositionWiringTests — the connector tier is composed, observed and
// torn down by the shell.
//
// `AIGatingWiringTests` proves the master toggle builds or withholds the graph;
// `AIProfileSwitchWiringTests` proves a profile switch re-seats it. This suite covers
// the third composition claim the provider-connector work adds:
//
//  * THE DEFAULT IS UNCHANGED. With nothing selected the assistant stack is the
//    pre-connector one — `connectorParser` is `nil`, so the ladder never consults
//    the connector predicate and the local-only build makes zero network calls.
//  * A SELECTION REBUILDS THE GRAPH. Provider, model and Ollama host are read inside
//    `withObservationTracking`, so changing one rebuilds in place — which is what
//    lets `IntelligencePreferencesPane` keep its no-`.onChange` contract.
//  * A REPLACED GRAPH STOPS TALKING. Its `ConnectorSession` is cancelled first, so
//    the outgoing listener's route performs no further provider work.
//
// Nothing here touches the network or the Keychain: the selection cases drive a
// fake connector through a hand-built registry, and the live-rebuild cases only
// observe WHICH graph object is installed, never call through it.
import AIConnectorBridge
import AIConnectorKit
import AIConnectorKitOAuth
import Foundation
@testable import MacAMP
import Persistence
import Testing
import ViewModels

@Suite("AI connector composition", .serialized)
@MainActor
struct AIConnectorCompositionWiringTests {
    // MARK: The unconfigured default

    @Test("no selection builds the exact pre-connector stack")
    func theDefaultCarriesNoConnectorTier() {
        let stack = Self.backends(settings: Self.settings(#function))

        #expect(stack.connectorParser == nil)
        #expect(stack.narrating == nil)
    }

    @Test("the unconfigured predicate is never satisfied, so nothing can be routed")
    func theDefaultPredicateRefuses() async {
        let stack = Self.backends(settings: Self.settings(#function))

        #expect(await stack.connectorAvailability() == false)
    }

    @Test("an id no build registers degrades to Apple Intelligence rather than crashing")
    func anUnknownSelectionYieldsNoConnectorTier() {
        let settings = Self.settings(#function)
        settings.selectedConnectorID = "a-provider-from-a-newer-release"

        let stack = Self.backends(settings: settings)

        #expect(stack.connectorParser == nil)
        #expect(stack.narrating == nil)
    }

    @Test("a selected connector installs all three seam conformers")
    func aSelectionInstallsTheConnectorTier() {
        let settings = Self.settings(#function)
        settings.selectedConnectorID = ParkingConnector.identifier

        let stack = Self.backends(settings: settings, registry: Self.fakeRegistry(ParkingConnector()))

        #expect(stack.connectorParser is ConnectorQueryParser)
        #expect(stack.naming is ConnectorNamer)
        #expect(stack.narrating is ConnectorNarrator)
    }

    @Test("the shipped connectors register in picker order, subscription ones included")
    func theRegistryCarriesTheBuildsOwnConnectors() {
        let registry = AppEnvironment.makeConnectorRegistry(settings: Self.settings(#function))

        // There is ONE macOS target and it links `AIConnectorKitOAuth`, so the two
        // subscription connectors always register — ChatGPT among them, disabled,
        // which is a registration and not an omission.
        #expect(registry.ids == [
            "ollama",
            AnthropicConnector.connectorID,
            AppEnvironment.openAIConnectorID,
            ClaudeSubscriptionConnector.connectorID,
            "chatgpt",
        ])
    }

    @Test("the OpenAI Keychain namespace really is the id the connector reports")
    func theOpenAIIdentifierMatchesTheConnector() {
        let connector = OpenAIConnector(apiKey: { "" }, transport: URLSessionTransport())

        #expect(connector.id == AppEnvironment.openAIConnectorID)
    }

    @Test("a blank or unparseable Ollama host falls back to the stock address")
    func aBlankOllamaHostFallsBack() {
        #expect(AppEnvironment.ollamaHost(nil) == OllamaConnector.defaultHost)
        #expect(AppEnvironment.ollamaHost("   ") == OllamaConnector.defaultHost)
        #expect(AppEnvironment.ollamaHost("not a url") == OllamaConnector.defaultHost)
        #expect(AppEnvironment.ollamaHost("http://box.lan:11434").host == "box.lan")
    }

    // MARK: Live rebuild — the widened observation

    @Test("selecting a connector rebuilds the graph without a relaunch")
    func selectingAConnectorRebuildsLive() async {
        let settings = Self.settings(#function)
        let environment = AppEnvironment.preview()
        environment.connectAI(settings: settings)
        let before = environment.intelligence?.assistant

        settings.selectedConnectorID = "ollama"

        await Self.settle()
        #expect(before != nil)
        #expect(environment.intelligence?.assistant !== before)
    }

    @Test("changing the selected model rebuilds the graph")
    func changingTheModelRebuildsLive() async {
        let settings = Self.settings(#function)
        settings.selectedConnectorID = "ollama"
        let environment = AppEnvironment.preview()
        environment.connectAI(settings: settings)
        let before = environment.intelligence?.assistant

        settings.setSelectedModel("llama3.2", for: "ollama")

        await Self.settle()
        #expect(before != nil)
        #expect(environment.intelligence?.assistant !== before)
    }

    @Test("changing the Ollama host rebuilds the graph")
    func changingTheHostRebuildsLive() async {
        let settings = Self.settings(#function)
        let environment = AppEnvironment.preview()
        environment.connectAI(settings: settings)
        let before = environment.intelligence?.assistant

        settings.ollamaHost = "http://box.lan:11434"

        await Self.settle()
        #expect(before != nil)
        #expect(environment.intelligence?.assistant !== before)
    }

    @Test("the widened observation re-arms, so a second selection change still rebuilds")
    func theWidenedObservationReArms() async {
        let settings = Self.settings(#function)
        let environment = AppEnvironment.preview()
        environment.connectAI(settings: settings)

        // The view models are RETAINED, not reduced to `ObjectIdentifier`s: a
        // deallocated object's address is free to be reused by the next allocation,
        // so identifiers gathered across rebuilds collide for reasons that have
        // nothing to do with whether a rebuild happened.
        var assistants: [AssistantViewModel] = []
        for id in ["ollama", AnthropicConnector.connectorID, nil] {
            settings.selectedConnectorID = id
            await Self.settle()
            guard let assistant = environment.intelligence?.assistant else { continue }
            assistants.append(assistant)
        }

        #expect(assistants.count == 3)
        #expect(assistants.first !== assistants.dropFirst().first)
        #expect(assistants.dropFirst().first !== assistants.last)
        #expect(assistants.first !== assistants.last)
    }

    // MARK: Teardown — the connector session

    @Test("a profile switch cancels the outgoing graph's connector session")
    func aSwitchCancelsTheOutgoingSession() throws {
        let fixture = try Fixture()
        let outgoing = try #require(fixture.environment.intelligence).connectorSession
        #expect(outgoing.isActive)

        try fixture.switchToSecondProfile()

        let incoming = try #require(fixture.environment.intelligence).connectorSession
        #expect(!outgoing.isActive)
        #expect(incoming !== outgoing)
        #expect(incoming.isActive)
    }

    @Test("a graph replaced by a settings change cancels its session too")
    func aRebuildCancelsTheOutgoingSession() async {
        let settings = Self.settings(#function)
        let environment = AppEnvironment.preview()
        environment.connectAI(settings: settings)
        let outgoing = environment.intelligence?.connectorSession

        settings.selectedConnectorID = "ollama"

        await Self.settle()
        #expect(outgoing?.isActive == false)
        #expect(environment.intelligence?.connectorSession.isActive == true)
    }

    @Test("a cancelled session stops an in-flight connector task reaching its provider again")
    func aCancelledSessionStopsInFlightWork() async throws {
        let connector = ParkingConnector()
        let session = AppEnvironment.ConnectorSession()
        let settings = Self.settings(#function)
        settings.selectedConnectorID = ParkingConnector.identifier
        settings.setSelectedModel("parked", for: ParkingConnector.identifier)
        let route = try #require(AppEnvironment.connectorRoute(
            settings: settings,
            registry: Self.fakeRegistry(connector),
            session: session
        ))
        let parser = ConnectorQueryParser(
            connector: route.connector,
            model: route.model,
            contextProvider: { ConnectorPromptContext(requestText: "") }
        )

        // A request is genuinely in flight — parked INSIDE the provider call, which is
        // the only moment a profile switch could catch one.
        let inFlight = Task { try await parser.parse(text: "loud", locale: Self.locale) }
        await connector.log.waitUntilCalled()

        // The graph is replaced beneath it.
        session.cancel()
        await connector.log.release()
        _ = try? await inFlight.value

        // The outgoing route now refuses at BOTH gates, with no further provider call:
        // the ladder's predicate says no, and a parse that slipped past it raises
        // `.unconfigured` before any transport work.
        #expect(await route.isReady() == false)
        await #expect(throws: ConnectorFailure.unconfigured) {
            try await parser.parse(text: "loud again", locale: Self.locale)
        }
        #expect(await connector.log.callCount == 1)
    }

    // MARK: Helpers

    private static let suitePrefix = "com.example.macamp.tests.aiconnectors"
    private static let locale = Locale(identifier: "en_US")

    private static func settings(_ function: String) -> AppSettings {
        let name = "\(suitePrefix).\(function)"
        guard let store = UserDefaults(suiteName: name) else { return AppSettings(defaults: .standard) }
        store.removePersistentDomain(forName: name)
        return AppSettings(defaults: store)
    }

    /// The assistant stack the shell would build for `settings`, over an empty
    /// in-memory database. `registry` defaults to EMPTY so the unconfigured cases
    /// cannot accidentally resolve a real provider.
    private static func backends(
        settings: AppSettings,
        registry: ConnectorRegistry = ConnectorRegistry()
    ) -> AssistantBackendStack {
        AppEnvironment.makeAssistantBackends(
            settings: settings,
            database: AppEnvironment.preview().database,
            profileId: ProfileRecord.guestID,
            registry: registry,
            session: AppEnvironment.ConnectorSession()
        )
    }

    private static func fakeRegistry(_ connector: ParkingConnector) -> ConnectorRegistry {
        var registry = ConnectorRegistry()
        registry.register(connector)
        return registry
    }

    /// Lets the observation's main-actor hop run. `withObservationTracking` reports a
    /// change BEFORE the write lands, so the rebuild is deliberately deferred to a
    /// `Task`; yielding is what makes that deterministic without a sleep.
    private static func settle() async {
        for _ in 0 ..< 8 {
            await Task.yield()
        }
    }

    /// A `preview()` environment plus a second real profile to switch into — the same
    /// shape `AIProfileSwitchWiringTests` uses, so the switch runs through
    /// `ProfileService` rather than by poking the callback slot.
    @MainActor
    private struct Fixture {
        let environment: AppEnvironment
        let settings: AppSettings
        let secondProfileId: Int64

        init(function: String = #function) throws {
            settings = AIConnectorCompositionWiringTests.settings(function)
            environment = AppEnvironment.preview()
            let created = try environment.profileService.create(ProfileRecord(name: "Second"))
            secondProfileId = try #require(created.id)
            environment.connectAI(settings: settings)
        }

        func switchToSecondProfile() throws {
            try environment.profileService.switchTo(profileId: secondProfileId, pin: nil)
        }
    }
}

// MARK: - Fake provider

/// A connector that PARKS inside its structured call until released, so a test can
/// hold one request in flight while the graph is replaced beneath it.
///
/// A `struct` over an `actor` log rather than an actor itself: `AIProviderConnector`
/// declares `id` / `displayName` / `authDescriptor` as synchronous, and the shipped
/// connectors are all value types for the same reason.
private struct ParkingConnector: AIProviderConnector, ConnectorProbing {
    static let identifier = "macamp.tests.parking"

    let log = Log()

    var id: String {
        Self.identifier
    }

    var displayName: String {
        "Parking"
    }

    var authDescriptor: AuthDescriptor {
        .subscription
    }

    func listModels() async throws -> [ModelInfo] {
        await log.record()
        return [ModelInfo(id: "parked")]
    }

    func structuredCompletion(
        schema _: JSONSchemaObject,
        instructions _: String,
        prompt _: String,
        model _: String
    ) async throws -> Data {
        await log.record()
        await log.park()
        return Data("{}".utf8)
    }

    func completion(instructions _: String, prompt _: String, model _: String) async throws -> String {
        await log.record()
        return ""
    }

    /// Counts provider calls and holds the first one open on demand.
    actor Log {
        private(set) var callCount = 0
        private var parked: CheckedContinuation<Void, Never>?
        private var awaitingFirstCall: CheckedContinuation<Void, Never>?

        func record() {
            callCount += 1
            awaitingFirstCall?.resume()
            awaitingFirstCall = nil
        }

        /// Suspends the caller until ``release()``.
        func park() async {
            await withCheckedContinuation { parked = $0 }
        }

        func release() {
            parked?.resume()
            parked = nil
        }

        /// Returns once at least one provider call has been made.
        func waitUntilCalled() async {
            guard callCount == 0 else { return }
            await withCheckedContinuation { awaitingFirstCall = $0 }
        }
    }
}
