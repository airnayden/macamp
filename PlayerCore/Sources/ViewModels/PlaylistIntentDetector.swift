// PlaylistIntentDetector — "did the listener just ask for a playlist?", in the eight
// languages MacAMP ships.
//
// ── THIS MATCHES INPUT; IT IS NOT COPY ───────────────────────────────────────
//
// Nothing in this file is ever shown to anyone, so nothing in it belongs in a String
// Catalog: these are the words a LISTENER types, and translating them would be
// translating the wrong side of the conversation. The table covers the same eight
// locales the catalogs do for the same underlying reason — those are the languages
// MacAMP claims to understand — but the two lists are not the same list and must not
// be merged.
//
// ── STEMS, MATCHED AS SUBSTRINGS ─────────────────────────────────────────────
//
// Every entry is a STEM, so one entry covers a whole inflectional family: Bulgarian
// "плейлист" also reads "плейлиста", Russian "подборк" also reads "подборку" and
// "подборки", English "mix" also reads "mixes". Case, diacritics and width are folded
// off BOTH the message and the stem, which is also what makes the Cyrillic rows safe
// — it does not matter whether "й" folds to "и" as long as the stem folds the same
// way.
//
// ── EVERY LOCALE ALSO CARRIES THE ENGLISH STEMS ──────────────────────────────
//
// "playlist" is an English loanword typed verbatim across most of these languages,
// and a listener running MacAMP in German may still write their request in English.
// The English row is therefore consulted for EVERY language, and a language the table
// does not ship resolves to it alone rather than to nothing.
//
// This file imports only Foundation; it MUST NOT import AppKit or UIKit (PlayerCore
// portability invariant).
import Foundation

/// Whether a listener's own message is asking for a playlist.
public enum PlaylistIntentDetector {
    /// The English stems, which every language is matched against. See the header.
    private static let englishStems = ["playlist", "mix", "mixtape"]

    /// The stems by language code. `pseudo` is Xcode's pseudolanguage, generated from
    /// `en`, so it carries the English stems verbatim.
    private static let stemsByLanguage: [String: [String]] = [
        "en": englishStems,
        "pseudo": englishStems,
        "bg": ["плейлист", "списък"],
        "de": ["playlist", "wiedergabeliste"],
        "es": ["lista", "playlist"],
        "ru": ["плейлист", "подборк"],
        "fr": ["playlist", "liste de lecture"],
        "it": ["playlist", "scaletta"],
    ]

    /// The language codes the table covers, sorted — the shipped locales, restated as
    /// data so a locale added to the catalogs without a row here fails a test.
    public static var supportedLanguageCodes: [String] {
        stemsByLanguage.keys.sorted()
    }

    /// Whether `text` reads as a playlist ask in `locale`'s language.
    public static func matches(_ text: String, locale: Locale = .current) -> Bool {
        matches(text, languageCode: locale.language.languageCode?.identifier ?? "en")
    }

    /// The code-keyed form, which is what the table is really indexed by.
    ///
    /// Public because `pseudo` has no valid `Locale` identifier, so the per-locale
    /// coverage test cannot reach that row through the `Locale` overload at all.
    public static func matches(_ text: String, languageCode: String) -> Bool {
        let message = folded(text)
        guard !message.isEmpty else { return false }
        let stems = (stemsByLanguage[languageCode] ?? []) + englishStems
        return stems.contains { message.contains(folded($0)) }
    }

    private static func folded(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
    }
}
