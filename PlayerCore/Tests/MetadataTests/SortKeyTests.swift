import Foundation
import Metadata
import Testing

@Suite("SortKeyTests")
struct SortKeyTests {
    // MARK: - NFC normalisation

    @Test("normalized() composes decomposed (NFD) input to NFC")
    func normalizesToNFC() {
        let decomposed = "Cafe\u{0301}" // e + combining acute
        let normalised = SortKey.normalized(decomposed)
        #expect(normalised == "Café".precomposedStringWithCanonicalMapping)
        #expect(normalised.unicodeScalars.count == 4)
        #expect(!normalised.unicodeScalars.contains("\u{0301}"))
    }

    @Test("normalizedOrNil() trims and collapses blank values to nil")
    func normalizedOrNilTrimsAndCollapses() {
        #expect(SortKey.normalizedOrNil(nil) == nil)
        #expect(SortKey.normalizedOrNil("") == nil)
        #expect(SortKey.normalizedOrNil("   ") == nil)
        #expect(SortKey.normalizedOrNil("  hi  ") == "hi")
    }

    // MARK: - Article stripping

    @Test("sortKey strips a single leading English article", arguments: [
        ("The Beatles", "beatles"),
        ("the beatles", "beatles"),
        ("A Tribe Called Quest", "tribe called quest"),
        ("An Anthem", "anthem"),
        ("The The", "the"),
        ("Apple", "apple"),
        ("Theremin", "theremin"),
        ("Anaconda", "anaconda"),
    ])
    func stripsArticles(input: String, expected: String) {
        #expect(SortKey.sortKey(for: input) == expected)
    }

    @Test("a bare article is not reduced to an empty key")
    func bareArticleSurvives() {
        #expect(SortKey.sortKey(for: "The") == "the")
        #expect(SortKey.sortKey(for: "The ") == "the")
    }

    // MARK: - Accented + CJK collation

    @Test("sortKey folds diacritics and romanises CJK / full-width", arguments: [
        ("Café del Mar", "cafe del mar"),
        ("Naïve", "naive"),
        ("Ñoño", "nono"),
        ("日本語", "ri ben yu"),
        ("中文", "zhong wen"),
        ("ＡＢＣ", "abc"),
    ])
    func foldsAndRomanises(input: String, expected: String) {
        #expect(SortKey.sortKey(for: input) == expected)
    }

    // MARK: - Ordering correctness (what the keys are FOR)

    @Test("article-stripped keys sort under the real first letter")
    func sortsUnderRealFirstLetter() {
        let beatles = SortKey.sortKey(for: "The Beatles")
        #expect(beatles == "beatles")
        #expect(SortKey.sortKey(for: "Bach") < beatles) // bach < beatles
        #expect(beatles < SortKey.sortKey(for: "Beethoven")) // beatles < beethoven
        #expect(beatles < SortKey.sortKey(for: "The Cure")) // beatles < cure
    }

    @Test("accented and unaccented spellings collate together")
    func accentedCollatesWithBase() {
        #expect(SortKey.sortKey(for: "Café") == SortKey.sortKey(for: "Cafe"))
        #expect(SortKey.sortKey(for: "Motörhead") == SortKey.sortKey(for: "Motorhead"))
    }

    @Test("sortKey is deterministic across repeated calls")
    func deterministic() {
        let first = SortKey.sortKey(for: "Þe Naïve 日本語")
        let second = SortKey.sortKey(for: "Þe Naïve 日本語")
        #expect(first == second)
    }

    // MARK: - Optional helpers

    @Test("sortKeyOrNil maps blank / nil to nil")
    func sortKeyOrNilCollapses() {
        #expect(SortKey.sortKeyOrNil(nil) == nil)
        #expect(SortKey.sortKeyOrNil("   ") == nil)
        #expect(SortKey.sortKeyOrNil("The Doors") == "doors")
    }
}
