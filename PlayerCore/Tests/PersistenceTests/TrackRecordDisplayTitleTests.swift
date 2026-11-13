// TrackRecordDisplayTitleTests — pins the fallback that keeps an untagged track
// from rendering a full absolute path where a song name belongs.
//
// The transform is deliberately SIMPLER than `FilenameMetadataGuess`: one extension
// off the last path component and nothing else. No underscore substitution, no case
// folding, no artist/title splitting. A case here that starts passing because
// someone routed `displayTitle` through the guesser is a regression, not an
// improvement — `stemIsNotRewritten` is the fence.
import Foundation
import Persistence
import Testing

@Suite("TrackRecordDisplayTitleTests")
struct TrackRecordDisplayTitleTests {
    private func record(path: String, title: String?) -> TrackRecord {
        TrackRecord(filePath: path, title: title)
    }

    @Test("An untagged track falls back to its filename stem")
    func nilTitleFallsBackToStem() {
        let track = record(path: "/Volumes/M/90s/CD33/3301-untagged.mp3", title: nil)
        #expect(track.displayTitle == "3301-untagged")
    }

    @Test("A whitespace-only title is treated as no title at all")
    func whitespaceTitleFallsBackToStem() {
        let track = record(path: "/Volumes/M/90s/CD33/3301-untagged.mp3", title: "  ")
        #expect(track.displayTitle == "3301-untagged")
    }

    @Test("Exactly one extension is stripped from the stem")
    func stripsOnlyTheFinalExtension() {
        let track = record(path: "/music/a.b.mp3", title: nil)
        #expect(track.displayTitle == "a.b")
    }

    @Test("A real tag title wins and is used verbatim")
    func taggedTitleWinsVerbatim() {
        let track = record(path: "/music/3301-untagged.mp3", title: "Everything In Its Right Place")
        #expect(track.displayTitle == "Everything In Its Right Place")
    }

    /// A leading dot is part of the name, not an extension separator, so the whole
    /// component survives. Foundation already reads it this way; the `isEmpty` guard
    /// in `filenameStem` is the belt-and-braces that keeps the result non-empty if
    /// that ever changes.
    @Test("A dotfile-style stem keeps its leading dot")
    func dotfileStemIsPreserved() {
        let track = record(path: "/music/.hidden", title: nil)
        #expect(track.displayTitle == ".hidden")
    }

    @Test("A tag title is trimmed of surrounding whitespace")
    func taggedTitleIsTrimmed() {
        let track = record(path: "/music/3301-untagged.mp3", title: "  Pyramid Song  ")
        #expect(track.displayTitle == "Pyramid Song")
    }

    @Test("The stem is verbatim — no underscore or case rewriting")
    func stemIsNotRewritten() {
        let track = record(path: "/music/01_THE_bends.flac", title: nil)
        #expect(track.displayTitle == "01_THE_bends")
    }

    @Test("A file with no extension keeps its whole name")
    func extensionlessFileKeepsWholeName() {
        let track = record(path: "/music/noextension", title: nil)
        #expect(track.displayTitle == "noextension")
    }

    @Test("An untagged track never renders a directory separator")
    func fallbackNeverContainsAPathSeparator() {
        let track = record(path: "/Volumes/ANDROMEDA/music/90s - Greatest Hits/CD33/3301.mp3", title: nil)
        #expect(!track.displayTitle.contains("/"))
        #expect(track.displayTitle == "3301")
    }
}
