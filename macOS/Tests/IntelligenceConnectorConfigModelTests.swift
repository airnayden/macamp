// IntelligenceConnectorConfigModelTests — the commit-on-submit contract, proved by counting.
//
// The claim this todo makes is negative — "typing writes NOTHING" — and a negative
// claim about writes cannot be checked by looking at the end state: a sheet that
// wrote twenty times and a sheet that wrote once leave identical settings. So both
// stores count. `InMemorySecretStore` already ships `writeCount` / `deleteCount`
// (built for exactly this), and `CountingConnectorSettings` mirrors it for the
// non-secret half.
//
// Property observers do NOT fire during initialization, so a fake seeded with a
// starting selection begins at `writeCount == 0` and every later increment is a
// real write.
//
// The validation tests drive the REAL `AnthropicConnector` and `OllamaConnector`
// over a scripted transport rather than a stub connector: the claim under test is
// that a 401 becomes `ConnectorStatus.authExpired` all the way to the sheet, and a
// stub that simply returned `.authExpired` would prove only that the enum exists.
// Nothing here touches the network, the real Keychain, or `UserDefaults`.
import AIConnectorBridge
import AIConnectorKit
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Intelligence connector config model")
@MainActor
struct IntelligenceConnectorConfigModelTests {
    // MARK: Commit-on-submit

    @Test("typing an API key writes to neither store until Save")
    func typingAKeyPerformsNoWritesUntilSave() async throws {
        // Pre-consented: this test is about WHEN the write happens, not about the
        // disclosure gate — that is `IntelligenceConsentTests`' subject.
        let settings = CountingConnectorSettings(consented: [Self.keyConnectorID])
        let secrets = InMemorySecretStore()
        let model = Self.keyModel(settings: settings, secrets: secrets)
        await model.prepare()
        await secrets.resetCounters()

        for prefix in ["s", "sk", "sk-", "sk-l", "sk-live"] {
            model.draft = prefix
        }

        #expect(settings.writeCount == 0)
        #expect(await secrets.writeCount == 0)

        await model.save()

        // EXACTLY one of each: the Keychain entry, and the selection that activates it.
        #expect(await secrets.writeCount == 1)
        #expect(settings.writeCount == 1)
        let stored = try await secrets.get(service: model.service, account: Self.account)
        #expect(stored == "sk-live")
        #expect(settings.selectedConnectorID == Self.keyConnectorID)
        // The draft is surrendered on commit — the sheet never keeps a copy.
        #expect(model.draft.isEmpty)
        #expect(model.hasStoredSecret)
    }

    @Test("typing a server address writes nothing until Save, then writes once")
    func typingAHostPerformsNoWritesUntilSave() async {
        // A server that is not on this machine is remote, so it is pre-consented
        // here for the same reason the key test is.
        let settings = CountingConnectorSettings(consented: [Self.hostConnectorID])
        let secrets = InMemorySecretStore()
        let model = Self.hostModel(settings: settings, secrets: secrets)
        await model.prepare()

        for fragment in ["h", "http", "http://box", "http://box:11434"] {
            model.draft = fragment
        }

        #expect(settings.writeCount == 0)

        await model.save()

        #expect(settings.writeCount == 1)
        #expect(settings.ollamaHost == "http://box:11434")
        // An address needs no secret, so the Keychain is never touched at all.
        #expect(await secrets.writeCount == 0)
    }

    @Test("a blank address commits as absence, which resolves to the standard one")
    func aBlankHostSavesAsNil() async {
        let settings = CountingConnectorSettings(ollamaHost: "http://stale:1")
        let model = Self.hostModel(settings: settings, secrets: InMemorySecretStore())
        await model.prepare()
        #expect(model.draft == "http://stale:1")

        model.draft = "   "
        await model.save()

        #expect(settings.ollamaHost == nil)
        #expect(settings.writeCount == 1)
        #expect(AppEnvironment.ollamaHost(settings.ollamaHost) == OllamaConnector.defaultHost)
    }

    @Test("a blank key cannot be saved and writing is refused outright")
    func aBlankKeyIsRefused() async {
        let settings = CountingConnectorSettings()
        let secrets = InMemorySecretStore()
        let model = Self.keyModel(settings: settings, secrets: secrets)
        model.draft = "   "

        #expect(!model.canSave)
        await model.save()

        #expect(settings.writeCount == 0)
        #expect(await secrets.writeCount == 0)
        #expect(await secrets.storedSecretCount == 0)
    }

    // MARK: The key is never read back

