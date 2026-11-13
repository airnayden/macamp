// WebSuggestionsConsentTests — the claims the web-suggestions section makes that a
// screenshot cannot check.
//
// ── THE CENTRAL CLAIM IS A NEGATIVE ──────────────────────────────────────────
//
// "Declining the disclosure writes NOTHING" is a claim about a side effect that did
// not happen. Reading the two flags back afterwards is not enough to prove it: both
// ship `false`, so an implementation that wrote `false` to either key — or wrote
// `true` and then rolled back — reads back identically to one that never touched
// `UserDefaults` at all. The difference is visible only at the store.
//
// So the suite injects a ``RecordingDefaults``: a real `UserDefaults` suite that
// additionally RECORDS every key written through it. The decline test resets the
// recorder after `AppSettings` has hydrated and then asserts the recorded list is
// EMPTY — no consent key, no enablement key, nothing. `object(forKey:)` is asserted
// `nil` beside it, so both the "was it written" and the "what is stored" halves are
// covered.
//
// ── THE KEYCHAIN IS A SEAM, NEVER THE REAL ONE ───────────────────────────────
//
// The two optional keys are addressed through the SHIPPED service names, but the
// store behind them is a ``SecretSpy`` — an in-memory `SecretStore` that also
// records every call. Two reasons: a UI-level suite must not leave items in a
// working machine's login Keychain, and "Remove key called delete" is another
// negative-adjacent claim (delete, then a read that answers `nil`) that a real
// backend would prove more slowly and less certainly.
//
// ── WHAT IS DELIBERATELY NOT ASSERTED ────────────────────────────────────────
//
// Nothing here reaches the network, and nothing here renders a view. The section is
// a thin painter over ``WebSuggestionsSectionModel`` — exactly the split
// ``IntelligenceMCPSectionTests`` relies on — so every claim below is asked of the
// model.
import AIConnectorKit
import Foundation
@testable import MacAMP
import Testing

@Suite("Web suggestions consent", .serialized)
@MainActor
struct WebSuggestionsConsentTests {
    // MARK: The consent gate

    @Test("switching on without consent raises the disclosure and writes nothing")
    func enablingWithoutConsentRaisesTheSheet() throws {
        let harness = try Harness(named: "gate")
        harness.defaults.resetRecording()

        harness.model.setEnabled(true)

        let disclosure = try #require(harness.model.consenting)
        // The sheet names the two services by their own names, so the warning is
        // about something the listener can recognise.
        #expect(disclosure.searchProviderName == "Tavily")
        #expect(disclosure.videoProviderName == "YouTube")
        harness.expectNothingWritten()
    }

    @Test("declining leaves both records untouched and performs ZERO defaults writes")
    func decliningWritesNothing() throws {
        let harness = try Harness(named: "decline")
        harness.defaults.resetRecording()

        harness.model.setEnabled(true)
        harness.model.declineConsent()

        #expect(harness.model.consenting == nil)
        #expect(harness.settings.webSuggestionsEnabled == false)
        #expect(harness.settings.webSuggestionsConsented == false)
        // The load-bearing half: not "both read false" — both were never written.
        harness.expectNothingWritten()
    }

    @Test("accepting records the disclosure and the switch, in that order")
    func acceptingWritesBothFlags() throws {
        let harness = try Harness(named: "accept")
        harness.defaults.resetRecording()

        harness.model.setEnabled(true)
        harness.model.acceptConsent()

        #expect(harness.model.consenting == nil)
        #expect(harness.settings.webSuggestionsEnabled)
        #expect(harness.settings.webSuggestionsConsented)
        // Both records really reached the store, so a relaunch reads them back.
        #expect(harness.defaults.object(forKey: AppSettingsKeys.webSuggestionsConsented) as? Bool == true)
        #expect(harness.defaults.object(forKey: AppSettingsKeys.webSuggestionsEnabled) as? Bool == true)
    }

    @Test("a second enable after consent asks nothing and simply switches on")
    func consentIsNotAskedTwice() throws {
        let harness = try Harness(named: "again")
        harness.settings.webSuggestionsConsented = true

        harness.model.setEnabled(true)

        #expect(harness.model.consenting == nil)
        #expect(harness.settings.webSuggestionsEnabled)
    }

    @Test("switching off is unconditional and retracts no disclosure")
    func disablingNeverAsksAndKeepsConsent() throws {
        let harness = try Harness(named: "off")
        harness.settings.webSuggestionsConsented = true
        harness.model.setEnabled(true)

        harness.model.setEnabled(false)

        #expect(harness.model.consenting == nil)
        #expect(harness.settings.webSuggestionsEnabled == false)
        // The listener was told once; re-enabling later is not a second first time.
        #expect(harness.settings.webSuggestionsConsented)
    }

