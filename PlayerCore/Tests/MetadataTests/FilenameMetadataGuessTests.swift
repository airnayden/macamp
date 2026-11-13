import Foundation
import Metadata
import Testing

@Suite("FilenameMetadataGuessTests")
struct FilenameMetadataGuessTests {
    // MARK: - Artist / title delimiter

    @Test("a plain 'Artist - Title' name splits on the hyphen delimiter")
    func plainArtistTitleSplits() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "Queen - Bohemian Rhapsody.mp3")
        #expect(guess.artist == "Queen")
        #expect(guess.title == "Bohemian Rhapsody")
    }

    @Test("an en-dash delimiter splits, and diacritics survive NFC normalisation")
    func enDashSplitsAndKeepsDiacritics() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "Café – Münchën.m4a")
        #expect(guess.artist == "Café")
        #expect(guess.title == "Münchën")
    }

    @Test("an em-dash delimiter splits")
    func emDashSplits() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "Artist — Title.flac")
        #expect(guess.artist == "Artist")
        #expect(guess.title == "Title")
    }

    @Test("only the FIRST delimiter splits — the rest stays in the title")
    func splitsOnFirstDelimiterOnly() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "A - B - C.mp3")
        #expect(guess.artist == "A")
        #expect(guess.title == "B - C")
    }

    @Test("a hyphen without surrounding spaces is not a delimiter")
    func tightHyphenIsNotADelimiter() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "no-delimiters.mp3")
        #expect(guess.artist == nil)
        #expect(guess.title == "no-delimiters")
    }

    // MARK: - Track-number prefix

    @Test("a '01 - ' prefix is stripped before the artist/title split")
    func numberedPrefixWithHyphenIsStripped() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "01 - Queen - Bohemian Rhapsody.flac")
        #expect(guess.artist == "Queen")
        #expect(guess.title == "Bohemian Rhapsody")
    }

    @Test("a '04 - ' prefix is stripped from a generic Artist - Title name")
    func numberedPrefixStripsForGenericName() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "04 - Artist - Title.mp3")
        #expect(guess.artist == "Artist")
        #expect(guess.title == "Title")
    }

    @Test("a '07. ' prefix is stripped and underscores become spaces")
    func dottedPrefixStripsAndUnderscoresBecomeSpaces() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "07. Bohemian_Rhapsody.mp3")
        #expect(guess.artist == nil)
        #expect(guess.title == "Bohemian Rhapsody")
    }

    @Test("a '3) ' prefix is stripped")
    func parenthesisedPrefixIsStripped() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "3) Bohemian Rhapsody.mp3")
        #expect(guess.artist == nil)
        #expect(guess.title == "Bohemian Rhapsody")
    }

    @Test("a bare number plus space is KEPT — it may be the title")
    func bareNumberPrefixIsKept() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "99 Luftballons.mp3")
        #expect(guess.artist == nil)
        #expect(guess.title == "99 Luftballons")
    }

    // MARK: - Content that must survive untouched

    @Test("parenthesised content is never stripped")
    func parenthesisedContentSurvives() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "Song (Live).mp3")
        #expect(guess.artist == nil)
        #expect(guess.title == "Song (Live)")
    }

    @Test("bracketed content is never stripped")
    func bracketedContentSurvives() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "Queen - Bohemian Rhapsody [Remaster].mp3")
        #expect(guess.artist == "Queen")
        #expect(guess.title == "Bohemian Rhapsody [Remaster]")
    }

    @Test("only ONE path extension is removed, and directories are ignored")
    func usesLastPathComponentMinusOneExtension() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "/Music/Queen - A Night/Queen - Song.tar.mp3")
        #expect(guess.artist == "Queen")
        #expect(guess.title == "Song.tar")
    }

    @Test("whitespace runs collapse to single spaces")
    func whitespaceRunsCollapse() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "Queen   -   Bohemian    Rhapsody.mp3")
        #expect(guess.artist == "Queen")
        #expect(guess.title == "Bohemian Rhapsody")
    }

    // MARK: - Failure cases (must not crash)

    @Test("a stem that collapses to nothing yields no guess")
    func emptyStemYieldsNothing() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "/Music/___.mp3")
        #expect(guess.artist == nil)
        #expect(guess.title == nil)
    }

    @Test("an empty path yields no guess")
    func emptyPathYieldsNothing() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "")
        #expect(guess.artist == nil)
        #expect(guess.title == nil)
    }

    @Test("the root path yields no guess")
    func rootPathYieldsNothing() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "/")
        #expect(guess.artist == nil)
        #expect(guess.title == nil)
    }

    @Test("a directory path ending in a slash yields no guess")
    func trailingSlashPathYieldsNothing() {
        let guess = FilenameMetadataGuess.guess(fromFilePath: "/Users/someone/Music/")
        #expect(guess.artist == nil)
        #expect(guess.title == nil)
    }
}
