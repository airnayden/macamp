// GenreVocabularyMatcherTests — the vocabulary guard every model-driven tier shares.
//
// The matcher is pure and floor-available, so these cases need no model, no session
// and no database: proposals and a vocabulary in, surviving names out. They pin the
// two failures the guard exists for — a genre the library does not hold, and a real
// genre spelled differently — alongside the three NON-rules that belong to other
// layers and must not creep in here: no de-duplication, no fuzzy spelling
// correction, and no dropping when the vocabulary itself is empty.
import Services
import Testing

@Suite("GenreVocabularyMatching")
struct GenreVocabularyMatcherTests {
    /// One row of the matching table.
    struct Scenario {
        var proposed: [String]
        var vocabulary: [String]
        var expected: [String]
        var label: String
    }

    static let library = ["Rock", "Progressive Metal", "Jazz"]

    static let scenarios: [Scenario] = [
        Scenario(
            proposed: ["Rock", "Vaporwave", "Jazz"],
            vocabulary: library,
            expected: ["Rock", "Jazz"],
            label: "a hallucinated genre is dropped, the real ones survive"
        ),
        Scenario(
            proposed: ["Vaporwave", "Chillsynth", "Hyperpop"],
            vocabulary: library,
            expected: [],
            label: "every genre hallucinated yields an empty list, not a crash"
        ),
        Scenario(
            proposed: ["rock", "PROGRESSIVE METAL"],
            vocabulary: library,
            expected: ["Rock", "Progressive Metal"],
            label: "a differently-cased genre is rewritten to the library's spelling"
        ),
        Scenario(
            proposed: ["  Jazz "],
            vocabulary: library,
            expected: ["Jazz"],
            label: "surrounding whitespace does not stop a genre from matching"
        ),
        Scenario(
            proposed: ["Rockk", "Prog Metal"],
            vocabulary: library,
            expected: [],
            label: "a genuinely misspelled genre is dropped, never fuzzily corrected"
        ),
        Scenario(
            proposed: ["Rock", "Vaporwave"],
            vocabulary: [],
            expected: ["Rock", "Vaporwave"],
            label: "an empty vocabulary passes everything through rather than dropping all"
        ),
        Scenario(
            proposed: ["Jazz", "rock", "ROCK"],
            vocabulary: library,
            expected: ["Jazz", "Rock", "Rock"],
            label: "order is preserved and duplicates are NOT collapsed here"
        ),
        Scenario(
            proposed: ["ROCK"],
            vocabulary: ["Rock", "rock"],
            expected: ["Rock"],
            label: "a vocabulary holding two spellings resolves to the first"
        ),
        Scenario(
            proposed: [],
            vocabulary: library,
            expected: [],
            label: "no proposals means no genres, with a vocabulary present"
        ),
        Scenario(
            proposed: ["Rock", "   "],
            vocabulary: ["Rock", "   ", ""],
            expected: ["Rock"],
            label: "blank entries on either side are ignored rather than matched"
        ),
    ]

    @Test("Every proposal resolves against the vocabulary as documented", arguments: scenarios)
    func matchesTheVocabulary(_ scenario: Scenario) {
        let matched = GenreVocabularyMatcher.validated(scenario.proposed, against: scenario.vocabulary)
        #expect(matched == scenario.expected, "\(scenario.label)")
    }

    @Test("A vocabulary of any size never invents a name the library does not hold")
    func neverInventsAName() {
        for scenario in Self.scenarios where !scenario.vocabulary.isEmpty {
            let matched = GenreVocabularyMatcher.validated(scenario.proposed, against: scenario.vocabulary)
            #expect(matched.allSatisfy(scenario.vocabulary.contains), "\(scenario.label)")
        }
    }
}

@Suite("GenreVocabularyMatcherDelegation")
struct GenreVocabularyMatcherDelegationTests {
    private let library = ["Rock", "Progressive Metal", "Jazz"]

    @Test("The FM tier's resolve produces exactly what the matcher produces")
    func fmTierDelegatesToTheMatcher() {
        let proposed = ["rock", "Vaporwave", "  PROGRESSIVE METAL "]
        let resolved = FMQuerySpecFields(genres: proposed).resolve(validGenres: library).genres
        #expect(resolved == GenreVocabularyMatcher.validated(proposed, against: library))
    }

    @Test("De-duplication is the spec's rule, applied after the matcher has run")
    func specCollapsesWhatTheMatcherRepeats() {
        let proposed = ["Jazz", "rock", "ROCK"]
        #expect(GenreVocabularyMatcher.validated(proposed, against: library) == ["Jazz", "Rock", "Rock"])
        #expect(FMQuerySpecFields(genres: proposed).resolve(validGenres: library).genres == ["Jazz", "Rock"])
    }

    @Test("An all-hallucinated request resolves to an unconstrained, low-confidence spec")
    func allHallucinatedGenresAreLowConfidence() {
        let spec = FMQuerySpecFields(genres: ["Vaporwave", "Hyperpop"]).resolve(validGenres: library)
        #expect(spec.genres.isEmpty)
        // The FM tier reads "every value was unservable" as an unconfident answer
        // rather than a confident empty one; the connector tier mirrors this.
        #expect(spec.isUnconstrained)
        #expect(spec.lowConfidence)
    }
}
