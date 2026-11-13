import AVFAudio
import Decoding
import Foundation
import PlayerCoreTestSupport
import Testing

@Suite("SFBDecoderProviderTests")
struct SFBDecoderProviderTests {
    private func decodeAll(_ url: URL) throws -> AVAudioPCMBuffer {
        try SFBDecoderProvider().makeDecoder(for: url).decodeAll()
    }

    @Test("WAV decodes to a non-silent 440 Hz float-PCM tone")
    func wavDecodes() throws {
        let buffer = try decodeAll(TestFixtures.wav)
        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer.frameLength == 22050)
        #expect(Analysis.peak(buffer: buffer) > 0.5)
        let peak = Analysis.peakBin(buffer: buffer)
        #expect(abs(peak.frequency - 440) < 11)
    }

    @Test("FLAC decodes to a non-silent 440 Hz tone (guards the int->float silence regression)")
    func flacDecodes() throws {
        let decoder = try SFBDecoderProvider().makeDecoder(for: TestFixtures.flac)
        // FLAC's native processingFormat is packed integer, not float.
        #expect(decoder.processingFormat.commonFormat != .pcmFormatFloat32)
        let buffer = try decoder.decodeAll()
        #expect(buffer.frameLength == 22050)
        // Peak would be 0 if the native-int -> float32 normalisation regressed.
        #expect(Analysis.peak(buffer: buffer) > 0.5)
        let peak = Analysis.peakBin(buffer: buffer)
        #expect(abs(peak.frequency - 440) < 11)
    }

    @Test("MP3 decodes to a non-silent 440 Hz tone")
    func mp3Decodes() throws {
        let buffer = try decodeAll(TestFixtures.mp3)
        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer.frameLength > 20000)
        #expect(Analysis.peak(buffer: buffer) > 0.4)
        let peak = Analysis.peakBin(buffer: buffer)
        #expect(abs(peak.frequency - 440) < 11)
    }

    @Test("DSD is decimated to non-silent float PCM at ~1 kHz, never staying DSD")
    func dsdDecodesToPCM() throws {
        let decoder = try SFBDecoderProvider().makeDecoder(for: TestFixtures.dsf)
        let format = decoder.processingFormat
        // DSD64 source is 2.8224 MHz; the decoder must hand back decimated PCM.
        #expect(format.sampleRate < 400_000)
        #expect(format.sampleRate > 40000)

        let buffer = try decoder.decodeAll()
        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer.frameLength > 0)
        let peak = Analysis.peak(buffer: buffer)
        #expect(peak > 0.2)
        #expect(peak <= 1.0)
        let bin = Analysis.peakBin(buffer: buffer, fftSize: 16384)
        #expect(abs(bin.frequency - 1000) < 40)
    }

    @Test("corrupt.flac yields a typed bad-data DecodingError, never a crash")
    func corruptThrowsTypedError() {
        let error = #expect(throws: DecodingError.self) {
            _ = try SFBDecoderProvider().makeDecoder(for: TestFixtures.corruptFlac)
        }
        switch error {
        case .corruptedFile, .truncated, .unsupportedFormat:
            break
        case .ioError, .unsupportedSampleRate, .none:
            Issue.record("expected a bad-data DecodingError, got \(String(describing: error))")
        }
    }

    @Test("a missing file throws .ioError")
    func missingFileThrowsIO() {
        let error = #expect(throws: DecodingError.self) {
            _ = try SFBDecoderProvider().makeDecoder(for: TestFixtures.url("does-not-exist.flac"))
        }
        guard case .ioError = error else {
            Issue.record("expected .ioError, got \(String(describing: error))")
            return
        }
    }

    @Test("a zero-byte file throws .truncated")
    func zeroByteThrowsTruncated() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).flac")
        #expect(FileManager.default.createFile(atPath: temporary.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: temporary) }

        let error = #expect(throws: DecodingError.self) {
            _ = try SFBDecoderProvider().makeDecoder(for: temporary)
        }
        guard case .truncated = error else {
            Issue.record("expected .truncated, got \(String(describing: error))")
            return
        }
    }

    @Test("an unsupported file type throws a typed error rather than crashing")
    func unsupportedThrows() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("note-\(UUID().uuidString).xyz")
        try Data("definitely not audio".utf8).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        #expect(throws: DecodingError.self) {
            _ = try SFBDecoderProvider().makeDecoder(for: temporary)
        }
    }

    @Test("supported path extensions and MIME types advertise the common formats")
    func advertisesFormats() {
        let extensions = SFBDecoderProvider.supportedPathExtensions
        for expected in ["flac", "mp3", "wav", "aiff", "dsf", "m4a", "ogg", "opus", "wv", "ape", "mpc"] {
            #expect(extensions.contains(expected), "missing extension \(expected)")
        }
        let mimeTypes = SFBDecoderProvider.supportedMIMETypes
        #expect(mimeTypes.contains("audio/flac"))
        #expect(!mimeTypes.isEmpty)
    }

    @Test("every DSD spelling the library scanner walks is advertised and routed")
    func advertisesEveryDSDExtension() {
        for expected in ["dsf", "dff", "dsdiff"] {
            #expect(SFBDecoderProvider.dsdPathExtensions.contains(expected), "missing DSD extension \(expected)")
            #expect(SFBDecoderProvider.supportedPathExtensions.contains(expected), "missing extension \(expected)")
        }
    }

    /// The badge set is restated rather than imported because `Decoding` sits
    /// below `ViewModels` in the module graph. Drift is silent in the worst way:
    /// a DSD spelling present here but absent from `SignalPathModel.dsdCodecs`
    /// still plays, just without its badge.
    @Test("every routed DSD extension is a codec token the signal-path DSD badge recognises")
    func routedDSDExtensionsMatchTheBadgeTokens() {
        let badgeTokens: Set = ["DSD", "DSF", "DFF", "DSDIFF"]

        for routed in SFBDecoderProvider.dsdPathExtensions {
            #expect(badgeTokens.contains(routed.uppercased()), "SignalPathModel.dsdCodecs is missing \(routed)")
        }
    }

    @Test("a .dsdiff file decodes to PCM — SFB registers only .dff, so routing carries the long spelling")
    func dsdiffRoutesToTheDSDDecoder() throws {
        let copy = try DSDFixtureCopy(of: TestFixtures.dsf, pathExtension: "dsdiff")
        defer { copy.remove() }

        let decoder = try SFBDecoderProvider().makeDecoder(for: copy.url)

        #expect(decoder.processingFormat.sampleRate < 400_000)
        let buffer = try decoder.decodeAll()
        #expect(buffer.frameLength > 0)
    }

    @Test("a DSD128 stream is refused by case, never resampled")
    func dsd128ThrowsUnsupportedSampleRate() {
        let error = #expect(throws: DecodingError.self) {
            _ = try SFBDecoderProvider().makeDecoder(for: TestFixtures.dsd128)
        }

        guard case let .unsupportedSampleRate(url, detail) = error else {
            Issue.record("expected .unsupportedSampleRate, got \(String(describing: error))")
            return
        }
        #expect(url == TestFixtures.dsd128)
        #expect(detail == "DSD128 (5644800 Hz)")
    }

    @Test("the DSD128 refusal carries a localized message and an unlocalized diagnostic")
    func dsd128RefusalIsLocalizable() {
        let error = DecodingError.unsupportedSampleRate(url: TestFixtures.dsd128, detail: "DSD128 (5644800 Hz)")

        #expect(String(localized: error.message) == String(localized: DecodingStrings.errorUnsupportedSampleRate))
        // The diagnostic keeps the token verbatim; the user-facing message must not.
        #expect(error.description.contains("DSD128 (5644800 Hz)"))
        #expect(!String(localized: error.message).contains("5644800"))
    }

    @Test("a seekable decoder reports its position and seeks back to the start")
    func seekRepositions() throws {
        let decoder = try SFBDecoderProvider().makeDecoder(for: TestFixtures.wav)
        #expect(decoder.supportsSeeking)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 1024))

        let produced = try decoder.decode(into: buffer, frameLength: 1024)
        #expect(produced == 1024)
        #expect(decoder.framePosition == 1024)

        let sought = try decoder.seek(toFrame: 0)
        #expect(sought == 0)
        #expect(decoder.framePosition == 0)
    }
}

/// A temp copy of a fixture under a different path extension, so a routing test
/// can drive an extension SFB resolves by content sniffing without committing a
/// second binary that only differs in its name.
private struct DSDFixtureCopy {
    let url: URL

    init(of source: URL, pathExtension: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsd-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        try FileManager.default.copyItem(at: source, to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