    // MARK: The Intelligence switch

    @Test("the section reports itself inert while Intelligence is off")
    func theSectionIsGatedOnTheIntelligenceSwitch() throws {
        let harness = try Harness(named: "gating")
        harness.settings.intelligenceEnabled = false

        #expect(harness.model.isSectionEnabled == false)

        harness.settings.intelligenceEnabled = true
        #expect(harness.model.isSectionEnabled)
    }

    // MARK: The two optional keys

    @Test("the key slots address the shipped connector namespaces")
    func theKeySlotsAddressTheShippedServices() {
        // Pinned by literal: these strings ARE where an already-stored key lives,
        // so a "tidier" connector id would orphan it rather than rename it.
        #expect(WebSuggestionsKeySlot.search.service == "com.macamp.aiconnectors.web_search")
        #expect(WebSuggestionsKeySlot.video.service == "com.macamp.aiconnectors.youtube")
        #expect(WebSuggestionsKeySlot.allCases.count == 2)
    }

    @Test("a pasted key round-trips into its own slot and is never seeded back")
    func aPastedKeyRoundTrips() async throws {
        let harness = try Harness(named: "keys")

        harness.model.setDraft(" \(Self.searchKey) ", for: .search)
        await harness.model.saveKey(for: .search)

        let stored = try await harness.secrets.get(service: WebSuggestionsKeySlot.search.service, account: "apiKey")
        // Trimmed on the way in — a pasted key carries whatever the clipboard had.
        #expect(stored == Self.searchKey)
        #expect(harness.model.hasStoredKey(.search))
        // The field is cleared and NEVER re-seeded from the Keychain: a secret in a
        // `SecureField` is copyable, screenshot-able and gains nothing.
        #expect(harness.model.draft(for: .search).isEmpty)
        // The other slot is untouched — two keys, two namespaces.
        #expect(harness.model.hasStoredKey(.video) == false)
        let untouched = try await harness.secrets.get(service: WebSuggestionsKeySlot.video.service, account: "apiKey")
        #expect(untouched == nil)
    }

    @Test("both slots store independently under their own service names")
    func bothSlotsStoreIndependently() async throws {
        let harness = try Harness(named: "bothKeys")

        harness.model.setDraft(Self.searchKey, for: .search)
        await harness.model.saveKey(for: .search)
        harness.model.setDraft(Self.videoKey, for: .video)
        await harness.model.saveKey(for: .video)

        let search = try await harness.secrets.get(service: WebSuggestionsKeySlot.search.service, account: "apiKey")
        let video = try await harness.secrets.get(service: WebSuggestionsKeySlot.video.service, account: "apiKey")
        #expect(search == Self.searchKey)
        #expect(video == Self.videoKey)
        #expect(harness.model.hasStoredKey(.search))
        #expect(harness.model.hasStoredKey(.video))
    }

    @Test("a blank or whitespace-only entry stores nothing and keeps the saved key")
    func aBlankEntryKeepsTheSavedKey() async throws {
        let harness = try Harness(named: "blank")
        harness.model.setDraft(Self.searchKey, for: .search)
        await harness.model.saveKey(for: .search)
        await harness.secrets.resetRecording()

        // Whitespace is not a key. The field being empty means "not entered this
        // time", never "delete it" — removal has its own button.
        harness.model.setDraft("   \n\t ", for: .search)
        await harness.model.saveKey(for: .search)

        let writes = await harness.secrets.writes
        #expect(writes.isEmpty, "a whitespace-only entry must not reach the Keychain")
        let stored = try await harness.secrets.get(service: WebSuggestionsKeySlot.search.service, account: "apiKey")
        #expect(stored == Self.searchKey)
        #expect(harness.model.hasStoredKey(.search))
    }

    @Test("Remove key deletes the stored secret and the next read answers nil")
    func removingAKeyCallsDeleteAndClearsIt() async throws {
        let harness = try Harness(named: "remove")
        harness.model.setDraft(Self.searchKey, for: .search)
        await harness.model.saveKey(for: .search)
        await harness.secrets.resetRecording()

        await harness.model.removeKey(for: .search)

        let deletes = await harness.secrets.deletes
        #expect(deletes == [WebSuggestionsKeySlot.search.service])
        let stored = try await harness.secrets.get(service: WebSuggestionsKeySlot.search.service, account: "apiKey")
        #expect(stored == nil)
        #expect(harness.model.hasStoredKey(.search) == false)
    }

    @Test("removing a key that was never pasted is not an error path")
    func removingAnAbsentKeyIsIdempotent() async throws {
        let harness = try Harness(named: "removeAbsent")

        await harness.model.removeKey(for: .video)

        #expect(harness.model.hasStoredKey(.video) == false)
        let deletes = await harness.secrets.deletes
        #expect(deletes == [WebSuggestionsKeySlot.video.service])
    }

