// Frame-clamped CUE segment decoding (todo 31) through the real
// `SFBDecoderProvider`, which is where `AudioRegionDecoder`'s refusal-not-clamping
// behaviour has to be absorbed.
//
// The fixture is SYNTHESISED at run time rather than committed: the assertions need
// thirty seconds of audio whose every sample is a closed-form function of its
// absolute index, and a 5 MB binary in the repo would prove nothing a generator
// cannot. It is float32 CAF, so the round-trip is lossless and the middle slice can
// be compared to the whole file's own samples exactly.
@testable import AudioEngine
import AVFAudio
import Foundation
import Testing

@Suite(.serialized)
struct CueSegmentDecodingTests {
    private static let sampleRate: Double = 44100
    private static let totalSeconds: Double = 30
    private static let toneHertz: Double = 440
    private static let toneAmplitude: Float = 0.5

    private static var totalFrames: AVAudioFramePosition {
        AVAudioFramePosition(sampleRate * totalSeconds)
    }

    private static func frames(seconds: Double) -> AVAudioFramePosition {
        AVAudioFramePosition(sampleRate * seconds)
    }

    @Test("a [10 s, 20 s) segment reports 10 s and decodes exactly the middle content")
    func segmentReportsClampedDurationAndExactMiddleContent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = SFBDecoderProvider()
        let whole = try Self.decodeAll(provider.makeDecoder(for: fixture.url))
        let start = Self.frames(seconds: 10)
        let end = Self.frames(seconds: 20)

        let segment = try provider.makeDecoder(for: DecoderSource(url: fixture.url, frameRange: start ..< end))
        let seconds = Double(segment.frameLength) / segment.processingFormat.sampleRate
        let decoded = try Self.decodeAll(segment)

        #expect(abs(seconds - 10) < 0.05)
        #expect(decoded.count == Int(end - start))
        let reference = Array(whole[Int(start) ..< Int(end)])
        #expect(Self.maximumDifference(decoded, reference) < 1e-6)
        // A pair of all-zero buffers would satisfy the comparison above.
        #expect(Self.peak(reference) > 0.4)
    }

    @Test("an endFrame past the end of the file clamps to the end of the file instead of throwing")
    func endFrameBeyondEndOfFileClampsToEndOfFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = SFBDecoderProvider()
        let length = try AVAudioFramePosition(Self.decodeAll(provider.makeDecoder(for: fixture.url)).count)
        let start = Self.frames(seconds: 10)

        let segment = try provider.makeDecoder(
            for: DecoderSource(url: fixture.url, frameRange: start ..< Self.frames(seconds: 40))
        )

        #expect(segment.frameLength == length - start)
        #expect(try Self.decodeAll(segment).count == Int(length - start))
    }

    @Test("an open-ended segment decodes to the end of the file")
    func openEndedSegmentDecodesToEndOfFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = SFBDecoderProvider()
        let start = Self.frames(seconds: 10)

        let segment = try provider.makeDecoder(
            for: DecoderSource(url: fixture.url, frameRange: start ..< AVAudioFramePosition.max)
        )

        #expect(segment.frameLength == Self.totalFrames - start)
    }

    @Test("a whole-file source still reports the whole stream")
    func wholeFileSourceReportsTheWholeStream() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let decoder = try SFBDecoderProvider().makeDecoder(for: DecoderSource(url: fixture.url))

        #expect(decoder.frameLength == Self.totalFrames)
    }

    @Test("a segment's position is region-relative, which is what lets a seek clamp to its own bounds")
    func segmentPositionIsRegionRelative() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let start = Self.frames(seconds: 10)
        let segment = try SFBDecoderProvider().makeDecoder(
            for: DecoderSource(url: fixture.url, frameRange: start ..< Self.frames(seconds: 20))
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: segment.processingFormat, frameCapacity: 4410) else {
            Issue.record("could not allocate a decode buffer")
            return
        }

        let produced = try segment.decode(into: buffer, frameLength: 4410)

        #expect(produced == 4410)
        #expect(segment.framePosition == 4410)
    }
}

// MARK: - Fixture + analysis

private extension CueSegmentDecodingTests {
    /// A 30-second float32 CAF whose sample at absolute frame `n` is
    /// `amplitude · sin(2π · 440 · n / 44100)`, so any slice of it is verifiable
    /// without a second decode.
    struct Fixture {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cue-segment-\(UUID().uuidString).caf")
            guard
                let format = AVAudioFormat(
                    standardFormatWithSampleRate: CueSegmentDecodingTests.sampleRate,
                    channels: 1
                )
            else {
                throw FixtureError.unconstructibleFormat
            }
            let file = try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let chunk: AVAudioFrameCount = 44100
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                throw FixtureError.unconstructibleBuffer
            }
            var written: AVAudioFramePosition = 0
            let total = CueSegmentDecodingTests.totalFrames
            while written < total {
                let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), total - written))
                buffer.frameLength = count
                guard let channel = buffer.floatChannelData?[0] else {
                    throw FixtureError.unconstructibleBuffer
                }
                for index in 0 ..< Int(count) {
                    channel[index] = CueSegmentDecodingTests.sample(at: written + AVAudioFramePosition(index))
                }
                try file.write(from: buffer)
                written += AVAudioFramePosition(count)
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    enum FixtureError: Error {
        case unconstructibleFormat
        case unconstructibleBuffer
    }

    static func sample(at frame: AVAudioFramePosition) -> Float {
        toneAmplitude * Float(sin(2 * Double.pi * toneHertz * Double(frame) / sampleRate))
    }

    static func decodeAll(_ decoder: any PCMDecoding) throws -> [Float] {
        let capacity: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: capacity) else {
            return []
        }
        var samples: [Float] = []
        while true {
            let produced = try decoder.decode(into: buffer, frameLength: capacity)
            guard produced > 0, let channel = buffer.floatChannelData?[0] else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(produced)))
        }
        return samples
    }

    static func maximumDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return .infinity }
        return zip(lhs, rhs).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
    }

    static func peak(_ samples: [Float]) -> Float {
        samples.reduce(Float(0)) { max($0, abs($1)) }
    }
}
