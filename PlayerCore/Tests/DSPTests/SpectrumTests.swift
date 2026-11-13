import AVFAudio
@testable import DSP
import PlayerCoreTestSupport
import Testing

private enum SpectrumTestError: Error {
    case missingFormat
    case missingChannelData
}

private func renderMono(
    sampleRate: Double = 44100,
    _ makeNode: (AVAudioEngine) -> AVAudioNode
) throws -> [Float] {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
        throw SpectrumTestError.missingFormat
    }
    let buffer = try OfflineRenderHarness.render(format: format, duration: 1.0, buildGraph: makeNode)
    guard let channel = buffer.floatChannelData else {
        throw SpectrumTestError.missingChannelData
    }
    let frameCount = min(4096, Int(buffer.frameLength))
    var out = [Float](repeating: 0, count: 4096)
    for index in 0 ..< frameCount {
        out[index] = channel[0][index]
    }
    return out
}

private func spectrum(of samples: [Float], using analyzer: SpectrumAnalyzer) -> [Float] {
    var bands = [Float](repeating: 0, count: 128)
    samples.withUnsafeBufferPointer { buffer in
        if let base = buffer.baseAddress {
            analyzer.analyze(base, into: &bands)
        }
    }
    return bands
}

@Suite("Spectrum analyzer")
struct SpectrumTests {
    @Test("1 kHz sine peaks in the expected log band")
    func sinePeaksAtExpectedBand() throws {
        let analyzer = SpectrumAnalyzer()
        let samples = try renderMono { engine in
            let source = SignalGenerators.sine(frequency: 1000, sampleRate: 44100)
            engine.attach(source)
            return source
        }
        let bands = spectrum(of: samples, using: analyzer)
        let argmax = bands.indices.max(by: { bands[$0] < bands[$1] }) ?? -1
        let expected = analyzer.bandIndex(forBin: 93)
        #expect(abs(argmax - expected) <= 1, "argmax band \(argmax) vs expected \(expected)")
    }

    @Test("Silence yields a flat zero spectrum")
    func silenceIsFlat() throws {
        let analyzer = SpectrumAnalyzer()
        let samples = try renderMono { engine in
            let source = SignalGenerators.silence(sampleRate: 44100)
            engine.attach(source)
            return source
        }
        let bands = spectrum(of: samples, using: analyzer)
        #expect(bands.allSatisfy { $0 <= 0.001 }, "max band \(bands.max() ?? 0)")
    }

    @Test("White noise is broadband")
    func whiteNoiseIsBroadband() throws {
        let analyzer = SpectrumAnalyzer()
        let samples = try renderMono { engine in
            let source = SignalGenerators.whiteNoise(sampleRate: 44100, amplitude: 0.5)
            engine.attach(source)
            return source
        }
        let bands = spectrum(of: samples, using: analyzer)
        let loud = bands.count(where: { $0 > 0.05 })
        let mean = bands.reduce(0, +) / Float(bands.count)
        #expect(loud >= 100, "loud bands \(loud)")
        #expect(mean > 0.2, "mean band \(mean)")
    }
}
