import Foundation
@testable import Lyrics
import Metadata
import Testing

@Suite("EmbeddedLyricsTests")
struct EmbeddedLyricsTests {
    private let trackURL = URL(fileURLWithPath: "/music/song.flac")

    @Test("embedded SYLT-style synced lyrics surface as `.synced` via the Metadata seam")
    func embeddedSyncedViaMetadata() throws {
        let lrc = "[00:01.00]hello\n[00:02.00]world"
        let reader = MetadataEmbeddedLyricsReader(reader: FakeMetadataReader(metadata: TrackMetadata(lyrics: lrc)))

        let embedded = try reader.readEmbeddedLyrics(from: trackURL)
        let unwrapped = try #require(embedded)
        #expect(unwrapped.synced == lrc)
        #expect(unwrapped.unsynced == nil)
    }

    @Test("embedded USLT plain lyrics surface as `.unsynced` via the Metadata seam")
    func embeddedUnsyncedViaMetadata() throws {
        let plain = "just plain words\nno timing"
        let reader = MetadataEmbeddedLyricsReader(reader: FakeMetadataReader(metadata: TrackMetadata(lyrics: plain)))

        let embedded = try reader.readEmbeddedLyrics(from: trackURL)
        let unwrapped = try #require(embedded)
        #expect(unwrapped.unsynced == plain)
        #expect(unwrapped.synced == nil)
    }

    @Test("a file with no embedded lyrics yields nil")
    func noEmbeddedLyrics() throws {
        let reader = MetadataEmbeddedLyricsReader(reader: FakeMetadataReader(metadata: TrackMetadata()))
        #expect(try reader.readEmbeddedLyrics(from: trackURL) == nil)
    }
}
