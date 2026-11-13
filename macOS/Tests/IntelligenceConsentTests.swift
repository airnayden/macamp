// IntelligenceConsentTests — nothing reaches a remote provider before the listener agrees.
//
// The claim is negative and therefore unobservable from the end state: a save that
// was refused and a save that never happened leave identical stores. So both stores
// COUNT — `InMemorySecretStore` ships `writeCount`, `CountingConnectorSettings`
// mirrors it, and consent gets a counter of its own so "consent was recorded" and
// "the connector was configured" can be told apart.
//
// The disclosure copy is checked by RENDERING it and looking for the enforced
// number, not by reading the source. A literal typed into the copy would satisfy a
// source grep and still drift from `ConnectorPayloadBudget` the day the budget
// moves; resolving the string and comparing against the constant cannot.
import AIConnectorBridge
import AIConnectorKit
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Intelligence connector consent")
@MainActor
struct IntelligenceConsentTests {
    // MARK: The gate

    @Test("a remote connector's first save commits nothing until the disclosure is accepted")
    func consentBlocksTheFirstSave() async throws {
        let settings = CountingConnectorSettings()
        let secrets = InMemorySecretStore()
        let model = Self.keyModel(settings: settings, secrets: secrets)
        model.draft = "sk-live"

        #expect(model.requiresConsent)
        #expect(model.canSave)

        await model.save()

        // Refused at the head of `save()`: neither store was reached.
        #expect(settings.writeCount == 0)
        #expect(await secrets.writeCount == 0)
        #expect(await secrets.storedSecretCount == 0)
        #expect(settings.selectedConnectorID == nil)

        model.grantConsent()

        #expect(!model.requiresConsent)
        #expect(settings.consentCount == 1)
        // Recording consent is not configuring: still zero writes to either store.
        #expect(settings.writeCount == 0)
        #expect(await secrets.writeCount == 0)

        await model.save()

        #expect(settings.writeCount == 1)
        #expect(await secrets.writeCount == 1)
        #expect(settings.selectedConnectorID == Self.keyConnectorID)
        let stored = try await secrets.get(service: model.service, account: Self.account)
        #expect(stored == "sk-live")
    }

    @Test("declining leaves the connector unconfigured and the default stack intact")
    func decliningCommitsNothingAtAll() async throws {
        let settings = CountingConnectorSettings()
        let secrets = InMemorySecretStore()
        let model = Self.keyModel(settings: settings, secrets: secrets)
        model.draft = "sk-live"

        // Declining is the absence of `grantConsent()`; a second attempt changes
        // nothing, so a repeated Save cannot wear the gate down.
        await model.save()
        await model.save()

        #expect(settings.consentCount == 0)
        #expect(settings.writeCount == 0)
        #expect(await secrets.writeCount == 0)
        #expect(await secrets.storedSecretCount == 0)
        let stored = try await secrets.get(service: model.service, account: Self.account)
        #expect(stored == nil)
        // `nil` IS the shipped default: Apple Intelligence, on-device, zero network.
        #expect(settings.selectedConnectorID == nil)
        #expect(settings.ollamaHost == nil)
        #expect(model.requiresConsent)
    }

    // MARK: Locality

    @Test("a loopback Ollama host skips the disclosure entirely")
    func aLoopbackHostNeverAsksForConsent() async {
        let settings = CountingConnectorSettings()
        let model = Self.hostModel(settings: settings, secrets: InMemorySecretStore())
        await model.prepare()

        // Empty resolves to the connector's own loopback default.
        #expect(!model.requiresConsent)
        for loopback in ["http://127.0.0.1:11434", "http://localhost:11434", "http://[::1]:11434"] {
            model.draft = loopback
            #expect(!model.requiresConsent, "\(loopback) never leaves this Mac")
        }

        model.draft = "http://127.0.0.1:11434"
        await model.save()

        #expect(settings.ollamaHost == "http://127.0.0.1:11434")
        #expect(settings.writeCount == 1)
        // Nothing was disclosed, so nothing was consented to.
        #expect(settings.consentCount == 0)
        #expect(!settings.hasConsented(toConnectorID: Self.hostConnectorID))
    }

    @Test("an Ollama host that is not this machine is treated as remote")
    func aRemoteOllamaHostRequiresConsent() async {
        let settings = CountingConnectorSettings()
        let model = Self.hostModel(settings: settings, secrets: InMemorySecretStore())
        model.draft = "http://ollama.example.com:11434"

        #expect(model.requiresConsent)
        await model.save()
        #expect(settings.writeCount == 0)
        #expect(settings.ollamaHost == nil)

        model.grantConsent()
        await model.save()

        #expect(settings.ollamaHost == "http://ollama.example.com:11434")
        #expect(settings.writeCount == 1)
    }

    @Test("consent is remembered per connector, never globally")
    func consentDoesNotTransferBetweenConnectors() async {
        let settings = CountingConnectorSettings(consented: [Self.keyConnectorID])
        let consented = Self.keyModel(settings: settings, secrets: InMemorySecretStore())
        let other = Self.keyModel(
            settings: settings,
            secrets: InMemorySecretStore(),
            connectorID: Self.otherKeyConnectorID
        )
        consented.draft = "sk-live"
        other.draft = "sk-other"

        #expect(!consented.requiresConsent)
        #expect(other.requiresConsent)

        await other.save()
        #expect(settings.selectedConnectorID == nil)
    }

