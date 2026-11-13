// Fixture-driven coverage of the happy paths: exact frame arithmetic, per-FILE offset
// restart, and the EAC-variant normalization.
import Foundation
import Services
import Testing

@Suite("CUE sheet parsing")
struct CueSheetParserTests {
    private let locator = StubCueAudioFileLocator()

    private func parse(_ fixture: String) throws -> CueSheet {
        let url = CueFixtures.url(fixture)
        return try CueSheetParser.parse(
            contents: CueFixtures.contents(fixture),
            sheetURL: url,
            locator: locator
        )
    }

    // MARK: Single file

    @Test("A single-FILE sheet yields one track per TRACK with exact INDEX 01 frames")
    func singleFileFrames() throws {
        let sheet = try parse("standard-single-file.cue")

        #expect(sheet.tracks.count == 4)
        #expect(sheet.tracks.map(\.number) == [1, 2, 3, 4])
        #expect(sheet.tracks.map(\.startFrame) == [0, 21225, 38062, 57540])
        #expect(sheet.unresolvedFiles.isEmpty)
        #expect(sheet.containsEACAppendedGaps == false)
    }

    @Test("Each track ends where the next one starts; the last runs to end of file")
    func singleFileEndFrames() throws {
        let sheet = try parse("standard-single-file.cue")

        #expect(sheet.tracks.map(\.endFrame) == [21225, 38062, 57540, nil])
        #expect(sheet.tracks.map(\.frameCount) == [21225, 16837, 19478, nil])
    }

    @Test("INDEX 00 and PREGAP are carried without moving the track's start")
    func singleFileGaps() throws {
        let sheet = try parse("standard-single-file.cue")
        let second = try #require(sheet.tracks.first { $0.number == 2 })
        let fourth = try #require(sheet.tracks.first { $0.number == 4 })

        #expect(second.indexZeroFrame == 21100)
        #expect(second.startFrame == 21225)
        #expect(fourth.pregapFrames == 150)
        #expect(fourth.indexZeroFrame == nil)
        #expect(fourth.startFrame == 57540)
    }

    @Test("Disc-level metadata and REM GENRE/DATE land on the sheet, not on the tracks")
    func discMetadata() throws {
        let sheet = try parse("standard-single-file.cue")

        #expect(sheet.title == "Portishead")
        #expect(sheet.performer == "Portishead")
        #expect(sheet.genre == "Trip-Hop")
        #expect(sheet.date == "1997")
        #expect(sheet.tracks.map(\.title) == ["Cowboys", "All Mine", "Undenied", "Half Day Closing"])
    }

    @Test("Every track of a single-FILE sheet points at the same audio file")
    func singleFileSharesOneAudioPath() throws {
        let sheet = try parse("standard-single-file.cue")

        #expect(sheet.audioFilePaths.count == 1)
        #expect(sheet.tracks.allSatisfy { $0.filePath.hasSuffix("/Portishead - Portishead.flac") })
        #expect(sheet.tracks.allSatisfy { !$0.filePath.hasSuffix(".cue") })
        #expect(sheet.sheetPath.hasSuffix("standard-single-file.cue"))
    }

    // MARK: Multi-file

    @Test("A multi-FILE sheet restarts offsets at each FILE")
    func multiFileOffsetsRestart() throws {
        let sheet = try parse("multi-file.cue")

        #expect(sheet.tracks.count == 3)
        // 00:02:33 = 183 frames INTO ITS OWN FILE. A parser that accumulated disc-wide
        // offsets would report a value in the tens of thousands here.
        #expect(sheet.tracks.map(\.startFrame) == [0, 183, 0])
        #expect(sheet.tracks.map(\.endFrame) == [nil, nil, nil])
        #expect(sheet.audioFilePaths.count == 3)
    }

    @Test("A multi-FILE sheet keeps per-track performers distinct from the disc performer")
    func multiFilePerTrackMetadata() throws {
        let sheet = try parse("multi-file.cue")

        #expect(sheet.performer == "Miles Davis")
        #expect(sheet.tracks.map(\.performer) == ["Miles Davis", "Miles Davis", "Bill Evans"])
        #expect(sheet.tracks.map(\.indexZeroFrame) == [nil, 0, nil])
    }

    // MARK: EAC variant

    @Test("The EAC gaps-appended variant normalizes to its compliant twin's segments")
    func eacVariantMatchesCompliantTwin() throws {
        let variant = try parse("eac-appended-gaps.cue")
        let twin = try parse("eac-compliant-twin.cue")

        #expect(variant.tracks.map(\.segment) == twin.tracks.map(\.segment))
        #expect(variant.tracks.count == 3)
        #expect(variant.tracks.map(\.startFrame) == [0, 0, 0])
        #expect(variant.tracks.map(\.endFrame) == [nil, nil, nil])
    }

    @Test("The fold is recorded as provenance, and only on the variant")
    func eacVariantIsFlagged() throws {
        let variant = try parse("eac-appended-gaps.cue")
        let twin = try parse("eac-compliant-twin.cue")

        #expect(variant.containsEACAppendedGaps)
        #expect(variant.tracks.map(\.hasAppendedGapInPriorFile) == [false, true, true])
        #expect(twin.containsEACAppendedGaps == false)
        #expect(twin.tracks.allSatisfy { !$0.hasAppendedGapInPriorFile })
    }

    @Test("The folded orphan leaves no duplicate track row behind")
    func eacVariantHasNoDuplicateTracks() throws {
        let variant = try parse("eac-appended-gaps.cue")

        #expect(Set(variant.tracks.map(\.number)).count == variant.tracks.count)
        #expect(variant.tracks.map(\.number) == [1, 2, 3])
    }
}
