// IntelligenceProviderModelTests — the Intelligence pane's provider surface, without a pane.
//
// A SwiftUI `View` cannot be asserted on, so everything the provider section
// decides lives in two testable types and is pinned here:
//
//  * `IntelligenceProviderModel` — what one probe leaves behind: the model list the
//    picker offers, and the fact that a FAILED probe settles rather than wedging.
//  * `IntelligenceActiveTier` — which tier the status row speaks for, which is the
//    todo's central claim: a selected connector outranks Apple Intelligence even on
//    a Mac that cannot run the on-device model at all.
//
// Plus the localization contract the kit depends on the shell to honour: a
// `ConnectorStatus.disabled(reason:)` token and a `ConnectorFailure` diagnostic
// token are MACHINE values, and neither may ever appear in rendered copy. Those
// assertions resolve through the real catalog — this target is hosted by
// `macampMac`, so `macOS/Sources/Localizable.xcstrings` is actually loaded.
//
// Nothing here touches the network, the Keychain or a real provider: every case
// drives a stub connector through a hand-built registry.
import AIConnectorKit
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Intelligence provider model")
@MainActor
struct IntelligenceProviderModelTests {
    // MARK: The model picker

    @Test("a ready connector's reported models are exactly what the picker offers")
    func aReadyConnectorPopulatesTheModelList() async {
        let connector = StubConnector(models: [ModelInfo(id: "small"), ModelInfo(id: "large")])
        let model = IntelligenceProviderModel()

        await model.reload(connectorID: StubConnector.identifier, registry: Self.registry(connector))

        #expect(model.reportedModels?.map(\.id) == ["small", "large"])
        #expect(model.selection?.displayName == StubConnector.name)
        #expect(model.selection?.isProbing == false)
    }

    @Test("an empty model list is a real answer, not the absence of one")
    func anEmptyListIsDistinctFromNoList() async {
        let model = IntelligenceProviderModel()

        await model.reload(connectorID: StubConnector.identifier, registry: Self.registry(StubConnector(models: [])))

        // `[]` — the provider listed nothing (a fresh Ollama with no model pulled).
        #expect(model.reportedModels == [])
        #expect(model.selection?.status == .ready(models: []))
    }

    @Test("an id no build registers clears the selection instead of dangling")
    func anUnregisteredSelectionFallsBackToAppleIntelligence() async {
        let model = IntelligenceProviderModel()
        await model.reload(connectorID: StubConnector.identifier, registry: Self.registry(StubConnector()))
        #expect(model.selection != nil)

        await model.reload(connectorID: "a-provider-from-a-newer-release", registry: model.registry)

        #expect(model.selection == nil)
        #expect(model.reportedModels == nil)
        #expect(IntelligenceActiveTier(availability: .available, selection: nil)?.providerName == nil)
    }

    // MARK: The active tier

