// PlaylistIntentDetectorTests — the per-locale keyword table, one row per shipped
// locale.
//
// The detector matches INPUT, never copy: nothing it holds is shown to anyone, so
// nothing here goes through a String Catalog. Each locale gets BOTH a positive row
// (a real playlist ask in that language) and a negative one (a plausible request in
// the same language that is not a playlist ask), because a table that matches
// everything would fire a corrective turn on every message.
import Foundation
import Testing
import ViewModels

@Suite("PlaylistIntentDetector")
struct PlaylistIntentDetectorTests {
    /// One shipped locale: its code, a real playlist ask, and a request in the same
    /// language that must NOT be read as one.
    private struct Row {
        let language: String
        let asks: String
        let doesNotAsk: String
    }

    private static let rows: [Row] = [
        Row(
            language: "en",
            asks: "make me a playlist for tonight",
            doesNotAsk: "what is the loudest song I own"
        ),
        Row(
            language: "bg",
            asks: "направи ми плейлист за вечерта",
            doesNotAsk: "пусни нещо спокойно"
        ),
        Row(
            language: "de",
            asks: "erstell mir eine Wiedergabeliste",
            doesNotAsk: "spiel etwas Ruhiges"
        ),
        Row(
            language: "es",
            asks: "hazme una lista para la fiesta",
            doesNotAsk: "pon algo tranquilo"
        ),
        Row(
            language: "ru",
            asks: "сделай подборку на вечер",
            doesNotAsk: "включи что-нибудь спокойное"
        ),
        Row(
            language: "fr",
            asks: "fais-moi une liste de lecture",
            doesNotAsk: "joue quelque chose de calme"
        ),
        Row(
            language: "it",
            asks: "creami una scaletta per stasera",
            doesNotAsk: "metti qualcosa di allegro"
        ),
        Row(
            language: "pseudo",
            asks: "[[Måkè mé ä pläylïst]]",
            doesNotAsk: "[[Whät ïs pläyïng]]"
        ),
    ]

    // MARK: The table

    @Test("every shipped locale reads a playlist ask written in its own words")
    func everyLocaleMatchesItsOwnAsk() {
        for row in Self.rows {
            #expect(
                PlaylistIntentDetector.matches(row.asks, languageCode: row.language),
                "\(row.language) should read its own playlist ask as one"
            )
        }
    }

    @Test("a plain listening request in the same language is not a playlist ask")
    func everyLocaleRejectsAPlainRequest() {
        for row in Self.rows {
            #expect(
                !PlaylistIntentDetector.matches(row.doesNotAsk, languageCode: row.language),
                "\(row.language) should not read a plain request as a playlist ask"
            )
        }
    }

    @Test("the table covers exactly the eight shipped locales")
    func theTableCoversTheShippedLocales() {
        #expect(PlaylistIntentDetector.supportedLanguageCodes == [
            "bg", "de", "en", "es", "fr", "it", "pseudo", "ru",
        ])
    }

    // MARK: Folding and fallback

    @Test("matching ignores case and diacritics on the listener's own text")
    func matchingIsCaseAndDiacriticInsensitive() {
        #expect(PlaylistIntentDetector.matches("PLAYLIST please", languageCode: "en"))
        #expect(PlaylistIntentDetector.matches("un pläylïst", languageCode: "fr"))
    }

    @Test("pseudo carries the English stems it is generated from")
    func pseudoCarriesTheEnglishStems() {
        #expect(PlaylistIntentDetector.matches("make me a mixtape", languageCode: "pseudo"))
    }

    @Test("an unshipped language still reads the English loanword, and nothing else")
    func anUnshippedLanguageFallsBackToEnglish() {
        #expect(PlaylistIntentDetector.matches("playlist を作って", languageCode: "ja"))
        #expect(!PlaylistIntentDetector.matches("何か静かな曲をかけて", languageCode: "ja"))
    }

    @Test("the Locale overload resolves the language code, and only that one's stems")
    func theLocaleOverloadResolvesItsOwnStems() {
        #expect(PlaylistIntentDetector.matches("una scaletta per stasera", locale: Locale(identifier: "it_IT")))
        #expect(!PlaylistIntentDetector.matches("una scaletta per stasera", locale: Locale(identifier: "de_DE")))
    }

    @Test("an empty message is never a playlist ask")
    func anEmptyMessageIsNeverAnAsk() {
        #expect(!PlaylistIntentDetector.matches("", languageCode: "en"))
        #expect(!PlaylistIntentDetector.matches("   ", languageCode: "en"))
    }
}
