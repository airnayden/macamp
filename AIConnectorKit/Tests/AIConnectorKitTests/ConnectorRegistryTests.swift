// ConnectorRegistryTests — the registry is a generic ordered container.
//
// The assertions here are deliberately about SHAPE, not about providers: that
// registration order survives, that re-registering an id replaces it in place,
// that an unknown id resolves to nothing, and that a connector the kit has never
// heard of registers exactly like a shipped one. A registry that hardcoded
// MacAMP's three providers would fail the last of those.
//
// The one behavioural claim is the disabled short-circuit: a descriptor carrying a
// reason answers `.disabled` without calling its connector at all, which is the
// "an unusable connector must not spend a round-trip" rule applied one layer above
// the unconfigured case that `ConnectorRegistryProbeTests` pins.
import AIConnectorKit
import Foundation
import Testing

/// Fixture plumbing shared by both registry suites.
///
/// Internal rather than `private` on purpose — `ConnectorRegistryProbeTests` reads
/// the same fixtures, and a second copy of this loader is exactly the duplication
/// the sibling suites' own loaders already show the cost of. Fixtures load through
/// `#filePath`, the repo's established pattern, so the manifest needs no resource
/// declaration.
enum RegistryFixture {
    static let openAIModels = "openai-models.json"
    static let openAIUnauthorized = "openai-error-401.json"
    static let ollamaTags = "ollama-tags.json"

    static func data(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures")
            .appending(path: name)
        return try Data(contentsOf: url)
    }

    static func response(_ name: String, statusCode: Int = 200) throws -> HTTPResponse {
        try HTTPResponse(statusCode: statusCode, body: data(name))
    }

    static func transport(_ name: String, statusCode: Int = 200) throws -> FakeHTTPTransport {
        try FakeHTTPTransport(scripts: [.success(response(name, statusCode: statusCode))])
    }

    /// An OpenAI connector with a usable key, so the credential step never
    /// short-circuits a test that meant to exercise the transport.
    static func openAI(transport: FakeHTTPTransport, key: String = "sk-registry-test") -> OpenAIConnector {
        OpenAIConnector(apiKey: { key }, transport: transport)
    }

    static func ollama(transport: FakeHTTPTransport) -> OllamaConnector {
        OllamaConnector(transport: transport)
    }

    static func anthropic(transport: FakeHTTPTransport) -> AnthropicConnector {
        AnthropicConnector(auth: .apiKey(provider: { "sk-ant-registry-test" }), transport: transport)
    }
}

/// A connector from a provider this kit has never heard of.
///
/// Its whole job is to prove the registry hardcodes nothing: an arbitrary id, an
/// arbitrary display name, and a `probe()` that OVERRIDES the `listModels()`-based
/// default — the same override a subscription connector needs when it can answer
/// from a stored credential without a refresh.
private struct RegistryStubConnector: AIProviderConnector, ConnectorProbing {
    let id: String
    let displayName: String
    let authDescriptor: AuthDescriptor = .subscription
    var probeDelay: Duration = .zero
    var probeResult: ConnectorStatus = .ready(models: nil)

    func probe() async -> ConnectorStatus {
        if probeDelay > .zero {
            try? await Task.sleep(for: probeDelay)
        }
        return probeResult
    }

    func listModels() async throws -> [ModelInfo] {
        throw ConnectorFailure.unconfigured
    }

    func structuredCompletion(
        schema _: JSONSchemaObject,
        instructions _: String,
        prompt _: String,
        model _: String
    ) async throws -> Data {
        throw ConnectorFailure.unconfigured
    }

    func completion(instructions _: String, prompt _: String, model _: String) async throws -> String {
        throw ConnectorFailure.unconfigured
    }
}

@Suite("ConnectorRegistryTests")
struct ConnectorRegistryTests {
    @Test("An empty registry is a legal, fully-answerable state")
    func anEmptyRegistryAnswersEveryQuestion() async {
        let registry = ConnectorRegistry()

        #expect(registry.isEmpty)
        #expect(registry.ids.isEmpty)
        #expect(registry.descriptors.isEmpty)
        #expect(registry.descriptor(id: "ollama") == nil)
        #expect(registry.connector(id: "ollama") == nil)
        #expect(await registry.probe(id: "ollama") == nil)
        #expect(await registry.probeAll().isEmpty)
    }

    @Test("Registration order is the order the picker lists connectors in")
    func registrationOrderIsPreserved() {
        var registry = ConnectorRegistry()
        registry.register(RegistryFixture.ollama(transport: FakeHTTPTransport()))
        registry.register(RegistryFixture.openAI(transport: FakeHTTPTransport()))
        registry.register(RegistryFixture.anthropic(transport: FakeHTTPTransport()))

        #expect(registry.ids == ["ollama", "openai", "anthropic"])
        #expect(registry.descriptors.map(\.displayName) == ["Ollama", "OpenAI", "Anthropic Claude"])
        #expect(registry.descriptor(id: "openai")?.authDescriptor == .apiKey(header: "Authorization"))
        #expect(registry.connector(id: "anthropic")?.id == "anthropic")
        #expect(registry.isEmpty == false)
    }

