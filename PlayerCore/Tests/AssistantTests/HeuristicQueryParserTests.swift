// HeuristicQueryParserTests — tiers 2 and 3 of the natural-language ladder.
//
// The embedding lookup is INJECTED in every case that cares about it. Real
// `NLEmbedding` availability is a property of the host's downloaded model assets,
// so a test that called the system seam would assert something different on a CI
// runner than on a developer's Mac. Injecting `{ _, _ in nil }` pins the
// no-embedding path — the normal path for `bg` and `ru` — deterministically.
import Foundation
import os

// `SmartPlaylistRange` reaches this file through `PlaylistQuerySpec`'s public
// surface: the spec reuses the rule engine's own range type, so every consumer of
// its bounds imports `Persistence`.
import Persistence
import PlayerCoreTestSupport
import Services
import Testing

@Suite("HeuristicQueryParser")
struct HeuristicQueryParserTests {
    /// A parser whose embedding seam is unavailable — what `bg`/`ru` always get,
    /// and what every other locale gets on a host with no model assets.
    private static func parserWithoutEmbedding(
        genres: [String] = []
    ) -> HeuristicQueryParser {
        HeuristicQueryParser(knownGenres: { genres }, embeddingNeighbours: { _, _ in nil })
    }

    // MARK: Acceptance — the four cases the plan names

    @Test("English 'chill 90s evening' yields the nineties plus a low-energy mood")
    func englishChillNineties() async throws {
        let spec = try await Self.parserWithoutEmbedding()
            .parse(text: "chill 90s evening", locale: Locale(identifier: "en_US"))
        #expect(spec.yearRange == SmartPlaylistRange(lower: 1990, upper: 1999))
        #expect(spec.moodTags == [.calm])
        #expect(!spec.lowConfidence)
    }

    @Test("Bulgarian parses from the keyword table alone, with no embedding")
    func bulgarianWithoutEmbedding() async throws {
        let spec = try await Self.parserWithoutEmbedding()
            .parse(text: "спокойна музика от 90-те", locale: Locale(identifier: "bg_BG"))
        #expect(spec.yearRange == SmartPlaylistRange(lower: 1990, upper: 1999))
        #expect(spec.moodTags == [.calm])
        #expect(!spec.lowConfidence)
    }

    @Test("Russian parses from the keyword table alone, with no embedding")
    func russianWithoutEmbedding() async throws {
        let spec = try await Self.parserWithoutEmbedding()
            .parse(text: "спокойная музыка 90-х", locale: Locale(identifier: "ru_RU"))
        #expect(spec.yearRange == SmartPlaylistRange(lower: 1990, upper: 1999))
        #expect(spec.moodTags == [.calm])
        #expect(!spec.lowConfidence)
    }

    @Test("Gibberish becomes the tier-3 deterministic default")
    func gibberishBecomesTheDefault() async throws {
        let spec = try await Self.parserWithoutEmbedding()
            .parse(text: "qwzxk plkjhg vbnm", locale: Locale(identifier: "en_US"))
        #expect(spec == HeuristicQueryParser.deterministicDefault)
        #expect(spec.lowConfidence)
        #expect(spec.recency == .recentlyPlayed)
        #expect(spec.genres.isEmpty)
        #expect(spec.yearRange == nil)
        #expect(spec.moodTags.isEmpty)
    }

    @Test("Empty and whitespace-only text become the tier-3 default too")
    func emptyTextBecomesTheDefault() async throws {
        let parser = Self.parserWithoutEmbedding()
        let locale = Locale(identifier: "en_US")
        let empty = try await parser.parse(text: "", locale: locale)
        let blank = try await parser.parse(text: "   \n ", locale: locale)
        #expect(empty == HeuristicQueryParser.deterministicDefault)
        #expect(blank == HeuristicQueryParser.deterministicDefault)
    }

    // MARK: The nil-embedding contract

    @Test("A nil embedding never crashes, in any shipped locale")
    func nilEmbeddingIsSafeEverywhere() async throws {
        let parser = Self.parserWithoutEmbedding()
        for code in AssistantVocabulary.byLanguage.keys.sorted() {
            let locale = Locale(identifier: code)
            // Both a phrase the table knows and one it cannot know must return.
            let known = try await parser.parse(text: "chill", locale: locale)
            let unknown = try await parser.parse(text: "zzzzq wwwwq", locale: locale)
            #expect(known.targetCount >= 1)
            #expect(unknown == HeuristicQueryParser.deterministicDefault)
        }
    }

    @Test("The embedding boost fills a gap the table could not")
    func embeddingBoostRescuesAnUnknownWord() async throws {
        let parser = HeuristicQueryParser(embeddingNeighbours: { token, _ in
            token == "zzzzq" ? ["chill"] : nil
        })
        let spec = try await parser.parse(text: "zzzzq", locale: Locale(identifier: "en_US"))
        #expect(spec.moodTags == [.calm])
        #expect(!spec.lowConfidence)
    }

