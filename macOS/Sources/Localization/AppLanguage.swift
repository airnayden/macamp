// AppLanguage — the interface languages MacAMP ships, as a closed set.
//
// The seven cases are exactly the locales `macOS/Sources/Localizable.xcstrings`
// declares a translation for. `pseudo` is deliberately NOT a case: it is an
// Xcode-scheme diagnostic (Run ▸ Options ▸ App Language), not something a listener
// may choose.
//
// The raw values are BCP-47 identifiers because they are written verbatim into the
// `AppleLanguages` array macOS reads at launch — see `AppLanguageOverride`. They are
// therefore a persistence format as much as the `UserDefaults` key is: renaming one
// silently drops an existing listener back to the system language.
import Foundation

/// An interface language the app can be forced into, beside "follow the system".
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case bulgarian = "bg"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case russian = "ru"

    public var id: String {
        rawValue
    }

    /// The language's name written in that language ("Deutsch", "Русский").
    ///
    /// Resolved against a locale OF THAT LANGUAGE, never the running one: a listener
    /// who cannot read the current interface language is exactly the person using
    /// this picker, so "German" would be unreadable where "Deutsch" is not.
    ///
    /// Foundation returns these lowercased where the language's own orthography
    /// lowercases them ("français", "русский"); macOS's own Language & Region list
    /// capitalizes them, so `capitalized(with:)` applies that convention using the
    /// target locale's casing rules rather than the running locale's.
    public var endonym: String {
        let locale = Locale(identifier: rawValue)
        let name = locale.localizedString(forIdentifier: rawValue)
            ?? locale.localizedString(forLanguageCode: rawValue)
        guard let name else { return rawValue }
        return name.capitalized(with: locale)
    }
}
