// AIConnectorSettingsTests — `AppSettings` as the `AIConnectorSettingsProviding` witness.
//
// Three properties that would each look correct in the UI while being wrong:
//
//   1. A default that is not "Apple Intelligence". The whole no-network promise
//      rests on `selectedConnectorID == nil` on a fresh install, so it is asserted
//      against a freshly wiped domain rather than against a live app.
//   2. A key that persists a secret. API keys belong in the Keychain; a plist is
//      world-readable to anything running as the user and gets swept into backups.
//      The persisted domain is therefore inspected directly — the assertion is on
//      what actually reached disk, not on what the source claims it wrote.
//   3. A garbage stored value that takes the settings store down at launch. A
//      hand-edited plist or an older build must degrade, never trap, so each key
//      is seeded with a type it will never legitimately hold.
import AIConnectorBridge
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("AI connector settings")
@MainActor
struct AIConnectorSettingsTests {
    @Test("a fresh install routes to Apple Intelligence and configures nothing")
    func theDefaultStateIsUnconfigured() {
        let settings = AppSettings(defaults: Self.store(named: "\(Self.suitePrefix).default"))

        #expect(settings.selectedConnectorID == nil)
        #expect(settings.ollamaHost == nil)
        #expect(settings.selectedConnectorModels.isEmpty)
        #expect(settings.selectedModel(for: "ollama") == nil)
    }

    @Test("every connector key round-trips through a reload")
    func eachConnectorKeyRoundTrips() {
        let store = Self.store(named: "\(Self.suitePrefix).roundTrip")
        let settings = AppSettings(defaults: store)

        settings.selectedConnectorID = "ollama"
        settings.ollamaHost = "http://127.0.0.1:11434"
        settings.setSelectedModel("llama3.2", for: "ollama")

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.selectedConnectorID == "ollama")
        #expect(reloaded.ollamaHost == "http://127.0.0.1:11434")
        #expect(reloaded.selectedModel(for: "ollama") == "llama3.2")
    }

    @Test("clearing one connector's model leaves the others' selections intact")
    func modelSelectionsAreKeptPerConnector() {
        let store = Self.store(named: "\(Self.suitePrefix).perConnector")
        let settings = AppSettings(defaults: store)

        settings.setSelectedModel("llama3.2", for: "ollama")
        settings.setSelectedModel("claude-sonnet-4", for: "anthropic")
        settings.setSelectedModel(nil, for: "ollama")

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.selectedModel(for: "ollama") == nil)
        #expect(reloaded.selectedModel(for: "anthropic") == "claude-sonnet-4")
        #expect(reloaded.selectedModel(for: "never-configured") == nil)
    }

    @Test("nothing this todo persists is named like a secret")
    func noConnectorKeyLooksLikeASecret() {
        let name = "\(Self.suitePrefix).secrets"
        let store = Self.store(named: name)
        let settings = AppSettings(defaults: store)

        settings.selectedConnectorID = "anthropic"
        settings.ollamaHost = "http://127.0.0.1:11434"
        settings.setSelectedModel("claude-sonnet-4", for: "anthropic")
        settings.recordConsent(forConnectorID: "anthropic")

        let persisted = (store.persistentDomain(forName: name) ?? [:]).keys
            .filter { $0.hasPrefix(Self.connectorPrefix) }
            .sorted()
        #expect(persisted == [
            "\(Self.connectorPrefix)consentedIds",
            "\(Self.connectorPrefix)ollamaHost",
            "\(Self.connectorPrefix)selectedId",
            "\(Self.connectorPrefix)selectedModels",
        ])
        for key in persisted {
            let lowercased = key.lowercased()
            for forbidden in ["key", "token", "secret"] {
                #expect(!lowercased.contains(forbidden), "\(key) must not persist a \(forbidden)")
            }
        }
    }

    @Test("a garbage stored value degrades instead of trapping")
    func garbagePersistedValuesDegrade() {
        let name = "\(Self.suitePrefix).garbage"
        let store = Self.store(named: name)
        store.set([1, 2, 3], forKey: "\(Self.connectorPrefix)selectedId")
        store.set(["host": 42], forKey: "\(Self.connectorPrefix)ollamaHost")
        store.set(["ollama": "llama3.2", "anthropic": 7], forKey: "\(Self.connectorPrefix)selectedModels")

        let settings = AppSettings(defaults: store)
        #expect(settings.selectedConnectorID == nil)
        #expect(settings.ollamaHost == nil)
        #expect(settings.selectedModel(for: "ollama") == "llama3.2")
        #expect(settings.selectedModel(for: "anthropic") == nil)
    }

    @Test("an unknown persisted connector id resolves back to Apple Intelligence")
    func anUnregisteredSelectionDegradesToNil() {
        let store = Self.store(named: "\(Self.suitePrefix).unknownId")
        let settings = AppSettings(defaults: store)
        settings.selectedConnectorID = "connector-from-a-newer-build"

        #expect(settings.resolvedConnectorID(among: ["ollama", "anthropic"]) == nil)
        #expect(settings.selectedConnectorID == "connector-from-a-newer-build")

        settings.selectedConnectorID = "ollama"
        #expect(settings.resolvedConnectorID(among: ["ollama", "anthropic"]) == "ollama")
        #expect(settings.resolvedConnectorID(among: []) == nil)
    }

    @Test("the connector keys are independent of the seven feature switches")
    func connectorRoutingDoesNotDisturbTheFeatureSwitches() {
        let store = Self.store(named: "\(Self.suitePrefix).isolation")
        let settings = AppSettings(defaults: store)

        settings.selectedConnectorID = "openai"
        settings.ollamaHost = "http://localhost:11434"
        settings.setSelectedModel("gpt-4o", for: "openai")

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.intelligenceEnabled)
        #expect(AIFeatureBundle.allCases.allSatisfy { reloaded.isEnabled($0) })
    }

    // MARK: Helpers

    private static let suitePrefix = "com.example.macamp.tests.aiConnectorSettings"
    private static let connectorPrefix = "com.example.macamp.settings.ai.connector."

    private static func store(named name: String) -> UserDefaults {
        guard let store = UserDefaults(suiteName: name) else { return .standard }
        store.removePersistentDomain(forName: name)
        return store
    }
}
