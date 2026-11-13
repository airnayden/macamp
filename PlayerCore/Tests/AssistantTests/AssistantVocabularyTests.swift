// AssistantVocabularyTests — the shipped keyword tables, and the parity contract.
//
// The parity suite is the reason the tables exist at all: the same intent, typed
// in three different languages, must reach the SAME spec. Byte-identical input is
// impossible — the words differ — so equivalence is asserted on the OUTPUT the
// resolver consumes (mood tags and year window), which is what "the app
// understood me" actually means to a listener.
import Foundation
import Persistence
import Services
import Testing

@Suite("AssistantVocabularyTables")
struct AssistantVocabularyTests {
    /// MacAMP's shipped locales — `en` is the source, the other six are the
    /// translated ones. `pseudo` is a rendering pseudolanguage with no words of
    /// its own, so it has no keyword table and correctly falls back to English.
    static let shippedLanguageCodes = ["bg", "de", "en", "es", "fr", "it", "ru"]

    @Test("Every shipped locale has a keyword table")
    func everyShippedLocaleHasATable() {
        #expect(AssistantVocabulary.byLanguage.keys.sorted() == Self.shippedLanguageCodes)
    }

    @Test("Every table names all four mood buckets")
    func everyTableCoversEveryMood() {
        for (code, vocabulary) in AssistantVocabulary.byLanguage {
            for tag in PlaylistMoodTag.allCases {
                let words = vocabulary.moodKeywords[tag] ?? []
                #expect(!words.isEmpty, "\(code) has no words for \(tag)")
            }
        }
    }

    @Test("Every table names both tempo buckets")
    func everyTableCoversBothTempoBuckets() {
        for (code, vocabulary) in AssistantVocabulary.byLanguage {
            for hint in TempoHint.allCases {
                let named = vocabulary.tempoKeywords.values.contains(hint)
                #expect(named, "\(code) has no word for \(hint)")
            }
        }
    }

    @Test("Every table recognizes the nineties, the plan's worked example")
    func everyTableRecognizesTheNineties() {
        for (code, vocabulary) in AssistantVocabulary.byLanguage {
            #expect(vocabulary.decadeTokens.values.contains(1990), "\(code) cannot name the 90s")
        }
    }

    @Test("Every decade token maps to a decade boundary year")
    func decadeTokensAreDecadeBoundaries() {
        for (code, vocabulary) in AssistantVocabulary.byLanguage {
            for (token, year) in vocabulary.decadeTokens {
                #expect(year % 10 == 0, "\(code) maps \(token) to \(year)")
                #expect((1900 ... 2100).contains(year), "\(code) maps \(token) to \(year)")
            }
        }
    }

    @Test("An unlisted language resolves to the English table, not to an empty one")
    func unlistedLanguageResolvesToEnglish() {
        let english = AssistantVocabulary.vocabulary(for: Locale(identifier: "en"))
        #expect(AssistantVocabulary.vocabulary(for: Locale(identifier: "ja")) == english)
        #expect(AssistantVocabulary.vocabulary(for: Locale(identifier: "")) == english)
        #expect(AssistantVocabulary.languageCode(for: Locale(identifier: "")) == "en")
        #expect(AssistantVocabulary.languageCode(for: Locale(identifier: "bg_BG")) == "bg")
    }

    @Test("Tempo buckets are half-open on the side the word does not constrain")
    func tempoHintRangesAreHalfOpen() {
        #expect(TempoHint.slow.range.lower == nil)
        #expect(TempoHint.slow.range.upper == TempoHint.slowUpperBPM)
        #expect(TempoHint.fast.range.lower == TempoHint.fastLowerBPM)
        #expect(TempoHint.fast.range.upper == nil)
    }
}

@Suite("AssistantVocabularyParity")
struct AssistantVocabularyParityTests {
    /// The same request, written the way a native speaker would write it.
    private static let upbeatNineties: [(code: String, text: String)] = [
        ("en", "upbeat music from the 90s"),
        ("bg", "енергична музика от 90-те"),
        ("de", "energiegeladene Musik aus den 90ern"),
        ("ru", "энергичная музыка 90-х"),
        ("fr", "musique entraînante des années 90"),
        ("es", "música enérgica de los 90"),
        ("it", "musica energica degli anni 90"),
    ]

    private static let calmSeventies: [(code: String, text: String)] = [
        ("en", "quiet songs from the 70s"),
        ("bg", "спокойна музика от 70-те"),
        ("de", "ruhige Musik aus den 70ern"),
        ("ru", "спокойная музыка 70-х"),
        ("fr", "musique calme des années 70"),
        ("es", "música tranquila de los 70"),
        ("it", "musica tranquilla degli anni 70"),
    ]

    /// No embedding: parity must hold on the tables alone, because two of the
    /// seven locales have no embedding at all.
    private static let parser = HeuristicQueryParser(embeddingNeighbours: { _, _ in nil })

    @Test("The same upbeat-nineties request parses equivalently in every locale")
    func upbeatNinetiesHasParity() async throws {
        for sample in Self.upbeatNineties {
            let spec = try await Self.parser.parse(
                text: sample.text,
                locale: Locale(identifier: sample.code)
            )
            #expect(spec.yearRange == SmartPlaylistRange(lower: 1990, upper: 1999), "\(sample.code)")
            #expect(spec.moodTags.contains(.energetic), "\(sample.code) moods: \(spec.moodTags)")
            #expect(!spec.lowConfidence, "\(sample.code)")
        }
    }

    @Test("The same calm-seventies request parses equivalently in every locale")
    func calmSeventiesHasParity() async throws {
        for sample in Self.calmSeventies {
            let spec = try await Self.parser.parse(
                text: sample.text,
                locale: Locale(identifier: sample.code)
            )
            #expect(spec.yearRange == SmartPlaylistRange(lower: 1970, upper: 1979), "\(sample.code)")
            #expect(spec.moodTags.contains(.calm), "\(sample.code) moods: \(spec.moodTags)")
            #expect(!spec.lowConfidence, "\(sample.code)")
        }
    }

    @Test("Parity holds for the plan's en/bg/de trio on the exact same spec fields")
    func enBulgarianGermanProduceTheSameSpec() async throws {
        var produced: [PlaylistQuerySpec] = []
        for sample in Self.upbeatNineties where ["en", "bg", "de"].contains(sample.code) {
            try await produced.append(Self.parser.parse(
                text: sample.text,
                locale: Locale(identifier: sample.code)
            ))
        }
        #expect(produced.count == 3)
        // Not byte-identical inputs, but identical OUTPUT: the resolver downstream
        // cannot tell which of the three languages the request was written in.
        #expect(Set(produced.map(\.yearRange)).count == 1)
        #expect(Set(produced.map(\.moodTags)).count == 1)
    }
}
