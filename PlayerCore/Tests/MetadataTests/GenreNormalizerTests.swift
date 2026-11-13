import Foundation
import Metadata
import Testing

@Suite("GenreNormalizerTests")
struct GenreNormalizerTests {
    // MARK: - Empty / nil

    @Test("nil and blank input normalise to nil")
    func blankCollapsesToNil() {
        #expect(GenreNormalizer.normalize(nil) == nil)
        #expect(GenreNormalizer.normalize("") == nil)
        #expect(GenreNormalizer.normalize("   ") == nil)
    }

    // MARK: - Plain text passes through (no splitting on '/', ' ', ';')

    @Test("plain-text genres pass through unchanged")
    func plainTextPassesThrough() {
        #expect(GenreNormalizer.normalize("Rock") == "Rock")
        #expect(GenreNormalizer.normalize("Progressive Rock") == "Progressive Rock")
        #expect(GenreNormalizer.normalize("Pop/Funk") == "Pop/Funk")
        #expect(GenreNormalizer.normalize("Drum & Bass") == "Drum & Bass")
    }

    // MARK: - ID3 numeric codes

    @Test("parenthesised ID3 numeric codes resolve to canonical names")
    func parenthesisedCodesResolve() {
        #expect(GenreNormalizer.normalize("(17)") == "Rock")
        #expect(GenreNormalizer.normalize("(0)") == "Blues")
        #expect(GenreNormalizer.normalize("(13)") == "Pop")
        #expect(GenreNormalizer.normalize("(9)") == "Metal")
        #expect(GenreNormalizer.normalize("(32)") == "Classical")
        #expect(GenreNormalizer.normalize("(62)") == "Pop/Funk")
        #expect(GenreNormalizer.normalize("(137)") == "Heavy Metal")
    }

    @Test("bare numeric codes resolve to canonical names")
    func bareNumericCodesResolve() {
        #expect(GenreNormalizer.normalize("17") == "Rock")
        #expect(GenreNormalizer.normalize("0") == "Blues")
    }

    @Test("RX and CR refinements map to Remix and Cover")
    func refinementTokensResolve() {
        #expect(GenreNormalizer.normalize("(RX)") == "Remix")
        #expect(GenreNormalizer.normalize("(CR)") == "Cover")
    }

    // MARK: - Multi-genre: pick the first

    @Test("a (code)(code) list resolves the FIRST code only")
    func multiCodeListPicksFirst() {
        // 17 = Rock, 18 = Techno — only the first is used.
        #expect(GenreNormalizer.normalize("(17)(18)") == "Rock")
    }

    @Test("a NUL-separated multi-value tag keeps the FIRST value")
    func nulSeparatedPicksFirst() {
        #expect(GenreNormalizer.normalize("Rock\u{0}Pop") == "Rock")
        #expect(GenreNormalizer.normalize("(17)\u{0}(13)") == "Rock")
    }

    // MARK: - Refinement vs. known code

    @Test("a known code wins over any trailing refinement")
    func knownCodeWinsOverRefinement() {
        #expect(GenreNormalizer.normalize("(17)Hardcore") == "Rock")
    }

    @Test("an unknown code falls back to its trailing refinement")
    func unknownCodeUsesRefinement() {
        #expect(GenreNormalizer.normalize("(255)Bluegrass") == "Bluegrass")
    }

    @Test("an unknown code with no refinement passes the raw token through")
    func unknownCodeNoRefinementPassesThrough() {
        #expect(GenreNormalizer.normalize("(255)") == "(255)")
    }
}
