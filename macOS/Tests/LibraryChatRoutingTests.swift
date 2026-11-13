// LibraryChatRoutingTests — the whole gating matrix, as a table.
//
// This is the product decision in one place: which tier chats, when the
// library-browsing disclosure has to be shown, and what a listener is told when
// none of it is possible. Every case is pure, so none of it needs a model, a
// provider, a database or a running app.
import AIConnectorKit
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Library chat routing")
@MainActor
struct LibraryChatRoutingTests {
    private static let ollama = LibraryChatConnectorSelection(
        id: "ollama",
        displayName: "Ollama",
        supportsToolCalling: true,
        model: "llama3.2"
    )

    private static func availability(
        enabled: Bool = true,
        selection: LibraryChatConnectorSelection? = nil,
        consented: Bool = false,
        declined: Bool = false,
        appleIntelligence: AssistantAvailability = .available
    ) -> LibraryChatAvailability {
        LibraryChatRouting.availability(
            intelligenceEnabled: enabled,
            selection: selection,
            hasBrowsingConsent: consented,
            isConsentDeclined: declined,
            appleIntelligence: appleIntelligence
        )
    }

    // MARK: The master switch

    @Test("the top-level switch off beats everything, including a consented provider")
    func theTopLevelSwitchWins() {
        #expect(Self.availability(enabled: false) == .intelligenceOff)
        #expect(Self.availability(enabled: false, selection: Self.ollama, consented: true) == .intelligenceOff)
    }

    // MARK: Apple Intelligence

    @Test("no selection with a ready model is the shipped on-device route")
    func theDefaultIsOnDevice() {
        #expect(Self.availability() == .ready(.appleIntelligence))
    }

    @Test("an unreachable on-device model reports its own typed reason")
    func anUnreachableModelReportsItsReason() {
        let unavailable = AssistantAvailability.unavailable(reason: .deviceNotEligible)
        #expect(Self.availability(appleIntelligence: unavailable) == .appleIntelligenceUnavailable(.deviceNotEligible))
    }

    @Test("the on-device route NEVER consults the browsing consent record")
    func appleIntelligenceIsExemptFromTheDisclosure() {
        // Nothing leaves the Mac, so there is nothing to disclose. Proven by driving
        // both consent values through the same inputs and demanding one answer.
        #expect(Self.availability(consented: false) == .ready(.appleIntelligence))
        #expect(Self.availability(consented: true) == .ready(.appleIntelligence))
        #expect(Self.availability(declined: true) == .ready(.appleIntelligence))
    }

    // MARK: Connectors

    @Test("a consented tool-calling provider with a model is ready, and carries the model it showed")
    func aConsentedProviderIsReady() {
        #expect(Self.availability(selection: Self.ollama, consented: true)
            == .ready(.connector(id: "ollama", displayName: "Ollama", model: "llama3.2")))
    }

    @Test("an unconsented provider asks first")
    func anUnconsentedProviderAsksFirst() {
        #expect(Self.availability(selection: Self.ollama)
            == .consentRequired(id: "ollama", displayName: "Ollama"))
    }

    @Test("a declined provider is not asked again, and says so")
    func aDeclinedProviderIsNotReAsked() {
        #expect(Self.availability(selection: Self.ollama, declined: true)
            == .consentDeclined(id: "ollama", displayName: "Ollama"))
    }

    @Test("a decline outranks a stale acceptance, so declining always takes effect")
    func aDeclineOutranksConsent() {
        #expect(Self.availability(selection: Self.ollama, consented: true, declined: true)
            == .consentDeclined(id: "ollama", displayName: "Ollama"))
    }

    @Test("a provider that cannot call tools is refused before anything else is considered")
    func aNonToolCallingProviderIsRefused() {
        let selection = LibraryChatConnectorSelection(
            id: "legacy",
            displayName: "Legacy",
            supportsToolCalling: false,
            model: "m"
        )
        #expect(Self.availability(selection: selection, consented: true)
            == .providerCannotChat(id: "legacy", displayName: "Legacy"))
    }

    @Test("a provider with no model chosen is reported BEFORE the disclosure is offered")
    func aModellessProviderIsReportedBeforeConsent() {
        // Asking someone to agree to a data transfer that cannot succeed is worse
        // than telling them what to fix. Order is load-bearing; this pins it.
        for model in [nil, ""] {
            let selection = LibraryChatConnectorSelection(
                id: "ollama",
                displayName: "Ollama",
                supportsToolCalling: true,
                model: model
            )
            #expect(Self.availability(selection: selection)
                == .providerNeedsModel(id: "ollama", displayName: "Ollama"))
        }
    }

    // MARK: Derived answers

    @Test("only a ready state offers a route, and only consentRequired offers a sheet")
    func theDerivedAccessorsAgreeWithTheCases() {
        let ready = Self.availability(selection: Self.ollama, consented: true)
        #expect(ready.isReady)
        #expect(ready.pendingConsent == nil)

        let pending = Self.availability(selection: Self.ollama)
        #expect(!pending.isReady)
        #expect(pending.pendingConsent?.id == "ollama")
        #expect(pending.pendingConsent?.displayName == "Ollama")

        #expect(!Self.availability(enabled: false).isReady)
        #expect(Self.availability(enabled: false).pendingConsent == nil)
    }
}
