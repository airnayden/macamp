// Fixtures for the scanner's `.cue` sidecar import (todo 30).
//
// The album is a single FLAC plus a five-track sheet, which is the shape the whole
// feature exists for: one audio file, five rows, one `filePath`, five start frames.
// Frames are CD frames at 75/second, so the offsets below are exact.
import Foundation
import Metadata
import Persistence
@testable import Services

enum CueScanFixtures {
    static let audioFileName = "album.flac"
    static let sheetFileName = "album.cue"

    /// `INDEX 01` of each track, in frames: 0s, 30s, 60s, 90s, 120s.
    static let startFrames: [Int64] = [0, 2250, 4500, 6750, 9000]
    static let titles = ["One", "Two", "Three", "Four", "Five"]
    static let discTitle = "Disc Title"
    static let discPerformer = "Disc Artist"
    static let firstTrackPerformer = "Track One Artist"

    /// Every segment but the last is bounded by the next `INDEX 01`, so 30 seconds.
    /// The last runs to the end of the audio file, whose tagged length is
    /// ``FakeMetadataReader/defaultMetadata``'s 259 s — 120 s of which precede it.
    static let expectedDurations: [Double] = [30, 30, 30, 30, 139]

    static let sheetText = """
    REM GENRE Electronic
    REM DATE 1997-04-29
    PERFORMER "\(discPerformer)"
    TITLE "\(discTitle)"
    FILE "\(audioFileName)" WAVE
      TRACK 01 AUDIO
        TITLE "One"
        PERFORMER "\(firstTrackPerformer)"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "Two"
        INDEX 01 00:30:00
      TRACK 03 AUDIO
        TITLE "Three"
        INDEX 01 01:00:00
      TRACK 04 AUDIO
        TITLE "Four"
        INDEX 01 01:30:00
      TRACK 05 AUDIO
        TITLE "Five"
        INDEX 01 02:00:00
    """

    /// A sheet naming an audio file that is not on disk — the failure path.
    static let unresolvedSheetText = """
    TITLE "Ghost"
    FILE "not-here.flac" WAVE
      TRACK 01 AUDIO
        TITLE "Nothing"
        INDEX 01 00:00:00
      TRACK 02 AUDIO
        TITLE "Also Nothing"
        INDEX 01 00:30:00
    """

    /// The path `FileManager.enumerator` — and therefore the stored `filePath` —
    /// actually uses.
    ///
    /// On macOS `/var` is a symlink to `/private/var`, so a literal
    /// `temporaryDirectory` URL reads `/var/…` while the walk yields `/private/var/…`.
    /// Foundation's `resolvingSymlinksInPath()` cannot bridge that: it is documented
    /// to STRIP a leading `/private`, i.e. it resolves in the opposite direction.
    /// `realpath(3)` is the one call that returns the fully-resolved form.
    private static func resolved(_ url: URL) -> URL {
        guard let buffer = realpath(url.path, nil) else { return url }
        defer { free(buffer) }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    @discardableResult
    static func writeAudio(in dir: URL) throws -> URL {
        try resolved(ScannerFixtures.writeFile(in: dir, name: audioFileName))
    }

    @discardableResult
    static func writeSheet(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(sheetFileName)
        try sheetText.write(to: url, atomically: true, encoding: .utf8)
        return resolved(url)
    }

    /// Writes both halves of the album and returns their URLs.
    @discardableResult
    static func writeAlbum(in dir: URL) throws -> (audio: URL, sheet: URL) {
        let audio = try writeAudio(in: dir)
        let sheet = try writeSheet(in: dir)
        return (audio, sheet)
    }

    @discardableResult
    static func writeUnresolvedSheet(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("ghost.cue")
        try unresolvedSheetText.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Every `track` row for the album's audio file, in playing order.
    static func storedSegments(_ database: AppDatabase, audio: URL) throws -> [TrackRecord] {
        try database.writer.read { db in
            try TrackRecord.requestForAllRows(filePath: audio.path).fetchAll(db)
        }
    }
}

/// A ``MetadataReading`` that records every URL it is asked to read, so a test can
/// prove the `.cue` sidecar never entered the metadata path and that a five-segment
/// sheet costs exactly ONE tag read of its audio file.
final class CountingMetadataReader: MetadataReading, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [URL] = []
    private let metadata: TrackMetadata

    init(metadata: TrackMetadata = FakeMetadataReader.defaultMetadata) {
        self.metadata = metadata
    }

    func readMetadata(from url: URL) throws -> TrackMetadata {
        lock.lock()
        reads.append(url)
        lock.unlock()
        return metadata
    }

    var readURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func readCount(forPathExtension ext: String) -> Int {
        readURLs.count { $0.pathExtension.lowercased() == ext.lowercased() }
    }
}
