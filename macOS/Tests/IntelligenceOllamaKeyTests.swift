// IntelligenceOllamaKeyTests — the OPTIONAL Ollama Cloud key, as the setup sheet
// handles it.
//
// The address-configured provider is the only one that accepts a second, optional
// credential, and the interesting behaviour is all in the EDGES rather than the
// happy path:
//
//   * An untouched key field must not clear a key that is already stored. The
//     field is never seeded from the Keychain, so "empty" means "not entered this
//     time", and treating it as "delete" would silently sign a listener out of
//     Ollama Cloud every time they edited the host.
//   * Typing a key is still ONE settings write and ONE Keychain write, because
//     `AppSettings` writes through in `didSet` and every write rebuilds the whole
//     assistant graph.
//   * "Test" must check the key being TYPED, not the one on disk.
//
// Nothing here touches the network, the real Keychain, or `UserDefaults`.
import AIConnectorBridge
import AIConnectorKit
import Foundation
@testable import MacAMP
import Testing

@Suite("Intelligence Ollama optional key")
@MainActor
struct IntelligenceOllamaKeyTests {
    private static let key = "test-token-ollama-sheet-alpha"

    @Test("Only the address-configured provider offers an optional key")
    func onlyTheHostProviderOffersAnOptionalKey() {
        #expect(Self.hostModel().supportsOptionalAPIKey)
        #expect(Self.keyModel().supportsOptionalAPIKey == false)
    }

    @Test("Typing a key stores it once, beside a single settings write")
    func typingAKeyCommitsOnceEach() async {
        let settings = CountingConnectorSettings(consented: [AppEnvironment.ollamaConnectorID])
        let secrets = InMemorySecretStore()
        let model = Self.hostModel(settings: settings, secrets: secrets)
        await model.prepare()

        model.draft = "http://box.lan:11434"
        model.secretDraft = Self.key
        #expect(settings.writeCount == 0)
        #expect(await secrets.writeCount == 0)

        await model.save()

        #expect(settings.writeCount == 1)
        #expect(await secrets.writeCount == 1)
        let stored = try? await secrets.get(service: model.service, account: Self.account)
        #expect(stored == Self.key)
        // Spent, then cleared — the sheet never holds a secret after committing it.
        #expect(model.secretDraft.isEmpty)
        #expect(model.hasStoredSecret)
    }

    @Test("An untouched key field leaves a stored key alone")
    func anUntouchedFieldNeverClearsAStoredKey() async throws {
        let settings = CountingConnectorSettings(consented: [AppEnvironment.ollamaConnectorID])
        let secrets = InMemorySecretStore()
        try await secrets.set(Self.key, service: Self.service, account: Self.account)
        let model = Self.hostModel(settings: settings, secrets: secrets)
        await model.prepare()

        // Seeded as "a key exists" but NEVER with its value.
        #expect(model.hasStoredSecret)
        #expect(model.secretDraft.isEmpty)

        model.draft = "http://box.lan:11434"
        await model.save()

        #expect(try await secrets.get(service: Self.service, account: Self.account) == Self.key)
    }

    @Test("Remove clears the key, the address and the selection together")
    func removeClearsEverything() async throws {
        let settings = CountingConnectorSettings(
            selectedConnectorID: AppEnvironment.ollamaConnectorID,
            ollamaHost: "http://box.lan:11434"
        )
        let secrets = InMemorySecretStore()
        try await secrets.set(Self.key, service: Self.service, account: Self.account)
        let model = Self.hostModel(settings: settings, secrets: secrets)
        await model.prepare()
        #expect(model.canRemove)

        await model.remove()

        #expect(try await secrets.get(service: Self.service, account: Self.account) == nil)
        #expect(settings.ollamaHost == nil)
        #expect(settings.selectedConnectorID == nil)
        #expect(model.hasStoredSecret == false)
        #expect(model.secretDraft.isEmpty)
    }

    @Test("Test checks the key being typed, not the one already saved")
    func validationUsesTheDraftKey() async {
        let probed = ProbedDraft()
        let model = Self.hostModel(probe: { draft, secret in
            probed.record(draft: draft, secret: secret)
            return .unconfigured
        })
        model.draft = "  https://ollama.com  "
        model.secretDraft = "  \(Self.key)  "

        await model.validate()

        #expect(probed.draft == "https://ollama.com")
        #expect(probed.secret == Self.key)
    }

    @Test("A hosted address still requires consent; loopback still does not")
    func consentTracksTheAddressNotTheKey() {
        let model = Self.hostModel()
        model.draft = "https://ollama.com"
        model.secretDraft = Self.key
        #expect(model.isLocalOnly == false)
        #expect(model.requiresConsent)

        // Adding a key to a loopback address changes nothing: nothing leaves the
        // machine, so there is nothing to disclose.
        model.draft = "http://127.0.0.1:11434"
        #expect(model.isLocalOnly)
        #expect(model.requiresConsent == false)
    }

    @Test("An unconsented save writes neither store")
    func consentGatesTheKeyWriteToo() async {
        let settings = CountingConnectorSettings()
        let secrets = InMemorySecretStore()
        let model = Self.hostModel(settings: settings, secrets: secrets)
        model.draft = "https://ollama.com"
        model.secretDraft = Self.key

        await model.save()

        #expect(settings.writeCount == 0)
        #expect(await secrets.writeCount == 0)
    }
}

// MARK: - Builders

private extension IntelligenceOllamaKeyTests {
    static var service: String {
        ConnectorSecretService.name(forConnectorID: AppEnvironment.ollamaConnectorID)
    }

    static var account: String {
        AppEnvironment.connectorAPIKeyAccount
    }

    static func hostModel(
        settings: CountingConnectorSettings = CountingConnectorSettings(),
        secrets: InMemorySecretStore = InMemorySecretStore(),
        probe: @escaping @MainActor (String, String) async -> ConnectorStatus = { _, _ in .unconfigured }
    ) -> IntelligenceConnectorConfigModel {
        IntelligenceConnectorConfigModel(
            configuration: IntelligenceConnectorConfiguration(
                id: AppEnvironment.ollamaConnectorID,
                displayName: "Ollama",
                credential: .host
            ),
            settings: settings,
            secrets: secrets,
            probe: probe
        )
    }

    static func keyModel() -> IntelligenceConnectorConfigModel {
        IntelligenceConnectorConfigModel(
            configuration: IntelligenceConnectorConfiguration(
                id: AnthropicConnector.connectorID,
                displayName: "Anthropic Claude",
                credential: .apiKey
            ),
            settings: CountingConnectorSettings(),
            secrets: InMemorySecretStore(),
            probe: { _, _ in .unconfigured }
        )
    }
}

/// Captures what a probe was handed, so the draft-versus-stored distinction is
/// asserted rather than assumed.
@MainActor
private final class ProbedDraft {
    private(set) var draft = ""
    private(set) var secret = ""

    func record(draft: String, secret: String) {
        self.draft = draft
        self.secret = secret
    }
}
