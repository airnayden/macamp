import Foundation
import Metadata
import Testing

@Suite("SFBMetadataReaderTests")
struct SFBMetadataReaderTests {
    private func read(_ url: URL) throws -> TrackMetadata {
        try SFBMetadataReader().readMetadata(from: url)
    }

    // MARK: - Full extraction

    @Test("FLAC: full tags are NFC values with article-stripped sort keys")
    func flacTags() throws {
        let meta = try read(TestFixtures.flac)
        #expect(meta.title == "Come Together")
        #expect(meta.artist == "The Beatles")
        #expect(meta.album == "Abbey Road")
        #expect(meta.albumArtist == "The Beatles")
        #expect(meta.genre == "Rock")
        #expect(meta.composer == "Lennon-McCartney")
        #expect(meta.year == 1969)
        #expect(meta.trackNumber == 1)
        #expect(meta.discNumber == 1)
        #expect(meta.sortTitle == "come together")
        #expect(meta.sortArtist == "beatles")
        #expect(meta.sortAlbum == "abbey road")
        #expect(meta.sortAlbumArtist == "beatles")
        #expect(meta.lyrics == "Here come old flat top")
    }

    @Test("FLAC: stream properties (sample rate, channels, 16-bit depth, duration)")
    func flacProperties() throws {
        let meta = try read(TestFixtures.flac)
        #expect(meta.sampleRate == 44100)
        #expect(meta.channelCount == 2)
        #expect(meta.bitDepth == 16)
        let duration = try #require(meta.duration)
        #expect(abs(duration - 0.5) < 0.05)
        let bitrate = try #require(meta.bitrate)
        #expect(bitrate > 0)
    }

    // MARK: - Embedded artwork

    @Test("FLAC / MP3 / M4A all carry an extractable embedded PNG cover", arguments: [
        "full.flac", "full.mp3", "full.m4a",
    ])
    func embeddedArtwork(name: String) throws {
        let meta = try read(TestFixtures.url(name))
        #expect(meta.hasArtwork, "no artwork extracted from \(name)")
        let art = try #require(meta.artwork.first)
        #expect(!art.data.isEmpty)
        #expect(art.mimeType == "image/png")
    }

    // MARK: - ReplayGain

    @Test("FLAC: ReplayGain track/album gain, peak and reference loudness")
    func flacReplayGain() throws {
        let meta = try read(TestFixtures.flac)
        let gain = try #require(meta.replayGain)
        let trackGain = try #require(gain.trackGain)
        #expect(abs(trackGain + 7.5) < 0.01)
        let trackPeak = try #require(gain.trackPeak)
        #expect(abs(trackPeak - 0.988553) < 0.0001)
        let albumGain = try #require(gain.albumGain)
        #expect(abs(albumGain + 8.2) < 0.01)
        let albumPeak = try #require(gain.albumPeak)
        #expect(abs(albumPeak - 0.997162) < 0.0001)
        let reference = try #require(gain.referenceLoudness)
        #expect(abs(reference - 89.0) < 0.01)
    }

    @Test("MP3: tags, embedded art and ReplayGain all extracted")
    func mp3Metadata() throws {
        let meta = try read(TestFixtures.mp3)
        #expect(meta.artist == "The Beatles")
        #expect(meta.sortArtist == "beatles")
        #expect(meta.album == "Abbey Road")
        #expect(meta.year == 1969)
        #expect(meta.hasArtwork)
        #expect(meta.replayGain?.trackGain != nil)
    }

    @Test("M4A: tags and embedded art extracted")
    func m4aMetadata() throws {
        let meta = try read(TestFixtures.m4a)
        #expect(meta.title == "Come Together")
        #expect(meta.artist == "The Beatles")
        #expect(meta.sortArtist == "beatles")
        #expect(meta.hasArtwork)
    }

    // MARK: - Typed errors (never a crash)

    @Test("corrupt.flac yields a typed error, never a crash")
    func corruptThrowsTyped() {
        let error = #expect(throws: MetadataError.self) {
            _ = try SFBMetadataReader().readMetadata(from: TestFixtures.corruptFlac)
        }
        switch error {
        case .corruptedFile, .unsupportedFormat:
            break
        case .ioError, .none:
            Issue.record("expected a bad-data MetadataError, got \(String(describing: error))")
        }
    }

    @Test("a missing file throws .ioError")
    func missingThrowsIO() {
        let error = #expect(throws: MetadataError.self) {
            _ = try SFBMetadataReader().readMetadata(from: TestFixtures.url("does-not-exist.flac"))
        }
        guard case .ioError = error else {
            Issue.record("expected .ioError, got \(String(describing: error))")
            return
        }
    }

    @Test("an unsupported file type throws a typed error rather than crashing")
    func unsupportedThrows() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-\(UUID().uuidString).xyz")
        try Data("definitely not audio".utf8).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        #expect(throws: MetadataError.self) {
            _ = try SFBMetadataReader().readMetadata(from: temporary)
        }
    }

    @Test("supported path extensions advertise the common formats")
    func advertisesFormats() {
        let extensions = SFBMetadataReader.supportedPathExtensions
        for expected in ["flac", "mp3", "m4a"] {
            #expect(extensions.contains(expected), "missing extension \(expected)")
        }
    }

    // MARK: - DSD reader coverage

    @Test("DSF: the reader registers .dsf and returns real stream properties")
    func dsfIsCovered() throws {
        #expect(SFBMetadataReader.supportedPathExtensions.contains("dsf"))
        #expect(SFBMetadataReader.supportedPathExtensions.contains("dff"))

        let meta = try read(DSDFixtures.dsf)

        #expect(meta.sampleRate == 2_822_400)
        #expect(meta.channelCount == 2)
        #expect(meta.bitDepth == 1)
        let duration = try #require(meta.duration)
        #expect(abs(duration - 0.5) < 0.05)
    }

    @Test("DFF and DSDIFF: both spellings read, so the scanner never drops one as failed")
    func dsdContainerSpellingsAreCovered() throws {
        // SFB registers `dff` only; `dsdiff` resolves through content sniffing.
        #expect(!SFBMetadataReader.supportedPathExtensions.contains("dsdiff"))

        for spelling in ["dff", "dsdiff"] {
            let copy = try DSDFixtures.copy(of: DSDFixtures.dsf, pathExtension: spelling)
            defer { try? FileManager.default.removeItem(at: copy) }

            let meta = try read(copy)

            #expect(meta.sampleRate == 2_822_400, "\(spelling) lost its stream properties")
            #expect(meta.channelCount == 2, "\(spelling) lost its channel count")
        }
    }
}

/// Locates the DSD fixtures committed next to the Decoding suite.
///
/// DSD is the one format whose metadata coverage had to be *proven* rather than
/// assumed (todo 25), and the fixture already exists one target over — so this
/// reads the SAME `tone.dsf` instead of committing a second 350 KB copy.
private enum DSDFixtures {
    static var dsf: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DecodingTests/Fixtures/tone.dsf")
    }

    static func copy(of source: URL, pathExtension: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsd-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