    @Test("a selected connector's status outranks an unavailable Apple Intelligence")
    func aConnectorOutranksTheOnDeviceTier() async throws {
        let model = IntelligenceProviderModel()
        await model.reload(connectorID: StubConnector.identifier, registry: Self.registry(StubConnector()))

        let tier = try #require(IntelligenceActiveTier(
            availability: .unavailable(reason: .deviceNotEligible),
            selection: model.selection
        ))

        #expect(tier.providerName == StubConnector.name)
        #expect(tier.connectorID == StubConnector.identifier)
        #expect(tier.isHealthy)
        #expect(!tier.showsHeuristicFallbackNotice)
        // The row says the CONNECTOR is ready, never "this Mac cannot run the model".
        #expect(Self.text(tier.message) != Self.text(AssistantUnavailableReason.deviceNotEligible.message))
        #expect(Self.text(tier.message) == Self.text(PreferencesStrings.connectorReadyModels(count: 1)))
    }

    @Test("with nothing selected the row still speaks for Apple Intelligence")
    func theDefaultTierIsUnchanged() throws {
        let tier = try #require(IntelligenceActiveTier(availability: .available, selection: nil))

        #expect(tier.providerName == nil)
        #expect(tier.isHealthy)
        #expect(Self.text(tier.message) == Self.text(PreferencesStrings.intelligenceStatusAvailable))
    }

    @Test("a selection whose first probe is still running reports checking, not ready")
    func anUnfinishedProbeIsNotYetHealthy() throws {
        let pending = IntelligenceProviderModel.Selection(
            id: StubConnector.identifier,
            displayName: StubConnector.name,
            status: nil,
            isProbing: true
        )

        let tier = try #require(IntelligenceActiveTier(availability: .available, selection: pending))

        #expect(!tier.isHealthy)
        #expect(!tier.showsHeuristicFallbackNotice)
        #expect(Self.text(tier.message) == Self.text(PreferencesStrings.intelligenceConnectorChecking))
    }

    // MARK: Failure

    @Test("a probe failure settles into unreachable instead of wedging the pane")
    func aFailedProbeRendersUnreachable() async throws {
        let refused = ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.connectionRefused)
        let model = IntelligenceProviderModel()

        await model.reload(
            connectorID: StubConnector.identifier,
            registry: Self.registry(StubConnector(failure: refused))
        )

        #expect(model.selection?.status == .unreachable(refused))
        // NOT wedged: the spinner stops and the refresh button becomes usable again.
        #expect(model.selection?.isProbing == false)
        #expect(model.reportedModels == nil)

        let tier = try #require(IntelligenceActiveTier(availability: .available, selection: model.selection))
        #expect(!tier.isHealthy)
        #expect(tier.showsHeuristicFallbackNotice)
        #expect(Self.text(tier.message) == Self.text(PreferencesStrings.connectorConnectionRefused))
        #expect(!Self.text(tier.message).contains(ConnectorFailure.DiagnosticToken.connectionRefused))
    }

    @Test("every unreachable diagnostic token maps to copy that never contains it")
    func noDiagnosticTokenIsEverRendered() {
        let tokens = [
            ConnectorFailure.DiagnosticToken.connectionRefused,
            ConnectorFailure.DiagnosticToken.hostNotFound,
            ConnectorFailure.DiagnosticToken.networkUnavailable,
            ConnectorFailure.DiagnosticToken.secureConnectionFailed,
            ConnectorFailure.DiagnosticToken.invalidResponse,
            ConnectorFailure.DiagnosticToken.transportFailure,
            "a-token-from-a-newer-release",
        ]

        for token in tokens {
            let rendered = Self.text(
                PreferencesStrings.connectorStatusMessage(.unreachable(.unreachable(underlying: token)))
            )
            #expect(!rendered.isEmpty, "\(token) rendered nothing")
            #expect(!rendered.contains(token), "\(token) leaked into the UI")
        }
    }

    // MARK: Disabled

    @Test("both disabled tokens render their own mapped copy, never the token")
    func aDisabledConnectorRendersMappedCopy() {
        let mapped: [(String, LocalizedStringResource)] = [
            (ConnectorStatus.DisabledReason.upstreamFlowUnavailable, PreferencesStrings.connectorDisabledUpstream),
            (ConnectorStatus.DisabledReason.notLinkedInThisBuild, PreferencesStrings.connectorDisabledNotLinked),
        ]

        for (token, expected) in mapped {
            let rendered = Self.text(PreferencesStrings.connectorStatusMessage(.disabled(reason: token)))
            #expect(rendered == Self.text(expected))
            #expect(!rendered.contains(token))
            // Specific copy, not the catch-all — the whole reason the token exists.
            #expect(rendered != Self.text(PreferencesStrings.connectorDisabled))
        }
    }

    @Test("an unrecognised disabled token degrades to generic copy rather than leaking")
    func anUnknownDisabledTokenDegrades() {
        let rendered = Self.text(PreferencesStrings.connectorStatusMessage(.disabled(reason: "not-yet-mapped")))

        #expect(rendered == Self.text(PreferencesStrings.connectorDisabled))
        #expect(!rendered.contains("not-yet-mapped"))
    }

    @Test("a registry-disabled connector reaches the pane as disabled, unprobed")
    func aDisabledDescriptorShortCircuitsTheProbe() async throws {
        let connector = StubConnector(failure: .timeout)
        var registry = ConnectorRegistry()
        registry.register(connector, disabledReason: ConnectorStatus.DisabledReason.notLinkedInThisBuild)
        let model = IntelligenceProviderModel()

        await model.reload(connectorID: StubConnector.identifier, registry: registry)

        // The descriptor answered without calling the connector — a `.timeout` stub
        // would otherwise have surfaced as `.unreachable`.
        #expect(model.selection?.status == .disabled(reason: ConnectorStatus.DisabledReason.notLinkedInThisBuild))
        let tier = try #require(IntelligenceActiveTier(availability: .available, selection: model.selection))
        #expect(Self.text(tier.message) == Self.text(PreferencesStrings.connectorDisabledNotLinked))
        #expect(tier.showsHeuristicFallbackNotice)
    }

    // MARK: Totality

    @Test("every ConnectorStatus case renders non-empty catalog copy")
    func everyStatusCaseIsRenderable() {
        let statuses: [ConnectorStatus] = [
            .unconfigured,
            .ready(models: nil),
            .ready(models: []),
            .ready(models: [ModelInfo(id: "small")]),
            .unreachable(.timeout),
            .unreachable(.httpStatus(503, body: nil, providerMessage: nil)),
            .unreachable(.rateLimited(retryAfter: 30)),
            .unreachable(.malformedResponse),
            .unreachable(.cancelled),
            .authExpired,
            .disabled(reason: ConnectorStatus.DisabledReason.upstreamFlowUnavailable),
        ]

        for status in statuses {
            #expect(!Self.text(PreferencesStrings.connectorStatusMessage(status)).isEmpty)
        }
        // The HTTP code is DATA and must survive into the sentence.
        let httpFailure = ConnectorFailure.httpStatus(503, body: nil, providerMessage: nil)
        let httpMessage = Self.text(PreferencesStrings.connectorStatusMessage(.unreachable(httpFailure)))
        #expect(httpMessage.contains("503"))
    }

    // MARK: Helpers

    private static func registry(_ connector: StubConnector) -> ConnectorRegistry {
        var registry = ConnectorRegistry()
        registry.register(connector)
        return registry
    }

    /// Resolved through the app bundle's catalog, in a fixed locale — so a key that
    /// never reached `Localizable.xcstrings` still renders its `defaultValue` and
    /// the token assertions stay meaningful either way.
    private static func text(_ resource: LocalizedStringResource) -> String {
        resource.resolved(in: Locale(identifier: "en"))
    }
}

// MARK: - Stub provider

/// A connector that answers from a fixture, or throws one. Enough to drive the
/// real `ConnectorProbing` default probe, which is what turns `listModels()` into
/// a `ConnectorStatus`.
private struct StubConnector: AIProviderConnector, ConnectorProbing {
    static let identifier = "macamp.tests.stub"
    static let name = "Stub Provider"

    var models: [ModelInfo] = [ModelInfo(id: "small")]
    var failure: ConnectorFailure?

    var id: String {
        Self.identifier
    }

    var displayName: String {
        Self.name
    }

    var authDescriptor: AuthDescriptor {
        .apiKey(header: "x-api-key")
    }

    func listModels() async throws -> [ModelInfo] {
        if let failure { throw failure }
        return models
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
}