    @Test("The registry hardcodes no provider — an unknown connector registers identically")
    func anUnknownConnectorRegistersLikeAShippedOne() async {
        var registry = ConnectorRegistry()
        registry.register(RegistryFixture.ollama(transport: FakeHTTPTransport()))
        registry.register(RegistryStubConnector(id: "never-heard-of-it", displayName: "Somebody Else"))

        #expect(registry.ids == ["ollama", "never-heard-of-it"])
        #expect(registry.descriptor(id: "never-heard-of-it")?.displayName == "Somebody Else")
        #expect(await registry.probe(id: "never-heard-of-it") == .ready(models: nil))
    }

    @Test("Re-registering an id replaces it IN PLACE, keeping its position")
    func reRegisteringAnIDReplacesItInPlace() async throws {
        let stale = FakeHTTPTransport()
        let fresh = try RegistryFixture.transport(RegistryFixture.ollamaTags)

        var registry = ConnectorRegistry()
        registry.register(RegistryFixture.ollama(transport: stale))
        registry.register(RegistryFixture.openAI(transport: FakeHTTPTransport()))
        registry.register(RegistryFixture.ollama(transport: fresh))

        // Position survives — a rebuilt graph must not reshuffle the picker.
        #expect(registry.ids == ["ollama", "openai"])

        let status = try #require(await registry.probe(id: "ollama"))
        #expect(status.reportedModels?.map(\.id) == ["llama3.2:latest", "qwen2.5:7b", "mistral-small:24b"])
        #expect(await fresh.recordedRequests.count == 1)
        #expect(await stale.recordedRequests.isEmpty)
    }

    @Test("An unknown id resolves to nothing, which is not a status")
    func anUnknownIDIsDistinctFromEveryStatus() async {
        var registry = ConnectorRegistry()
        registry.register(RegistryFixture.openAI(transport: FakeHTTPTransport()))

        #expect(registry.descriptor(id: "claude-subscription") == nil)
        #expect(registry.connector(id: "claude-subscription") == nil)
        #expect(await registry.probe(id: "claude-subscription") == nil)
    }

    @Test("A disabled connector reports its token and never touches its transport")
    func aDisabledConnectorNeverReachesItsTransport() async throws {
        let transport = try RegistryFixture.transport(RegistryFixture.openAIModels)
        var registry = ConnectorRegistry()
        registry.register(
            RegistryFixture.openAI(transport: transport),
            disabledReason: ConnectorStatus.DisabledReason.upstreamFlowUnavailable
        )

        let status = try #require(await registry.probe(id: "openai"))

        #expect(status == .disabled(reason: "upstream-flow-unavailable"))
        #expect(status.isReady == false)
        #expect(status.reportedModels == nil)
        // The whole point: a build that cannot use a connector spends nothing
        // finding that out, on every probe, forever.
        #expect(await transport.recordedRequests.isEmpty)
        #expect(registry.descriptor(id: "openai")?.disabledReason == "upstream-flow-unavailable")
    }

    @Test("probeAll returns results in REGISTRATION order, not completion order")
    func probeAllIsOrderedByRegistrationNotByWhoAnswersFirst() async {
        var registry = ConnectorRegistry()
        registry.register(RegistryStubConnector(
            id: "slow",
            displayName: "Slow",
            probeDelay: .milliseconds(120),
            probeResult: .ready(models: [ModelInfo(id: "slow-1")])
        ))
        registry.register(RegistryStubConnector(id: "fast", displayName: "Fast", probeResult: .authExpired))
        registry.register(RegistryStubConnector(
            id: "off",
            displayName: "Off",
            probeResult: .disabled(reason: ConnectorStatus.DisabledReason.notLinkedInThisBuild)
        ))

        let results = await registry.probeAll()

        #expect(results.map(\.id) == ["slow", "fast", "off"])
        #expect(results.map(\.status) == [
            .ready(models: [ModelInfo(id: "slow-1")]),
            .authExpired,
            .disabled(reason: "not-linked-in-this-build"),
        ])
    }

    @Test("A registry built from an array dedupes exactly like register(_:)")
    func arrayInitialisationAppliesTheSameReplacementRule() {
        let first = RegistryStubConnector(id: "dup", displayName: "First")
        let second = RegistryStubConnector(id: "dup", displayName: "Second")
        let other = RegistryStubConnector(id: "other", displayName: "Other")

        let registry = ConnectorRegistry([
            ConnectorDescriptor(first),
            ConnectorDescriptor(other),
            ConnectorDescriptor(second),
        ])

        #expect(registry.ids == ["dup", "other"])
        #expect(registry.descriptor(id: "dup")?.displayName == "Second")
    }
}
