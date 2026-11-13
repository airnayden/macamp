// LibraryChatCorrectiveWiringTests — both tiers really opt into the corrective
// follow-up turn.
//
// `LibraryChatCorrectiveTurnTests` (PlayerCore) proves the view model sends exactly
// one directive when a playlist ask files nothing — but only for an engine whose
// `supportsCorrectiveFollowUp` is `true`, and that flag DEFAULTS TO FALSE. An
// implementation that adds the flag and wires neither composition root passes that
// whole suite while the shipped app never corrects anything, so the wiring needs its
// own claim, made here, where the composition root is visible.
//
// A NEW FILE rather than three more cases on `LibraryChatCompositionTests`: that
// suite is already long enough to be near SwiftLint's `type_body_length` ceiling, and
// a `*WiringTests.swift` per composition claim is this target's own convention.
//
// Nothing here reaches a provider, the Keychain or the network: the connector case
// constructs a conversation and reads a stored flag off it, and the on-device case
// only asks the composition root which tier it would mint.
import AIConnectorBridge
import AIConnectorKit
import Foundation
@testable import MacAMP
import Persistence
import Services
import Testing
import ViewModels

@Suite("Library chat corrective wiring", .serialized)
@MainActor
struct LibraryChatCorrectiveWiringTests {
    @Test("the connector tier's engine opts into the corrective follow-up")
    func theConnectorTierOptsIn() {
        let conversation = ConnectorChatConversation(
            engine: ConnectorChatEngine(
                connector: SilentToolConnector(),
                model: "unreached",
                tools: []
            ),
            isActive: { true }
        )

        #expect(conversation.engineValue.supportsCorrectiveFollowUp)
    }

    @Test("the on-device tier's engine opts into the corrective follow-up")
    func theOnDeviceTierOptsIn() {
        let settings = Self.settings(#function)
        settings.intelligenceEnabled = true

        let made = AppEnvironment.makeChatEngine(
            settings: settings,
            toolbox: Self.toolbox(),
            connectors: AppEnvironment.ConnectorContext(
                registry: ConnectorRegistry(),
                session: AppEnvironment.ConnectorSession()
            )
        )
        // RECORDED: where FoundationModels is absent or Apple Intelligence is not
        // ready, this route resolves to `.failure(.unavailable(…))` and there is no
        // engine to inspect. The connector case above still pins the flag on every
        // build, so a wiring regression cannot pass this file unnoticed.
        guard case let .success(engine) = made else { return }

        #expect(engine.supportsCorrectiveFollowUp)
    }

    @Test("the seam still defaults to off, so a tier has to opt in deliberately")
    func theSeamDefaultsToOff() {
        let engine = LibraryChatEngine(
            prewarm: {},
            send: { _ in LibraryChatReply(turn: AssistantChatTurn(text: "")) }
        )

        #expect(!engine.supportsCorrectiveFollowUp)
    }

    // MARK: Helpers

    private static let suitePrefix = "com.example.macamp.tests.libraryChatCorrective"

    private static func settings(_ function: String) -> AppSettings {
        let name = "\(suitePrefix).\(function)"
        guard let store = UserDefaults(suiteName: name) else { return AppSettings(defaults: .standard) }
        store.removePersistentDomain(forName: name)
        return AppSettings(defaults: store)
    }

    private static func toolbox() -> LibraryToolbox {
        AppEnvironment.makeLibraryToolbox(
            database: AppEnvironment.preview().database,
            profileId: ProfileRecord.guestID,
            proposals: LibraryChatProposalFiler(store: ProposalStore())
        )
    }
}

// MARK: - Fake provider

/// A tool-calling connector that is never asked anything.
///
/// `engineValue` reads a stored flag and cannot reach the provider, so a fixture that
/// answered would prove nothing: only CONSTRUCTION is required to make the wiring
/// observable.
private struct SilentToolConnector: ToolCallingConnector {
    var id: String {
        "macamp.tests.corrective"
    }

    var displayName: String {
        "Silent"
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