    @Test("consent survives an edit: a second visit does not re-interrogate")
    func consentIsAskedOnlyOnce() async {
        let settings = CountingConnectorSettings()
        let secrets = InMemorySecretStore()
        let first = Self.keyModel(settings: settings, secrets: secrets)
        first.draft = "sk-live"
        first.grantConsent()
        await first.save()

        let second = Self.keyModel(settings: settings, secrets: secrets)
        second.draft = "sk-rotated"

        #expect(!second.requiresConsent)
        #expect(settings.consentCount == 1)
    }

    // MARK: The disclosure quotes the enforced budget

    @Test("the disclosure forwards the payload budget rather than restating it")
    func theDisclosureMirrorsTheBudget() {
        let disclosure = IntelligenceConsentDisclosure(
            configuration: Self.configuration(id: Self.keyConnectorID)
        )

        #expect(disclosure.requestCharacters == ConnectorPayloadBudget.maxRequestCharacters)
        #expect(disclosure.genres == ConnectorPayloadBudget.maxGenres)
        #expect(disclosure.artists == ConnectorPayloadBudget.maxArtists)
        #expect(disclosure.id == Self.keyConnectorID)
    }

    @Test("the consent copy renders the numbers the builder actually enforces")
    func theConsentCopyQuotesTheBudget() {
        let disclosure = IntelligenceConsentDisclosure(
            configuration: Self.configuration(id: Self.keyConnectorID)
        )
        let request = Self.text(PreferencesStrings.connectorConsentRequestItem(
            characters: disclosure.requestCharacters
        ))
        let genres = Self.text(PreferencesStrings.connectorConsentGenresItem(count: disclosure.genres))
        let artists = Self.text(PreferencesStrings.connectorConsentArtistsItem(count: disclosure.artists))

        #expect(request.contains(ConnectorPayloadBudget.maxRequestCharacters.formatted()))
        #expect(genres.contains(ConnectorPayloadBudget.maxGenres.formatted()))
        #expect(artists.contains(ConnectorPayloadBudget.maxArtists.formatted()))
        // The provider is named by interpolation, so the brand never has to be
        // glued onto a translated sentence at the call site.
        #expect(Self.text(PreferencesStrings.connectorConsentLead(provider: "Anthropic Claude"))
            .contains("Anthropic Claude"))
    }

    // MARK: The shipped default

    @Test("a fresh install selects no connector and has consented to none")
    func aFreshInstallIsFullyOnDevice() {
        let name = "\(Self.suitePrefix).fresh"
        let settings = AppSettings(defaults: Self.store(named: name))

        #expect(settings.selectedConnectorID == nil)
        #expect(settings.consentedConnectorIDs.isEmpty)
        for connectorID in [Self.keyConnectorID, Self.otherKeyConnectorID, Self.hostConnectorID] {
            #expect(!settings.hasConsented(toConnectorID: connectorID))
        }
    }

    @Test("a recorded consent round-trips, and a garbage stored value degrades")
    func consentPersistsAndDegradesSafely() {
        let name = "\(Self.suitePrefix).roundTrip"
        let store = Self.store(named: name)
        let settings = AppSettings(defaults: store)

        settings.recordConsent(forConnectorID: Self.keyConnectorID)
        settings.recordConsent(forConnectorID: Self.keyConnectorID)

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.consentedConnectorIDs == [Self.keyConnectorID])
        #expect(reloaded.hasConsented(toConnectorID: Self.keyConnectorID))
        #expect(!reloaded.hasConsented(toConnectorID: Self.otherKeyConnectorID))
        // Selecting a provider is still a separate, explicit act.
        #expect(reloaded.selectedConnectorID == nil)

        store.set(["anthropic": true], forKey: Self.consentKey)
        let degraded = AppSettings(defaults: store)
        #expect(degraded.consentedConnectorIDs.isEmpty)
    }
}

// MARK: - Builders

private extension IntelligenceConsentTests {
    static let suitePrefix = "com.example.macamp.tests.aiConnectorConsent"
    static let consentKey = "com.example.macamp.settings.ai.connector.consentedIds"
    static let keyConnectorID = AnthropicConnector.connectorID

    /// Computed, not `static let`: `AppEnvironment` is `@MainActor`, and a static
    /// initializer would run its expression in a nonisolated context.
    static var otherKeyConnectorID: String {
        AppEnvironment.openAIConnectorID
    }

    static var hostConnectorID: String {
        AppEnvironment.ollamaConnectorID
    }

    static var account: String {
        AppEnvironment.connectorAPIKeyAccount
    }

    static func store(named name: String) -> UserDefaults {
        guard let store = UserDefaults(suiteName: name) else { return .standard }
        store.removePersistentDomain(forName: name)
        return store
    }

    static func configuration(id: String) -> IntelligenceConnectorConfiguration {
        IntelligenceConnectorConfiguration(id: id, displayName: "Anthropic Claude", credential: .apiKey)
    }

    static func keyModel(
        settings: CountingConnectorSettings,
        secrets: InMemorySecretStore,
        connectorID: String = IntelligenceConsentTests.keyConnectorID
    ) -> IntelligenceConnectorConfigModel {
        IntelligenceConnectorConfigModel(
            configuration: configuration(id: connectorID),
            settings: settings,
            secrets: secrets,
            probe: { _, _ in .unconfigured }
        )
    }

    static func hostModel(
        settings: CountingConnectorSettings,
        secrets: InMemorySecretStore
    ) -> IntelligenceConnectorConfigModel {
        IntelligenceConnectorConfigModel(
            configuration: IntelligenceConnectorConfiguration(
                id: hostConnectorID,
                displayName: "Ollama",
                credential: .host
            ),
            settings: settings,
            secrets: secrets,
            probe: { _, _ in .unconfigured }
        )
    }

    static func text(_ resource: LocalizedStringResource) -> String {
        resource.resolved(in: Locale(identifier: "en"))
    }
}
