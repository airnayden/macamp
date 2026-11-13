// Refusal coverage: every typed error the grammar raises, plus the ONE failure the
// parser reports as data instead of throwing (a `FILE` that is not on disk).
import Foundation
import Services
import Testing

@Suite("CUE sheet refusals")
struct CueSheetParserErrorTests {
    private let sheetURL = URL(fileURLWithPath: "/tmp/macamp-cue-tests/album.cue")
    private let locator = StubCueAudioFileLocator()

    private func parse(_ contents: String) throws -> CueSheet {
        try CueSheetParser.parse(contents: contents, sheetURL: sheetURL, locator: locator)
    }

    // MARK: INDEX 01 is mandatory

    @Test("A TRACK with no INDEX 01 and no later FILE to fold into is refused")
    func missingIndexOneIsRefused() throws {
        let contents = try CueFixtures.contents("malformed-missing-index01.cue")
        let url = CueFixtures.url("malformed-missing-index01.cue")

        #expect(throws: CueParseError.missingIndexOne(trackNumber: 2, line: 8)) {
            try CueSheetParser.parse(contents: contents, sheetURL: url, locator: locator)
        }
    }

    // MARK: A dead FILE reference is DATA, not a throw

    @Test("A FILE with no audio on disk surfaces as an unresolved reference")
    func unresolvedFileIsReportedAsData() throws {
        // Deliberately the PRODUCTION locator against the fixtures directory, which
        // commits no audio — so this exercises the real filesystem path end to end.
        let sheet = try CueSheetParser.parse(sheetURL: CueFixtures.url("standard-single-file.cue"))

        #expect(sheet.tracks.isEmpty)
        #expect(sheet.unresolvedFiles.count == 1)
        let reference = try #require(sheet.unresolvedFiles.first)
        #expect(reference.fileName == "Portishead - Portishead.flac")
        #expect(reference.lineNumber == 6)
        #expect(reference.trackNumbers == [1, 2, 3, 4])
        #expect(sheet.title == "Portishead")
    }

    @Test("One dead FILE in a multi-FILE sheet does not discard the others")
    func partiallyUnresolvedSheetKeepsResolvableTracks() throws {
        let missing = StubCueAudioFileLocator(missing: ["02 - Freddie Freeloader.flac"])
        let sheet = try CueSheetParser.parse(
            contents: CueFixtures.contents("multi-file.cue"),
            sheetURL: CueFixtures.url("multi-file.cue"),
            locator: missing
        )

        #expect(sheet.tracks.map(\.number) == [1, 3])
        #expect(sheet.unresolvedFiles.map(\.trackNumbers) == [[2]])
        #expect(sheet.unresolvedFiles.map(\.lineNumber) == [10])
    }

    // MARK: Structural refusals

    @Test("A TRACK before any FILE is refused")
    func trackOutsideFile() {
        #expect(throws: CueParseError.trackOutsideFile(trackNumber: 1, line: 1)) {
            try parse("TRACK 01 AUDIO\n  INDEX 01 00:00:00\n")
        }
    }

    @Test("An INDEX before any TRACK is refused")
    func indexOutsideTrack() {
        #expect(throws: CueParseError.indexOutsideTrack(line: 2)) {
            try parse("FILE \"a.flac\" WAVE\n  INDEX 01 00:00:00\n")
        }
    }

    @Test("A sheet with no FILE at all is refused")
    func emptySheet() {
        #expect(throws: CueParseError.emptySheet) {
            try parse("REM GENRE Rock\nTITLE \"Nothing Here\"\n")
        }
    }

    @Test("PREGAP and INDEX 00 on one track are refused as double-counted gap")
    func conflictingPregap() {
        let contents = """
        FILE "a.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            PREGAP 00:02:00
            INDEX 00 03:00:00
            INDEX 01 03:02:00
        """
        #expect(throws: CueParseError.conflictingPregap(trackNumber: 2, line: 4)) {
            try parse(contents)
        }
    }

    @Test("A repeated TRACK number outside the EAC shape is refused")
    func duplicateTrackNumber() {
        let contents = """
        FILE "a.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        FILE "b.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
        """
        #expect(throws: CueParseError.duplicateTrackNumber(1, line: 5)) {
            try parse(contents)
        }
    }

    @Test("A repeated INDEX number inside one TRACK is refused")
    func duplicateIndex() {
        let contents = """
        FILE "a.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
            INDEX 01 00:01:00
        """
        #expect(throws: CueParseError.duplicateIndex(number: 1, trackNumber: 1, line: 4)) {
            try parse(contents)
        }
    }

    @Test("A non-advancing INDEX 01 inside one FILE is refused")
    func nonMonotonicIndexOne() {
        let contents = """
        FILE "a.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:10:00
          TRACK 02 AUDIO
            INDEX 01 00:05:00
        """
        #expect(throws: CueParseError.nonMonotonicIndexOne(trackNumber: 2, line: 4)) {
            try parse(contents)
        }
    }

    // MARK: Lexical refusals

    @Test("An out-of-range timecode is refused with the offending text")
    func malformedTimecode() {
        let contents = """
        FILE "a.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:60:00
        """
        #expect(throws: CueParseError.malformedTimecode("00:60:00", line: 3)) {
            try parse(contents)
        }
    }

    @Test("A non-numeric TRACK number is refused")
    func malformedTrackNumber() {
        #expect(throws: CueParseError.malformedTrackNumber("AUDIO", line: 2)) {
            try parse("FILE \"a.flac\" WAVE\n  TRACK AUDIO\n")
        }
    }

    @Test("An INDEX with no timecode is refused")
    func missingOperand() {
        let contents = """
        FILE "a.flac" WAVE
          TRACK 01 AUDIO
            INDEX 01
        """
        #expect(throws: CueParseError.missingOperand(command: "INDEX", line: 3)) {
            try parse(contents)
        }
    }

    @Test("A .cue file that cannot be read is refused by path")
    func unreadableSheet() {
        let missing = URL(fileURLWithPath: "/tmp/macamp-cue-tests/does-not-exist.cue")
        #expect(throws: CueParseError.unreadableSheet(path: missing.path)) {
            try CueSheetParser.parse(sheetURL: missing, locator: locator)
        }
    }
}