    @Test("a stored key is reported but never seeded into the field")
    func theKeyFieldIsNeverSeededWithTheStoredSecret() async throws {
        let secrets = InMemorySecretStore()
        let model = Self.keyModel(settings: CountingConnectorSettings(), secrets: secrets)
        try await secrets.set("sk-already-there", service: model.service, account: Self.account)

        await model.prepare()

        #expect(model.hasStoredSecret)
        // The whole point of a SecureField: the value stays where it was put.
        #expect(model.draft.isEmpty)
        #expect(!model.draft.contains("sk-already-there"))
    }

    // MARK: Remove

    @Test("Remove deletes the secret and falls back to Apple Intelligence")
    func removeDeletesTheSecretAndClearsAnActiveSelection() async throws {
        let settings = CountingConnectorSettings(selectedConnectorID: Self.keyConnectorID)
        let secrets = InMemorySecretStore()
        let model = Self.keyModel(settings: settings, secrets: secrets)
        try await secrets.set("sk-live", service: model.service, account: Self.account)
        await model.prepare()
        #expect(model.hasStoredSecret)

        await model.remove()

        let survivor = try await secrets.get(service: model.service, account: Self.account)
        #expect(survivor == nil)
        #expect(await secrets.storedSecretCount == 0)
        // `nil` IS the shipped default: on-device, zero network.
        #expect(settings.selectedConnectorID == nil)
        #expect(!model.hasStoredSecret)
        #expect(model.validation == .idle)
    }

    @Test("Remove leaves a different provider's selection alone")
    func removeDoesNotDisturbAnotherProvidersSelection() async {
        let settings = CountingConnectorSettings(selectedConnectorID: "some-other-provider")
        let model = Self.keyModel(settings: settings, secrets: InMemorySecretStore())

        await model.remove()

        #expect(settings.selectedConnectorID == "some-other-provider")
    }

    @Test("Remove on a never-configured connector is not an error path")
    func removeIsIdempotent() async {
        let secrets = InMemorySecretStore()
        let model = Self.keyModel(settings: CountingConnectorSettings(), secrets: secrets)

        await model.remove()

        #expect(await secrets.deleteCount == 1)
        #expect(await secrets.storedSecretCount == 0)
    }

    // MARK: Validation

    @Test("a 401 from the real connector surfaces as authExpired")
    func validateSurfacesAuthExpiredOnA401() async {
        let model = Self.keyModel(
            settings: CountingConnectorSettings(),
            secrets: InMemorySecretStore(),
            probe: Self.anthropicProbe(response: HTTPResponse(
                statusCode: 401,
                body: Data(#"{"type":"error","error":{"type":"authentication_error"}}"#.utf8)
            ))
        )
        model.draft = "sk-rejected"

        await model.validate()

        #expect(model.validation == .finished(.authExpired))
        // Rendered through the SHARED mapping, so the sheet invents no wording.
        #expect(Self.text(PreferencesStrings.connectorStatusMessage(.authExpired))
            == Self.text(PreferencesStrings.connectorAuthExpired))
    }

