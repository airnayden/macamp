// Lexical robustness, driven through the public parse API: the shapes real sheets arrive
// in that a naive line-splitter gets wrong.
import Foundation
import Services
import Testing

@Suite("CUE grammar robustness")
struct CueGrammarTests {
    private let sheetURL = URL(fileURLWithPath: "/tmp/macamp-cue-tests/album.cue")
    private let locator = StubCueAudioFileLocator()

    private func parse(_ contents: String) throws -> CueSheet {
        try CueSheetParser.parse(contents: contents, sheetURL: sheetURL, locator: locator)
    }

    @Test("Quoted operands keep their spaces; indentation and blank lines are discarded")
    func quotingAndWhitespace() throws {
        let contents = """

        TITLE "The Dark Side of the Moon"

        \tFILE "Pink Floyd - The Dark Side of the Moon.flac" WAVE
                TRACK 01 AUDIO
                  TITLE "Speak to Me / Breathe"
                  INDEX 01 00:00:00

        """
        let sheet = try parse(contents)

        #expect(sheet.title == "The Dark Side of the Moon")
        #expect(sheet.tracks.first?.title == "Speak to Me / Breathe")
        #expect(sheet.tracks.first?.filePath.hasSuffix("Pink Floyd - The Dark Side of the Moon.flac") == true)
    }

    @Test("Commands are matched case-insensitively")
    func caseInsensitiveCommands() throws {
        let contents = """
        title "Lowercase Album"
        File "a.flac" Wave
          track 01 audio
            Title "Lowercase Track"
            index 01 00:01:00
        """
        let sheet = try parse(contents)

        #expect(sheet.title == "Lowercase Album")
        #expect(sheet.tracks.map(\.startFrame) == [75])
        #expect(sheet.tracks.first?.title == "Lowercase Track")
    }

    @Test("A CRLF sheet numbers lines identically to a Unix one")
    func crlfLineNumbering() {
        let contents = "FILE \"a.flac\" WAVE\r\n  TRACK 01 AUDIO\r\n    INDEX 05 00:00:00\r\n"

        // INDEX 05 leaves the track with no INDEX 01; the line must be 2 (the TRACK),
        // which a parser that counted \r and \n separately would report as 3.
        #expect(throws: CueParseError.missingIndexOne(trackNumber: 1, line: 2)) {
            try parse(contents)
        }
    }

    @Test("A UTF-8 BOM does not hide the first command")
    func byteOrderMarkIsStripped() throws {
        let sheet =
            try parse("\u{FEFF}TITLE \"BOM Album\"\nFILE \"a.flac\" WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n")

        #expect(sheet.title == "BOM Album")
        #expect(sheet.tracks.count == 1)
    }

    @Test("An unquoted FILE name keeps its spaces once the format keyword is dropped")
    func unquotedFileName() throws {
        let sheet = try parse("FILE 01 - So What.flac WAVE\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n")

        #expect(sheet.tracks.first?.filePath.hasSuffix("/01 - So What.flac") == true)
    }

    @Test("Unquoted REM values rejoin; unknown remarks are discarded")
    func remarkHandling() throws {
        let contents = """
        REM GENRE Progressive Rock
        REM DATE 1973-03-01
        REM DISCID 830B0C0B
        REM COMMENT "ExactAudioCopy v1.0"
        FILE "a.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        """
        let sheet = try parse(contents)

        #expect(sheet.genre == "Progressive Rock")
        #expect(sheet.date == "1973-03-01")
    }

    @Test("Unknown commands are ignored rather than refused")
    func unknownCommandsAreIgnored() throws {
        let contents = """
        CATALOG 0602537351169
        CDTEXTFILE "album.cdt"
        FILE "a.flac" WAVE
          TRACK 01 AUDIO
            FLAGS DCP
            ISRC GBAYE0000123
            SONGWRITER "Someone Else"
            INDEX 01 00:00:00
        """
        let sheet = try parse(contents)

        #expect(sheet.tracks.count == 1)
        #expect(sheet.tracks.first?.startFrame == 0)
    }

    @Test("A track-level TITLE never leaks onto the disc")
    func trackTitleDoesNotOverwriteDiscTitle() throws {
        let contents = """
        TITLE "Album Title"
        PERFORMER "Album Artist"
        FILE "a.flac" WAVE
          TRACK 01 AUDIO
            TITLE "Track Title"
            PERFORMER "Track Artist"
            INDEX 01 00:00:00
        """
        let sheet = try parse(contents)

        #expect(sheet.title == "Album Title")
        #expect(sheet.performer == "Album Artist")
        #expect(sheet.tracks.first?.title == "Track Title")
        #expect(sheet.tracks.first?.performer == "Track Artist")
    }
}
