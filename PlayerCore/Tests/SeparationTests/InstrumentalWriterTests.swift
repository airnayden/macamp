// InstrumentalWriterTests — the atomic 24-bit ALAC encoder.
//
// The round-trip is proven through the REAL production decoder (`SFBDecoderProvider`),
// so these tests exercise the exact FLAC/ALAC codec path the pipeline reads back
// with. ALAC is a lossless INTEGER codec at a fixed 24-bit source depth, hence the
// two precision tiers:
//   (a) samples already on the 24-bit grid survive byte-exact (max abs diff == 0);
//   (b) arbitrary float samples are bounded by ≤ 1 LSB (1.5 × 2⁻²³).
// A simulated write failure must leave NO partial file at the final path (atomic
// publish), and ENOSPC must surface as `.diskFull`.
import AudioToolbox
import AVFAudio
import Decoding
import Foundation
@testable import Separation
import Testing

@Suite("InstrumentalWriter")
struct InstrumentalWriterTests {
    /// One ALSB (unit in the last place) at 24-bit, the grid ALAC quantises onto.
    private static let lsb24: Float = 1.0 / Float(1 << 23)
    /// A whole number of 4096-frame ALAC packets, so no partial-packet padding can
    /// perturb the round-trip frame count.
    private static let frameCount: AVAudioFrameCount = 4096 * 12
    /// One second of audio at 44.1 kHz — the quality-tier round-trip fixture size.
    private static let oneSecondFrames: AVAudioFrameCount = 44100

    // MARK: - (a) 24-bit-exact input round-trips byte-exact

    /// A float32 signal whose samples are EXACTLY representable at 24-bit round-trips
    /// through `SFBDecoderProvider` with identical frame count and max abs diff == 0.
    @Test("24-bit-exact PCM round-trips with zero error and identical frame count")
    func exactRoundTripIsLossless() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("exact.m4a")
        let source = try Self.makeStereoSine(frameCount: Self.frameCount, quantizeTo24Bit: true)

        try InstrumentalWriter().write(source, to: destination)

