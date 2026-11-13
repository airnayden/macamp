// WebSuggestionsSettingsTests — the two web-suggestions records, and their independence.
//
// Two `Bool`s that look like one switch and are deliberately not: `enabled` is
// what the listener asked MacAMP to DO, `consented` is what the listener was
// TOLD before it could. Every claim here is about keeping those apart.
//
// The independence claim cannot be proven by driving the setters alone — a
// property that derived consent from enablement would still read back whatever
// the setter had just written. So the load-bearing test injects the pair
// STRAIGHT into `UserDefaults` (the shape a hand-edited plist, a restored
// backup, or a half-migrated install arrives in) and re-hydrates: only a
// genuinely separate record survives `enabled = true, consented = false`.
//
// The suite writes to a per-test `UserDefaults` suite and removes the persistent
// domain on both ends, so nothing here can reach the real preferences and no run
// starts on another run's leftovers.
import Foundation
@testable import MacAMP
import Testing

@Suite("Web suggestions settings", .serialized)
@MainActor
struct WebSuggestionsSettingsTests {
    private static let suitePrefix = "com.example.macamp.tests.webSuggestions"

    private static func suiteName(_ function: String) -> String {
        "\(suitePrefix).\(function)"
    }

    /// A `UserDefaults` suite emptied before the test sees it.
    private static func emptyStore(_ function: String) throws -> UserDefaults {
        let name = suiteName(function)
        let store = try #require(UserDefaults(suiteName: name), "test-only defaults suite unavailable")
        store.removePersistentDomain(forName: name)
        return store
    }

    // MARK: Shipped state

    @Test("web suggestions ship off and undisclosed")
    func theShippedStateIsOffAndUndisclosed() throws {
        let name = Self.suiteName(#function)
        let store = try Self.emptyStore(#function)
        defer { store.removePersistentDomain(forName: name) }

        let settings = AppSettings(defaults: store)

        #expect(settings.webSuggestionsEnabled == false)
        #expect(settings.webSuggestionsConsented == false)
        // Hydration must not write back: an untouched install has no stored
        // record at all, which is what lets "never asked" be told from "declined".
        #expect(store.object(forKey: AppSettingsKeys.webSuggestionsEnabled) == nil)
        #expect(store.object(forKey: AppSettingsKeys.webSuggestionsConsented) == nil)
    }

    @Test("the two keys are the shipped persistence format")
    func theKeysAreTheShippedPersistenceFormat() {
        // Keys are a persistence FORMAT: renaming one silently resets the record
        // it stored, which for a consent record means re-asking behind the
        // listener's back. Pinned by literal, prefix and all.
        #expect(AppSettingsKeys.webSuggestionsEnabled == "com.example.macamp.settings.ai.webSuggestions.enabled")
        #expect(AppSettingsKeys.webSuggestionsConsented == "com.example.macamp.settings.ai.webSuggestions.consented")
    }

    // MARK: Persistence

    @Test("both records survive an AppSettings re-init against the same defaults")
    func bothRecordsPersistAcrossReInit() throws {
        let name = Self.suiteName(#function)
        let store = try Self.emptyStore(#function)
        defer { store.removePersistentDomain(forName: name) }

        let first = AppSettings(defaults: store)
        first.webSuggestionsEnabled = true
        first.webSuggestionsConsented = true

        let reloaded = AppSettings(defaults: store)
        #expect(reloaded.webSuggestionsEnabled == true)
        #expect(reloaded.webSuggestionsConsented == true)

        // Turning the feature back off must NOT retract the disclosure: the
        // listener was told, and re-enabling later is not a second first time.
        reloaded.webSuggestionsEnabled = false

        let afterDisable = AppSettings(defaults: store)
        #expect(afterDisable.webSuggestionsEnabled == false)
        #expect(afterDisable.webSuggestionsConsented == true)
    }

    // MARK: Independence

    @Test("an injected enabled=true, consented=false pair stays surfaced as itself")
    func injectedEnablementDoesNotImplyConsent() throws {
        let name = Self.suiteName(#function)
        let store = try Self.emptyStore(#function)
        defer { store.removePersistentDomain(forName: name) }

        store.set(true, forKey: AppSettingsKeys.webSuggestionsEnabled)
        store.set(false, forKey: AppSettingsKeys.webSuggestionsConsented)

        let settings = AppSettings(defaults: store)
        #expect(settings.webSuggestionsEnabled == true)
        #expect(settings.webSuggestionsConsented == false)
    }

    @Test("an injected consented=true, enabled=false pair stays surfaced as itself")
    func injectedConsentDoesNotImplyEnablement() throws {
        let name = Self.suiteName(#function)
        let store = try Self.emptyStore(#function)
        defer { store.removePersistentDomain(forName: name) }

        store.set(true, forKey: AppSettingsKeys.webSuggestionsConsented)
        store.set(false, forKey: AppSettingsKeys.webSuggestionsEnabled)

        let settings = AppSettings(defaults: store)
        #expect(settings.webSuggestionsConsented == true)
        #expect(settings.webSuggestionsEnabled == false)
    }

    @Test("flipping the switch records no consent")
    func enablingWritesNoConsentRecord() throws {
        let name = Self.suiteName(#function)
        let store = try Self.emptyStore(#function)
        defer { store.removePersistentDomain(forName: name) }

        let settings = AppSettings(defaults: store)
        settings.webSuggestionsEnabled = true

        #expect(settings.webSuggestionsConsented == false)
        // Not merely `false` in memory — no consent key was written at all, so
        // the switch cannot stand in for the disclosure on the next launch.
        #expect(store.object(forKey: AppSettingsKeys.webSuggestionsConsented) == nil)
        #expect(store.object(forKey: AppSettingsKeys.webSuggestionsEnabled) as? Bool == true)
    }
}