    @Test("The embedding is not consulted when the table already matched")
    func embeddingIsSkippedOnADirectHit() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let parser = HeuristicQueryParser(embeddingNeighbours: { _, _ in
            calls.withLock { $0 += 1 }
            return nil
        })
        _ = try await parser.parse(text: "chill 90s", locale: Locale(identifier: "en_US"))
        #expect(calls.withLock { $0 } == 0)
        _ = try await parser.parse(text: "zzzzq", locale: Locale(identifier: "en_US"))
        #expect(calls.withLock { $0 } > 0)
    }

    // MARK: Genres

    @Test("Genres are matched against the live library list, original spelling kept")
    func genresComeFromTheLibrary() async throws {
        let parser = Self.parserWithoutEmbedding(genres: ["Rock", "Drum and Bass", "Jazz"])
        let spec = try await parser.parse(
            text: "some Rock plus drum and bass",
            locale: Locale(identifier: "en_US")
        )
        #expect(spec.genres == ["Rock", "Drum and Bass"])
    }

    @Test("A single-word genre must match a whole token, never a prefix")
    func singleWordGenresDoNotPrefixMatch() async throws {
        let parser = Self.parserWithoutEmbedding(genres: ["Rock"])
        let spec = try await parser.parse(text: "rocket science", locale: Locale(identifier: "en_US"))
        #expect(spec.genres.isEmpty)
        #expect(spec == HeuristicQueryParser.deterministicDefault)
    }

    @Test("A failing genre lookup degrades to no genres, never to a thrown error")
    func genreFailureDegradesGracefully() async throws {
        let parser = HeuristicQueryParser(
            knownGenres: { throw FakeAssistantError.forcedFailure },
            embeddingNeighbours: { _, _ in nil }
        )
        let spec = try await parser.parse(text: "chill 90s rock", locale: Locale(identifier: "en_US"))
        #expect(spec.genres.isEmpty)
        #expect(spec.moodTags == [.calm])
        #expect(spec.yearRange == SmartPlaylistRange(lower: 1990, upper: 1999))
    }

    // MARK: Ranges, recency, determinism

    @Test("Tempo words produce half-open ranges, which is why SmartPlaylistRange is used")
    func tempoRangesAreHalfOpen() async throws {
        let parser = Self.parserWithoutEmbedding()
        let locale = Locale(identifier: "en_US")
        let fast = try await parser.parse(text: "fast", locale: locale)
        #expect(fast.tempoRange == SmartPlaylistRange(lower: TempoHint.fastLowerBPM))
        #expect(fast.tempoRange?.upper == nil)
        let slow = try await parser.parse(text: "slow", locale: locale)
        #expect(slow.tempoRange == SmartPlaylistRange(upper: TempoHint.slowUpperBPM))
        #expect(slow.tempoRange?.lower == nil)
    }

    @Test("Two decades in one request span their union")
    func twoDecadesSpanTheirUnion() async throws {
        let spec = try await Self.parserWithoutEmbedding()
            .parse(text: "80s and 90s hits", locale: Locale(identifier: "en_US"))
        #expect(spec.yearRange == SmartPlaylistRange(lower: 1980, upper: 1999))
    }

    @Test("Recency words map onto the history preferences")
    func recencyWordsAreRecognized() async throws {
        let parser = Self.parserWithoutEmbedding()
        let locale = Locale(identifier: "en_US")
        let fresh = try await parser.parse(text: "new arrivals", locale: locale)
        let rediscovered = try await parser.parse(text: "forgotten favourites", locale: locale)
        #expect(fresh.recency == .freshlyAdded)
        #expect(rediscovered.recency == .rediscovery)
    }

    @Test("Parsing the same request twice produces byte-identical specs")
    func parsingIsDeterministic() async throws {
        let parser = Self.parserWithoutEmbedding(genres: ["Rock", "Jazz"])
        let text = "chill slow forgotten rock from the 80s and 90s"
        let locale = Locale(identifier: "en_US")
        let first = try await parser.parse(text: text, locale: locale)
        for _ in 0 ..< 4 {
            let repeated = try await parser.parse(text: text, locale: locale)
            #expect(repeated == first)
        }
    }

    @Test("Track counts are deliberately not parsed, so a bare numeral stays a decade")
    func trackCountsAreNotParsed() async throws {
        let spec = try await Self.parserWithoutEmbedding()
            .parse(text: "20 chill songs", locale: Locale(identifier: "en_US"))
        #expect(spec.targetCount == MixSpec.defaultTargetCount)
    }

    @Test("An unlisted language falls back to the English table rather than to tier 3")
    func unlistedLanguageUsesTheEnglishTable() async throws {
        let spec = try await Self.parserWithoutEmbedding()
            .parse(text: "chill 90s", locale: Locale(identifier: "ja_JP"))
        #expect(spec.moodTags == [.calm])
        #expect(spec.yearRange == SmartPlaylistRange(lower: 1990, upper: 1999))
    }

    @Test("The tier-3 default is constrained, low confidence, and recency-shaped")
    func deterministicDefaultShape() {
        let spec = HeuristicQueryParser.deterministicDefault
        #expect(spec.lowConfidence)
        #expect(spec.recency == .recentlyPlayed)
        #expect(!spec.isUnconstrained)
        #expect(spec.targetCount == MixSpec.defaultTargetCount)
    }
}
