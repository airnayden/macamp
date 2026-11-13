import Foundation
import Metadata
import Testing

@Suite("FakeMetadataReaderTests")
struct FakeMetadataReaderTests {
    private let anyURL = URL(fileURLWithPath: "/fixtures/anything.flac")

    @Test("the default fixture models a leading-article artist + embedded art + ReplayGain")
    func defaultFixture() throws {
        let metadata = try FakeMetadataReader().readMetadata(from: anyURL)
        #expect(metadata.title == "Come Together")
        #expect(metadata.artist == "The Beatles")
        #expect(metadata.sortArtist == "beatles")
        #expect(metadata.album == "Abbey Road")
        #expect(metadata.sortAlbum == "abbey road")
        #expect(metadata.albumArtist == "The Beatles")
        #expect(metadata.sortAlbumArtist == "beatles")
        #expect(metadata.year == 1969)
        #expect(metadata.trackNumber == 1)
        #expect(metadata.trackTotal == 17)
        #expect(metadata.hasArtwork)
        #expect(metadata.artwork.first?.type == .frontCover)
        #expect(metadata.lyrics == "Here come old flat top")
        #expect(metadata.replayGain?.trackGain == -7.5)
        #expect(metadata.replayGain?.albumPeak == 0.99)
    }

    @Test("a configured value is returned verbatim")
    func returnsConfigured() throws {
        let custom = TrackMetadata(title: "Respect", artist: "Aretha Franklin")
        let result = try FakeMetadataReader(metadata: custom).readMetadata(from: anyURL)
        #expect(result.title == "Respect")
        #expect(result.artist == "Aretha Franklin")
        #expect(result.sortArtist == "aretha franklin")
    }

    @Test("unsupportedExtensions injects a typed .unsupportedFormat")
    func injectsUnsupported() {
        let reader = FakeMetadataReader(unsupportedExtensions: ["xyz"])
        let error = #expect(throws: MetadataError.self) {
            _ = try reader.readMetadata(from: URL(fileURLWithPath: "/file.xyz"))
        }
        guard case .unsupportedFormat = error else {
            Issue.record("expected .unsupportedFormat, got \(String(describing: error))")
            return
        }
    }

    @Test("corruptExtensions injects a typed .corruptedFile")
    func injectsCorrupt() {
        let reader = FakeMetadataReader(corruptExtensions: ["bad"])
        let error = #expect(throws: MetadataError.self) {
            _ = try reader.readMetadata(from: URL(fileURLWithPath: "/file.bad"))
        }
        guard case .corruptedFile = error else {
            Issue.record("expected .corruptedFile, got \(String(describing: error))")
            return
        }
    }

    @Test("the initialiser NFC-normalises textual values")
    func normalisesOnInit() {
        let decomposed = "Cafe\u{0301} del Mar" // NFD
        let metadata = TrackMetadata(album: decomposed)
        #expect(metadata.album == "Café del Mar".precomposedStringWithCanonicalMapping)
        #expect(metadata.album?.unicodeScalars.contains("\u{0301}") == false)
    }

    @Test("blank textual tags collapse to nil and yield no sort key")
    func blankCollapses() {
        let metadata = TrackMetadata(title: "   ", artist: "")
        #expect(metadata.title == nil)
        #expect(metadata.artist == nil)
        #expect(metadata.sortTitle == nil)
        #expect(metadata.sortArtist == nil)
    }

    @Test("an absent ReplayGain reports isEmpty; a populated one does not")
    func replayGainEmptiness() {
        #expect(ReplayGain().isEmpty)
        #expect(!ReplayGain(trackGain: -5).isEmpty)
    }

    @Test("EmbeddedArtwork carries verbatim bytes and a role")
    func artworkPayload() {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let art = EmbeddedArtwork(data: bytes, mimeType: "image/jpeg", type: .frontCover)
        #expect(art.data == bytes)
        #expect(art.mimeType == "image/jpeg")
        #expect(art.type == .frontCover)
        #expect(art.type.rawValue == 3)
    }
}