        try Self.expectIs24BitALAC(destination)
        let decoded = try SFBDecoderProvider().makeDecoder(for: destination).decodeAll()
        #expect(decoded.frameLength == source.frameLength)
        #expect(Self.maxAbsDiff(source, decoded) == 0)
    }

    // MARK: - (b) arbitrary float input round-trips within 1 LSB

    /// An arbitrary float32 sine round-trips within ≤ 1 LSB at 24-bit — ALAC is an
    /// integer codec, so float→int quantisation is bounded, not zero.
    @Test("arbitrary float PCM round-trips within 1.5 × 2⁻²³")
    func arbitraryRoundTripIsWithinOneLSB() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("arbitrary.m4a")
        let source = try Self.makeStereoSine(frameCount: Self.frameCount, quantizeTo24Bit: false)

        try InstrumentalWriter().write(source, to: destination)

        let decoded = try SFBDecoderProvider().makeDecoder(for: destination).decodeAll()
        #expect(decoded.frameLength == source.frameLength)
        #expect(Self.maxAbsDiff(source, decoded) <= 1.5 * Self.lsb24)
    }

    // MARK: - (c) failed write leaves nothing at the final path

    /// A write into a non-existent parent directory fails, and the atomic contract
    /// guarantees NO partial file is left at the final path.
    @Test("a failed write leaves no partial file at the destination")
    func failedWriteLeavesNoPartialFile() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Parent subdirectory deliberately absent ⇒ the temp encode cannot be created.
        let destination = directory
            .appendingPathComponent("absent", isDirectory: true)
            .appendingPathComponent("instrumental.m4a")
        let source = try Self.makeStereoSine(frameCount: 4096, quantizeTo24Bit: true)

        #expect(throws: SeparationError.encodeFailed) {
            try InstrumentalWriter().write(source, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        // No stray temp sibling either.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(siblings.isEmpty)
    }

    /// Publishing over an existing file replaces it atomically (the cache overwrites
    /// a stale instrumental in place).
    @Test("publishing over an existing file replaces it")
    func publishReplacesExistingFile() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("reused.m4a")
        try Data("stale".utf8).write(to: destination)
        let source = try Self.makeStereoSine(frameCount: 4096, quantizeTo24Bit: true)

        try InstrumentalWriter().write(source, to: destination)

        let decoded = try SFBDecoderProvider().makeDecoder(for: destination).decodeAll()
        #expect(decoded.frameLength == source.frameLength)
    }

    // MARK: - Error mapping (ENOSPC → diskFull)

    /// A POSIX `ENOSPC` — the out-of-disk-space errno — maps to `.diskFull`.
    @Test("POSIX ENOSPC maps to diskFull")
    func posixOutOfSpaceMapsToDiskFull() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        #expect(InstrumentalWriter.mapWriteError(error) == .diskFull)
    }

    /// A Cocoa `fileWriteOutOfSpace`, including when nested as an underlying error,
    /// maps to `.diskFull`.
    @Test("Cocoa out-of-space (even nested) maps to diskFull")
    func cocoaOutOfSpaceMapsToDiskFull() {
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteOutOfSpace.rawValue)
        #expect(InstrumentalWriter.mapWriteError(cocoa) == .diskFull)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: cocoa])
        #expect(InstrumentalWriter.mapWriteError(wrapped) == .diskFull)
    }

    /// Any other failure maps to `.encodeFailed`, not `.diskFull`.
    @Test("a generic write failure maps to encodeFailed")
    func genericFailureMapsToEncodeFailed() {
        let error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue)
        #expect(InstrumentalWriter.mapWriteError(error) == .encodeFailed)
    }

    // MARK: - Quality tiers (settings dict)

    /// `.lossless` selects 24-bit Apple Lossless — both bit-depth keys present, no
    /// AAC bit-rate key.
    @Test("lossless settings are 24-bit Apple Lossless")
    func losslessSettingsAreALAC() {
        let settings = InstrumentalWriter.settings(for: .lossless)
        #expect(settings[AVFormatIDKey] as? AudioFormatID == kAudioFormatAppleLossless)
        #expect(settings[AVSampleRateKey] as? Double == InstrumentalWriter.sampleRate)
        #expect(settings[AVNumberOfChannelsKey] as? Int == Int(InstrumentalWriter.channelCount))
        #expect(settings[AVEncoderBitDepthHintKey] as? Int == InstrumentalWriter.bitDepth)
        #expect(settings[AVLinearPCMBitDepthKey] as? Int == InstrumentalWriter.bitDepth)
        #expect(settings[AVEncoderBitRateKey] == nil)
    }

    /// `.standard` selects 256 kbps AAC — the bit-rate key is present and neither
    /// bit-depth key is (AAC is not an integer codec).
    @Test("standard settings are 256 kbps AAC with no bit-depth keys")
    func standardSettingsAreAAC() {
        let settings = InstrumentalWriter.settings(for: .standard)
        #expect(settings[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC)
        #expect(settings[AVSampleRateKey] as? Double == InstrumentalWriter.sampleRate)
        #expect(settings[AVNumberOfChannelsKey] as? Int == Int(InstrumentalWriter.channelCount))
        #expect(settings[AVEncoderBitRateKey] as? Int == InstrumentalWriter.standardBitRate)
        #expect(settings[AVEncoderBitDepthHintKey] == nil)
        #expect(settings[AVLinearPCMBitDepthKey] == nil)
    }

    // MARK: - Quality tiers (round-trip)

    /// `.standard` writes a decodable AAC `.m4a`: the container reports
    /// `kAudioFormatMPEG4AAC`, the file is non-empty, and it decodes to non-zero
    /// frames. AAC is lossy/VBR with encoder priming, so neither the byte size nor
    /// the exact frame count is asserted — only the format and non-emptiness.
    @Test("standard quality writes a decodable AAC .m4a")
    func standardQualityWritesDecodableAAC() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("standard.m4a")
        let source = try Self.makeStereoSine(frameCount: Self.oneSecondFrames, quantizeTo24Bit: false)

        try InstrumentalWriter().write(source, to: destination, quality: .standard)

        try Self.expectFormatID(destination, kAudioFormatMPEG4AAC)
        #expect(try Self.fileSize(destination) > 0)
        let decoded = try SFBDecoderProvider().makeDecoder(for: destination).decodeAll()
        #expect(decoded.frameLength > 0)
    }

    /// `.lossless` (explicit) writes byte-exact 24-bit ALAC — identical to the
    /// default path, proving the `.lossless` default parameter behaves as spelled out.
    @Test("lossless quality writes byte-exact 24-bit ALAC")
    func losslessQualityWritesALAC() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("lossless.m4a")
        let source = try Self.makeStereoSine(frameCount: Self.oneSecondFrames, quantizeTo24Bit: true)

        try InstrumentalWriter().write(source, to: destination, quality: .lossless)

        try Self.expectIs24BitALAC(destination)
        let decoded = try SFBDecoderProvider().makeDecoder(for: destination).decodeAll()
        #expect(decoded.frameLength == source.frameLength)
        #expect(Self.maxAbsDiff(source, decoded) == 0)
    }

    /// A `.standard` write into a non-existent parent directory fails atomically:
    /// `.encodeFailed`, nothing at the destination, and no stray temp sibling.
    @Test("a failed standard-quality write leaves no partial file")
    func failedStandardWriteLeavesNoPartialFile() throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory
            .appendingPathComponent("absent", isDirectory: true)
            .appendingPathComponent("instrumental.m4a")
        let source = try Self.makeStereoSine(frameCount: 4096, quantizeTo24Bit: false)

        #expect(throws: SeparationError.encodeFailed) {
            try InstrumentalWriter().write(source, to: destination, quality: .standard)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(siblings.isEmpty)
    }

    // MARK: - Fixtures

    /// A deinterleaved float32 stereo sine in the writer's exact processing format.
    /// When `quantizeTo24Bit` is true each sample is snapped to the 24-bit integer
    /// grid (`round(x·2²³)/2²³`), making it byte-exact-representable in ALAC.
    private static func makeStereoSine(
        frameCount: AVAudioFrameCount,
        quantizeTo24Bit: Bool
    ) throws -> AVAudioPCMBuffer {
        let format = try #require(InstrumentalWriter.processingFormat)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        let data = try #require(buffer.floatChannelData)
        let scale = Float(1 << 23)
        let channelCount = Int(format.channelCount)
        for channel in 0 ..< channelCount {
            let frequency = 440.0 * Double(channel + 1) // distinct tone per channel
            let increment = 2 * Double.pi * frequency / Self.sampleRateValue
            var phase = 0.0
            for frame in 0 ..< Int(frameCount) {
                let raw = Float(sin(phase)) * 0.9
                data[channel][frame] = quantizeTo24Bit ? (raw * scale).rounded() / scale : raw
                phase += increment
                if phase >= 2 * Double.pi { phase -= 2 * Double.pi }
            }
        }
        buffer.frameLength = frameCount
        return buffer
    }

    private static let sampleRateValue = InstrumentalWriter.sampleRate

    /// The largest absolute per-sample difference across all channels/frames.
    private static func maxAbsDiff(_ lhs: AVAudioPCMBuffer, _ rhs: AVAudioPCMBuffer) -> Float {
        guard let lhsData = lhs.floatChannelData, let rhsData = rhs.floatChannelData else { return .infinity }
        let frames = min(Int(lhs.frameLength), Int(rhs.frameLength))
        let channels = min(Int(lhs.format.channelCount), Int(rhs.format.channelCount))
        var maxDiff: Float = 0
        for channel in 0 ..< channels {
            for frame in 0 ..< frames {
                maxDiff = max(maxDiff, abs(lhsData[channel][frame] - rhsData[channel][frame]))
            }
        }
        return maxDiff
    }

    /// Asserts the file on disk is genuinely 24-bit Apple Lossless (not 16/32-bit),
    /// reading the container's stream description directly.
    private static func expectIs24BitALAC(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let asbd = file.fileFormat.streamDescription.pointee
        #expect(asbd.mFormatID == kAudioFormatAppleLossless)
        #expect(asbd.mFormatFlags == kAppleLosslessFormatFlag_24BitSourceData)
    }

    /// Asserts the file on disk reports the expected container format ID.
    private static func expectFormatID(_ url: URL, _ formatID: AudioFormatID) throws {
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.streamDescription.pointee.mFormatID == formatID)
    }

    /// The on-disk byte size of `url`.
    private static func fileSize(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
    }

    private static func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstrumentalWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
