// IntelligenceConnectorConfigFakes — the witnesses `IntelligenceConnectorConfigModelTests` drives.
//
// Split out for the usual mechanical reason — `file_length` is capped at 400 under
// `swiftlint --strict` and the suite crossed it — so these are `internal` rather
// than `private`: a `private` type cannot be seen from the file that uses it.
//
// Nothing here reaches a socket, the real Keychain, or `UserDefaults`. The counting
// settings witness is the only fake this todo needed to write: `InMemorySecretStore`
// already ships `readCount` / `writeCount` / `deleteCount` for exactly this claim.
import AIConnectorBridge
import AIConnectorKit
import Foundation
@testable import MacAMP

/// The non-secret half of the contract, counting every write.
///
/// Property observers do not run during initialization, so a seeded fake starts at
/// zero and each later increment is a genuine store mutation.
@MainActor
final class CountingConnectorSettings: AIConnectorSettingsProviding, IntelligenceConnectorConsentStoring {
    private(set) var writeCount = 0
    /// Counted separately from ``writeCount``: "consent was recorded" and "the
    /// connector was configured" are different claims, and todo 16's whole point is
    /// that the second cannot happen before the first.
    private(set) var consentCount = 0

    var selectedConnectorID: String? {
        didSet { writeCount += 1 }
    }

    var ollamaHost: String? {
        didSet { writeCount += 1 }
    }

    private var models: [String: String] = [:]
    private var consented: Set<String>

    init(selectedConnectorID: String? = nil, ollamaHost: String? = nil, consented: Set<String> = []) {
        self.selectedConnectorID = selectedConnectorID
        self.ollamaHost = ollamaHost
        self.consented = consented
    }

    func selectedModel(for connectorID: String) -> String? {
        models[connectorID]
    }

    func setSelectedModel(_ model: String?, for connectorID: String) {
        models[connectorID] = model
        writeCount += 1
    }

    func hasConsented(toConnectorID connectorID: String) -> Bool {
        consented.contains(connectorID)
    }

    func recordConsent(forConnectorID connectorID: String) {
        consented.insert(connectorID)
        consentCount += 1
    }
}

/// Answers every request with one scripted response. No network, no fixtures on
/// disk — the two bodies under test are three lines each.
struct ScriptedTransport: HTTPTransport {
    let response: HTTPResponse

    func send(_: URLRequest) async throws -> HTTPResponse {
        response
    }
}

/// Refuses to send at all: used where a connector is constructed purely to be
/// registered, so a stray request would be a test bug rather than a slow test.
struct SilentTransport: HTTPTransport {
    func send(_: URLRequest) async throws -> HTTPResponse {
        throw ConnectorFailure.unreachable(underlying: ConnectorFailure.DiagnosticToken.transportFailure)
    }
}

/// A connector whose credential is obtained by signing in — the case that must get
/// no setup sheet.
struct SubscriptionStub: AIProviderConnector, ConnectorProbing {
    let id = "macamp.tests.subscription"
    let displayName = "Subscription Stub"
    let authDescriptor = AuthDescriptor.subscription

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
}
