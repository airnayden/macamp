// AppLanguageTests — the interface-language override, as a persisted decision.
//
// Four claims that would each look right in the General pane while being wrong:
//
//   1. Offering a language the app has no translation for. The list is pinned as a
//      literal here AND checked against the BUILT bundle's own `.lproj` set, because
//      a restated list agrees with itself no matter what actually shipped.
//   2. "System" writing a resolved language instead of clearing the override. That
//      one is invisible — the app comes up in the right language either way — until
//      the listener changes their Mac's language and MacAMP no longer follows.
//   3. A choice that does not survive the relaunch it exists to be read by. Asserted
//      through the app's PERSISTENT DOMAIN, never `object(forKey:)`: the resolved
//      read falls through to `NSGlobalDomain`, so it answers with the system's
//      languages even when nothing of ours is stored and would pass vacuously.
//   4. Language names shown in the running language ("German"), which is unreadable
//      to the one person who needs this picker.
import Foundation
@testable import MacAMP
import Testing

@Suite("App language override")
@MainActor
struct AppLanguageTests {
    // MARK: The offered list

    @Test("exactly the seven shipped locales are offered, in catalog order")
    func theOfferedListIsTheShippedList() {
        #expect(AppLanguage.allCases.map(\.rawValue) == ["en", "bg", "de", "es", "fr", "it", "ru"])
    }

    /// The double-entry half: the list above is a restatement, so it agrees with
    /// itself whatever shipped. `Bundle.main` in a hosted test is the real app, so
    /// this asks the artifact instead.
    @Test("every offered language has a real localization in the built app")
    func everyOfferedLanguageIsActuallyBundled() {
        let bundled = Set(Bundle.main.localizations)
        for language in AppLanguage.allCases {
            #expect(bundled.contains(language.rawValue), "\(language.rawValue).lproj is missing from the app")
        }
    }

    @Test("pseudo is never offered — it is an Xcode diagnostic, not a choice")
    func pseudoIsNotOffered() {
        #expect(!AppLanguage.allCases.map(\.rawValue).contains("pseudo"))
    }

    // MARK: System clears rather than writes

    @Test("System writes no AppleLanguages value at all")
    func systemClearsTheOverrideRatherThanPinningOne() {
        #expect(AppLanguageOverride.appleLanguagesValue(for: nil) == nil)
        #expect(AppLanguageOverride.appleLanguagesValue(for: .german) == ["de"])
    }

    @Test("choosing System removes both keys from the app's own domain")
    func systemRemovesBothStoredKeys() {
        let name = "\(Self.suitePrefix).system"
        let store = Self.store(named: name)

        AppLanguageOverride.apply(.russian, in: store)
        #expect(Self.domain(name)[AppLanguageOverride.appleLanguagesKey] as? [String] == ["ru"])

        AppLanguageOverride.apply(nil, in: store)
        let cleared = Self.domain(name)
        #expect(cleared[AppLanguageOverride.appleLanguagesKey] == nil)
        #expect(cleared[AppSettingsKeys.appLanguage] == nil)
        #expect(AppLanguageOverride.current(in: store) == nil)
    }

    // MARK: Persistence

    @Test("a chosen language round-trips, and is the one macOS will read at launch")
    func aChosenLanguageRoundTrips() {
        let name = "\(Self.suitePrefix).roundTrip"
        let store = Self.store(named: name)

        #expect(AppLanguageOverride.current(in: store) == nil)
        AppLanguageOverride.apply(.bulgarian, in: store)

        #expect(AppLanguageOverride.current(in: store) == .bulgarian)
        #expect(Self.domain(name)[AppSettingsKeys.appLanguage] as? String == "bg")
        #expect(Self.domain(name)[AppLanguageOverride.appleLanguagesKey] as? [String] == ["bg"])
    }

    @Test("switching language replaces the override rather than appending to it")
    func switchingLanguageReplacesTheOverride() {
        let name = "\(Self.suitePrefix).switch"
        let store = Self.store(named: name)

        AppLanguageOverride.apply(.french, in: store)
        AppLanguageOverride.apply(.italian, in: store)

        #expect(Self.domain(name)[AppLanguageOverride.appleLanguagesKey] as? [String] == ["it"])
        #expect(AppLanguageOverride.current(in: store) == .italian)
    }

    @Test("an unknown stored identifier degrades to System instead of trapping")
    func anUnknownStoredIdentifierDegradesToSystem() {
        let name = "\(Self.suitePrefix).garbage"
        let store = Self.store(named: name)

        store.set("kl", forKey: AppSettingsKeys.appLanguage)
        #expect(AppLanguageOverride.current(in: store) == nil)
    }

    // MARK: Display names

    @Test("each language is named in its own language, and no two names collide")
    func languagesAreNamedInTheirOwnLanguage() {
        #expect(AppLanguage.german.endonym == "Deutsch")
        #expect(AppLanguage.russian.endonym == "Русский")
        #expect(AppLanguage.bulgarian.endonym == "Български")
        #expect(AppLanguage.french.endonym == "Français")
        #expect(AppLanguage.spanish.endonym == "Español")
        #expect(AppLanguage.italian.endonym == "Italiano")
        #expect(AppLanguage.english.endonym == "English")

        let names = Set(AppLanguage.allCases.map(\.endonym))
        #expect(names.count == AppLanguage.allCases.count)
    }

    // MARK: Helpers

    private static let suitePrefix = "com.example.macamp.tests.appLanguage"

    private static func store(named name: String) -> UserDefaults {
        guard let store = UserDefaults(suiteName: name) else { return .standard }
        store.removePersistentDomain(forName: name)
        return store
    }

    private static func domain(_ name: String) -> [String: Any] {
        UserDefaults().persistentDomain(forName: name) ?? [:]
    }
}
