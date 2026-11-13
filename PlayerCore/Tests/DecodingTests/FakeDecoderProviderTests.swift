import AVFAudio
import Decoding
import Foundation
import PlayerCoreTestSupport
import Testing

@Suite("FakeDecoderProviderTests")
struct FakeDecoderProviderTests {
    private let anyURL = URL(fileURLWithPath: "/fixtures/anything.fake")

    @Test("the fake produces a sine at the configured frequency and duration")
    func configuredSine() throws {
        let provider = FakeDecoderProvider(frequency: 660, sampleRate: 44100, duration: 0.25)
        let buffer = try provider.makeDecoder(for: anyURL).decodeAll()
        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer.frameLength == AVAudioFrameCount((0.25 * 44100).rounded()))
        let peak = Analysis.peakBin(buffer: buffer)
        #expect(abs(peak.frequency - 660) < 11)
    }

    @Test("two fakes with identical configuration produce identical samples")
    func deterministicAcrossInstances() throws {
        let first = try FakeDecoderProvider().makeDecoder(for: anyURL).decodeAll()
        let second = try FakeDecoderProvider().makeDecoder(for: anyURL).decodeAll()
        #expect(first.frameLength == second.frameLength)

        let lhs = try #require(first.floatChannelData)
        let rhs = try #require(second.floatChannelData)
        for frame in stride(from: 0, to: Int(first.frameLength), by: 137) {
            #expect(lhs[0][frame] == rhs[0][frame])
        }
    }

    @Test("multi-channel output writes the tone to every channel")
    func multiChannel() throws {
        let provider = FakeDecoderProvider(channelCount: 2, duration: 0.1)
        let buffer = try provider.makeDecoder(for: anyURL).decodeAll()
        #expect(buffer.format.channelCount == 2)
        let data = try #require(buffer.floatChannelData)
        #expect(data[0][100] == data[1][100])
    }

    @Test("unsupportedExtensions injects a typed .unsupportedFormat")
    func injectsUnsupported() {
        let provider = FakeDecoderProvider(unsupportedExtensions: ["xyz"])
        let error = #expect(throws: DecodingError.self) {
            _ = try provider.makeDecoder(for: URL(fileURLWithPath: "/file.xyz"))
        }
        guard case .unsupportedFormat = error else {
            Issue.record("expected .unsupportedFormat, got \(String(describing: error))")
            return
        }
    }

    @Test("corruptExtensions injects a typed .corruptedFile")
    func injectsCorrupt() {
        let provider = FakeDecoderProvider(corruptExtensions: ["bad"])
        let error = #expect(throws: DecodingError.self) {
            _ = try provider.makeDecoder(for: URL(fileURLWithPath: "/file.bad"))
        }
        guard case .corruptedFile = error else {
            Issue.record("expected .corruptedFile, got \(String(describing: error))")
            return
        }
    }

    @Test("seek is exact: re-decoding after seeking reproduces the original samples")
    func seekIsExact() throws {
        let decoder = try FakeDecoderProvider(duration: 0.1).makeDecoder(for: anyURL)
        #expect(decoder.supportsSeeking)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 512))

        _ = try decoder.decode(into: buffer, frameLength: 512)
        let firstSample = try #require(buffer.floatChannelData)[0][0]

        let sought = try decoder.seek(toFrame: 0)
        #expect(sought == 0)
        _ = try decoder.decode(into: buffer, frameLength: 512)
        let resampled = try #require(buffer.floatChannelData)[0][0]
        #expect(firstSample == resampled)
    }

    @Test("decode returns 0 at end-of-stream")
    func endOfStream() throws {
        let decoder = try FakeDecoderProvider(duration: 0.01).makeDecoder(for: anyURL)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096))
        var total = 0
        while true {
            let produced = try decoder.decode(into: buffer, frameLength: 4096)
            if produced == 0 { break }
            total += Int(produced)
        }
        #expect(total == Int(decoder.frameLength))
    }
}