    @Test("refreshing reads only WHETHER a key exists, never its value")
    func refreshReadsExistenceNotValue() async throws {
        let harness = try Harness(named: "refresh")
        try await harness.secrets.set(Self.videoKey, service: WebSuggestionsKeySlot.video.service, account: "apiKey")

        await harness.model.refreshStoredKeys()

        #expect(harness.model.hasStoredKey(.video))
        #expect(harness.model.hasStoredKey(.search) == false)
        // The value never lands in a draft — the caption is what tells the listener
        // a key is already saved.
        #expect(harness.model.draft(for: .video).isEmpty)
    }

    // MARK: Keys are not a grant

    @Test("saving a key neither enables the feature nor stands in for the disclosure")
    func savingAKeyGrantsNothing() async throws {
        let harness = try Harness(named: "keyIsNotAGrant")
        harness.defaults.resetRecording()

        harness.model.setDraft(Self.searchKey, for: .search)
        await harness.model.saveKey(for: .search)

        #expect(harness.settings.webSuggestionsEnabled == false)
        #expect(harness.settings.webSuggestionsConsented == false)
        harness.expectNothingWritten()
    }
}

// MARK: - Fixtures

private extension WebSuggestionsConsentTests {
    static let suitePrefix = "com.example.macamp.tests.webSuggestionsConsent"
    static let searchKey = "tvly-not-a-real-token-0123456789"
    static let videoKey = "AIza-not-a-real-token-0123456789"

    /// One settings store, one recording defaults suite, one spying Keychain, and
    /// the model they all meet in.
    struct Harness {
        let defaults: RecordingDefaults
        let settings: AppSettings
        let secrets: SecretSpy
        let model: WebSuggestionsSectionModel

        @MainActor
        init(named name: String) throws {
            let suite = "\(suitePrefix).\(name)"
            defaults = try #require(RecordingDefaults(suiteName: suite), "test-only defaults suite unavailable")
            defaults.removePersistentDomain(forName: suite)
            settings = AppSettings(defaults: defaults)
            settings.intelligenceEnabled = true
            secrets = SecretSpy()
            model = WebSuggestionsSectionModel(settings: settings, secrets: secrets)
        }

        /// Neither record moved, and neither key was written at all.
        @MainActor
        func expectNothingWritten() {
            #expect(defaults.recordedWrites.isEmpty, "recorded writes: \(defaults.recordedWrites.sorted())")
            #expect(defaults.object(forKey: AppSettingsKeys.webSuggestionsEnabled) == nil)
            #expect(defaults.object(forKey: AppSettingsKeys.webSuggestionsConsented) == nil)
        }
    }
}

// MARK: - Recording defaults

/// A real `UserDefaults` suite that also records every key written through it.
///
/// Both funnels are overridden deliberately: `AppSettings` writes `Bool`s through
/// `set(_:forKey:)`'s `Bool` overload, which `NSUserDefaults` is not documented to
/// route through `setObject:forKey:`. Overriding only one would record a subset and
/// let the very write this suite is about slip past unrecorded.
final class RecordingDefaults: UserDefaults, @unchecked Sendable {
    /// A SET, because the `Bool` overload is observed to funnel into the `Any?` one
    /// on this platform and would otherwise record each write twice. What is
    /// asserted is WHICH keys were written and whether any were — never how often.
    private(set) var recordedWrites: Set<String> = []

    func resetRecording() {
        recordedWrites = []
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        recordedWrites.insert(defaultName)
        super.set(value, forKey: defaultName)
    }

    override func set(_ value: Bool, forKey defaultName: String) {
        recordedWrites.insert(defaultName)
        super.set(value, forKey: defaultName)
    }
}

// MARK: - Secret spy

/// An in-memory ``SecretStore`` that records every write and delete it is asked for.
///
/// Never the login Keychain: a preferences suite must not leave items behind on a
/// working machine, and "Remove key really called delete" is a claim about a CALL,
/// which only a spy can answer.
actor SecretSpy: SecretStore {
    private(set) var writes: [String] = []
    private(set) var deletes: [String] = []
    private var storage: [String: String] = [:]

    func resetRecording() {
        writes = []
        deletes = []
    }

    func get(service: String, account: String) async throws -> String? {
        storage[Self.slot(service, account)]
    }

    func set(_ value: String, service: String, account: String) async throws {
        writes.append(service)
        storage[Self.slot(service, account)] = value
    }

    func delete(service: String, account: String) async throws {
        deletes.append(service)
        storage[Self.slot(service, account)] = nil
    }

    private static func slot(_ service: String, _ account: String) -> String {
        "\(service)|\(account)"
    }
}