    @Test("a reachable server reports the models it listed, without saving anything")
    func validateSurfacesTheListedModels() async {
        let settings = CountingConnectorSettings()
        let secrets = InMemorySecretStore()
        let model = Self.hostModel(
            settings: settings,
            secrets: secrets,
            probe: Self.ollamaProbe(response: HTTPResponse(
                statusCode: 200,
                body: Data(#"{"models":[{"name":"llama3.2:latest"}]}"#.utf8)
            ))
        )
        model.draft = "http://box:11434"

        await model.validate()

        guard case let .finished(status) = model.validation else {
            Issue.record("the check never settled: \(model.validation)")
            return
        }
        #expect(status.isReady)
        #expect(status.reportedModels?.map(\.id) == ["llama3.2:latest"])
        // A check is not a commit.
        #expect(settings.writeCount == 0)
        #expect(await secrets.writeCount == 0)
    }

    @Test("a check moves through checking and settles, never wedging")
    func validationSettlesFromIdle() async {
        let model = Self.keyModel(
            settings: CountingConnectorSettings(),
            secrets: InMemorySecretStore(),
            probe: Self.anthropicProbe(response: HTTPResponse(statusCode: 500))
        )
        #expect(model.validation == .idle)
        model.draft = "sk-live"

        await model.validate()

        // An EMPTY error payload is reported as no payload, never as `""`.
        #expect(model.validation == .finished(.unreachable(.httpStatus(500, body: nil, providerMessage: nil))))
        #expect(model.validation != .checking)
    }

    // MARK: Which connectors get a sheet

    @Test("a credential kind is derived from the auth descriptor, not from an id")
    func credentialKindsMapFromTheAuthDescriptor() {
        #expect(IntelligenceConnectorCredential(.none(defaultHost: OllamaConnector.defaultHost)) == .host)
        #expect(IntelligenceConnectorCredential(.apiKey(header: "x-api-key")) == .apiKey)
        // A sign-in flow has nothing to type, so it gets no setup sheet.
        #expect(IntelligenceConnectorCredential(.subscription) == nil)
    }

    @Test("the shell's Ollama id constant still matches the one the kit publishes")
    func connectorIDConstantsMatchTheKit() {
        #expect(AppEnvironment.ollamaConnectorID == OllamaConnector(transport: SilentTransport()).id)
    }

    @Test("the shipped registry offers a sheet for exactly the typeable providers")
    func theRegistryYieldsConfigurationsForTypeableProviders() {
        var registry = ConnectorRegistry()
        registry.register(OllamaConnector(transport: SilentTransport()))
        registry.register(SubscriptionStub())
        let configurations = registry.descriptors.compactMap(IntelligenceConnectorConfiguration.init(descriptor:))

        #expect(configurations.map(\.id) == [Self.hostConnectorID])
        #expect(configurations.first?.credential == .host)
    }

    // MARK: Locality (the seam todo 16's consent gate reads)

    @Test("locality is judged on the draft being committed, not on what was saved")
    func localityFollowsTheDraft() async {
        let model = Self.hostModel(settings: CountingConnectorSettings(), secrets: InMemorySecretStore())
        await model.prepare()

        // Empty resolves to the connector's own loopback default.
        #expect(model.isLocalOnly)
        model.draft = "http://127.0.0.1:11434"
        #expect(model.isLocalOnly)
        model.draft = "http://ollama.example.com:11434"
        #expect(!model.isLocalOnly)
        // An API key always leaves the machine, whatever is typed.
        #expect(!Self.keyModel(settings: CountingConnectorSettings(), secrets: InMemorySecretStore()).isLocalOnly)
    }
}

// MARK: - Builders

private extension IntelligenceConnectorConfigModelTests {
    static let keyConnectorID = AnthropicConnector.connectorID

    /// The composition root's constant, pinned against the kit by
    /// ``connectorIDConstantsMatchTheKit()`` so the two cannot drift apart.
    static var hostConnectorID: String {
        AppEnvironment.ollamaConnectorID
    }

    /// The Keychain slot the composition root reads, named from the same constant
    /// the sheet writes through.
    static var account: String {
        AppEnvironment.connectorAPIKeyAccount
    }

    static func keyModel(
        settings: CountingConnectorSettings,
        secrets: InMemorySecretStore,
        probe: @escaping @MainActor (String, String) async -> ConnectorStatus = { _, _ in .unconfigured }
    ) -> IntelligenceConnectorConfigModel {
        IntelligenceConnectorConfigModel(
            configuration: IntelligenceConnectorConfiguration(
                id: keyConnectorID,
                displayName: "Anthropic Claude",
                credential: .apiKey
            ),
            settings: settings,
            secrets: secrets,
            probe: probe
        )
    }

    static func hostModel(
        settings: CountingConnectorSettings,
        secrets: InMemorySecretStore,
        probe: @escaping @MainActor (String, String) async -> ConnectorStatus = { _, _ in .unconfigured }
    ) -> IntelligenceConnectorConfigModel {
        IntelligenceConnectorConfigModel(
            configuration: IntelligenceConnectorConfiguration(
                id: hostConnectorID,
                displayName: "Ollama",
                credential: .host
            ),
            settings: settings,
            secrets: secrets,
            probe: probe
        )
    }

    /// The REAL connector over a scripted transport, so the status under test is
    /// the one the shipped mapping produces rather than one a stub asserted.
    static func anthropicProbe(response: HTTPResponse) -> @MainActor (String, String) async -> ConnectorStatus {
        { draft, _ in
            await AnthropicConnector(
                auth: .apiKey(provider: { draft }),
                transport: ScriptedTransport(response: response)
            ).probe()
        }
    }

    /// Threads the DRAFT key through too, so a suite can prove the optional
    /// bearer reaches the probe rather than only the saved one.
    static func ollamaProbe(response: HTTPResponse) -> @MainActor (String, String) async -> ConnectorStatus {
        { draft, secret in
            // Named, then made optional: a closure literal inside a `?:` infers a
            // NON-`@Sendable` function type, which the parameter refuses.
            let resolve: @Sendable () async throws -> String = { secret }
            return await OllamaConnector(
                host: AppEnvironment.ollamaHost(draft),
                apiKey: secret.isEmpty ? nil : resolve,
                transport: ScriptedTransport(response: response)
            ).probe()
        }
    }

    static func text(_ resource: LocalizedStringResource) -> String {
        resource.resolved(in: Locale(identifier: "en"))
    }
}
