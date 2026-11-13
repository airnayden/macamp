// LibraryChatConsentTests — the second consent record, and its independence from
// the first.
//
// The claim under test is a PRIVACY one: accepting the connect-time payload
// disclosure must not, by itself, let a provider browse the library — and the two
// records must survive a relaunch separately. Both are checked by writing through
// one `AppSettings` and reading back through a SECOND one over the same suite,
// which is the only way to prove the value really reached `UserDefaults` rather
// than living in memory.
import AIConnectorKit
import Foundation
@testable import MacAMP
import Services
import Testing

@Suite("Library browsing consent", .serialized)
@MainActor
struct LibraryChatConsentTests {
    private static let suitePrefix = "com.example.macamp.tests.libraryChatConsent"

    private static func suiteName(_ function: String) -> String {
        "\(suitePrefix).\(function)"
    }

    private static func freshSettings(_ function: String) -> (AppSettings, String) {
        let name = suiteName(function)
        guard let store = UserDefaults(suiteName: name) else { return (AppSettings(defaults: .standard), name) }
        store.removePersistentDomain(forName: name)
        return (AppSettings(defaults: store), name)
    }

    private static func reloaded(_ name: String) -> AppSettings {
        guard let store = UserDefaults(suiteName: name) else { return AppSettings(defaults: .standard) }
        return AppSettings(defaults: store)
    }

    // MARK: Defaults

    @Test("a fresh install has agreed to nothing, so no provider may browse")
    func aFreshInstallHasNoBrowsingConsent() {
        let (settings, _) = Self.freshSettings(#function)
        #expect(settings.libraryBrowsingConsentedConnectorIDs.isEmpty)
        #expect(!settings.hasLibraryBrowsingConsent(forConnectorID: "ollama"))
    }

    // MARK: Round trip

    @Test("browsing consent survives a relaunch, per connector id")
    func consentRoundTripsThroughUserDefaults() {
        let (settings, name) = Self.freshSettings(#function)
        settings.recordLibraryBrowsingConsent(forConnectorID: "ollama")
        let reloaded = Self.reloaded(name)
        #expect(reloaded.hasLibraryBrowsingConsent(forConnectorID: "ollama"))
        #expect(!reloaded.hasLibraryBrowsingConsent(forConnectorID: AnthropicConnector.connectorID))
    }

    @Test("recording is idempotent and additive")
    func recordingIsIdempotentAndAdditive() {
        let (settings, name) = Self.freshSettings(#function)
        settings.recordLibraryBrowsingConsent(forConnectorID: "ollama")
        settings.recordLibraryBrowsingConsent(forConnectorID: "ollama")
        settings.recordLibraryBrowsingConsent(forConnectorID: AnthropicConnector.connectorID)
        #expect(Self.reloaded(name).libraryBrowsingConsentedConnectorIDs
            == ["ollama", AnthropicConnector.connectorID])
    }

    // MARK: Independence — the whole point of a second record

    @Test("the connect-time payload consent does NOT grant library browsing")
    func payloadConsentDoesNotGrantBrowsing() {
        let (settings, name) = Self.freshSettings(#function)
        settings.recordConsent(forConnectorID: "ollama")
        let reloaded = Self.reloaded(name)
        #expect(reloaded.hasConsented(toConnectorID: "ollama"))
        #expect(!reloaded.hasLibraryBrowsingConsent(forConnectorID: "ollama"))
    }

    @Test("granting library browsing does NOT retroactively grant the payload consent")
    func browsingConsentDoesNotGrantThePayloadConsent() {
        let (settings, name) = Self.freshSettings(#function)
        settings.recordLibraryBrowsingConsent(forConnectorID: "ollama")
        let reloaded = Self.reloaded(name)
        #expect(reloaded.hasLibraryBrowsingConsent(forConnectorID: "ollama"))
        #expect(!reloaded.hasConsented(toConnectorID: "ollama"))
    }

    @Test("the two records use different UserDefaults keys, so neither can shadow the other")
    func theTwoRecordsAreStoredSeparately() throws {
        let (settings, name) = Self.freshSettings(#function)
        settings.recordConsent(forConnectorID: "a")
        settings.recordLibraryBrowsingConsent(forConnectorID: "b")
        let store = try #require(UserDefaults(suiteName: name))
        let payload = store.stringArray(forKey: "com.example.macamp.settings.ai.connector.consentedIds")
        let browsing = store.stringArray(
            forKey: "com.example.macamp.settings.ai.connector.libraryBrowsingConsentedIds"
        )
        #expect(payload == ["a"])
        #expect(browsing == ["b"])
    }

    @Test("a hand-edited plist of the wrong shape degrades to 'nothing consented'")
    func aMalformedStoreFailsClosed() throws {
        let name = Self.suiteName(#function)
        let store = try #require(UserDefaults(suiteName: name))
        store.removePersistentDomain(forName: name)
        store.set(42, forKey: "com.example.macamp.settings.ai.connector.libraryBrowsingConsentedIds")
        #expect(AppSettings(defaults: store).libraryBrowsingConsentedConnectorIDs.isEmpty)
    }

    // MARK: The disclosure quotes its enforcement

    @Test("every number on the sheet is read from the constant that enforces it")
    func theDisclosureForwardsItsBudget() {
        let disclosure = LibraryBrowsingDisclosure(id: "ollama", displayName: "Ollama")
        #expect(disclosure.rowsPerLookup == ToolProfile.cloud.rowLimit)
        #expect(disclosure.charactersPerLookup == ToolProfile.cloud.characterLimit)
        #expect(disclosure.lookupsPerQuestion == ToolLoopEngine.defaultMaxToolRounds)
        // Not a tautology: these pin the SHIPPED values, so a budget change that a
        // reviewer did not intend to disclose differently goes red here too.
        #expect(disclosure.rowsPerLookup == ToolResultBudget.cloudRowLimit)
        #expect(disclosure.charactersPerLookup == ToolResultBudget.cloudCharacterLimit)
        #expect(disclosure.lookupsPerQuestion == 20)
    }
}
