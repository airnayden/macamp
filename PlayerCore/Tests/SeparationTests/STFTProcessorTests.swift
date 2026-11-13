import Accelerate
import Foundation
@testable import Separation
import Testing

/// Round-trip correctness for the offline STFT/iSTFT + overlap-add processor.
///
/// The sample configuration mirrors the karaoke model manifest shape
/// (`nFFT` / `hopLength` / `windowLength`); the real values are injected from
/// `model-manifest.json` at integration time and are never hardcoded in the
/// processor itself.
@Suite("STFTProcessor")
struct STFTProcessorTests {
    private static let sampleRate: Float = 44100

    private struct Partial {
        let frequency: Float
        let amplitude: Float
        let phase: Float
    }

    /// Mel-Band Roformer-style STFT params (power-of-two FFT, 4x overlap).
    private static func sampleConfiguration() throws -> STFTConfiguration {
        try STFTConfiguration(fftSize: 2048, hopLength: 512, windowLength: 2048)
    }

    /// Sum of sinusoids at distinct frequencies, amplitudes and phases — enough
    /// spectral spread to expose any phase incoherence in reconstruction.
    private func multiTone(sampleCount: Int) -> [Float] {
        let partials = [
            Partial(frequency: 110, amplitude: 0.30, phase: 0.0),
            Partial(frequency: 440, amplitude: 0.25, phase: 0.7),
            Partial(frequency: 1000, amplitude: 0.20, phase: 1.9),
            Partial(frequency: 3500, amplitude: 0.15, phase: 2.6),
            Partial(frequency: 8000, amplitude: 0.10, phase: 0.3),
        ]
        var signal = [Float](repeating: 0, count: sampleCount)
        for index in 0 ..< sampleCount {
            let time = Float(index) / Self.sampleRate
            var value: Float = 0
            for partial in partials {
                value += partial.amplitude * sinf(2 * .pi * partial.frequency * time + partial.phase)
            }
            signal[index] = value
        }
        return signal
    }

    private func signalToNoiseRatio(reference: [Float], reconstructed: [Float]) -> Float {
        var signalPower: Float = 0
        var noisePower: Float = 0
        let count = min(reference.count, reconstructed.count)
        for index in 0 ..< count {
            signalPower += reference[index] * reference[index]
            let difference = reference[index] - reconstructed[index]
            noisePower += difference * difference
        }
        guard noisePower > 0 else { return .infinity }
        return 10 * log10f(signalPower / noisePower)
    }

    @Test("10 s multi-tone round-trips with SNR > 60 dB at exactly the input length")
    func multiToneRoundTrip() throws {
        let processor = try STFTProcessor(configuration: Self.sampleConfiguration())
        let sampleCount = Int(Self.sampleRate * 10)
        let signal = multiTone(sampleCount: sampleCount)
        let reconstructed = try processor.inverse(processor.forward(signal))
        #expect(reconstructed.count == sampleCount)
        let snr = signalToNoiseRatio(reference: signal, reconstructed: reconstructed)
        #expect(snr > 60)
    }

    @Test("3 s sub-segment input round-trips with SNR > 60 dB at exact length")
    func subSegmentRoundTrip() throws {
        let processor = try STFTProcessor(configuration: Self.sampleConfiguration())
        let sampleCount = Int(Self.sampleRate * 3)
        let signal = multiTone(sampleCount: sampleCount)
        let reconstructed = try processor.inverse(processor.forward(signal))
        #expect(reconstructed.count == sampleCount)
        let snr = signalToNoiseRatio(reference: signal, reconstructed: reconstructed)
        #expect(snr > 60)
    }

    @Test("signal shorter than one FFT frame round-trips at exact length")
    func shorterThanFrameRoundTrip() throws {
        let processor = try STFTProcessor(configuration: Self.sampleConfiguration())
        let sampleCount = 1000 // < fftSize (2048)
        let signal = multiTone(sampleCount: sampleCount)
        let reconstructed = try processor.inverse(processor.forward(signal))
        #expect(reconstructed.count == sampleCount)
    }

    @Test("hop greater than window throws a typed error")
    func mismatchedHopAndWindowThrows() throws {
        #expect(throws: STFTError.incompatibleHopAndWindow(hop: 4096, window: 2048)) {
            _ = try STFTConfiguration(fftSize: 4096, hopLength: 4096, windowLength: 2048)
        }
    }

    @Test("non-power-of-two FFT size throws a typed error")
    func invalidFFTSizeThrows() throws {
        #expect(throws: STFTError.invalidFFTSize(1000)) {
            _ = try STFTConfiguration(fftSize: 1000, hopLength: 256, windowLength: 1000)
        }
    }

    @Test("window longer than the FFT throws a typed error")
    func invalidWindowLengthThrows() throws {
        #expect(throws: STFTError.invalidWindowLength(4096)) {
            _ = try STFTConfiguration(fftSize: 2048, hopLength: 512, windowLength: 4096)
        }
    }

    @Test("inverse with a mismatched processor configuration throws")
    func inverseConfigurationMismatchThrows() throws {
        let processor = try STFTProcessor(configuration: Self.sampleConfiguration())
        let spectrogram = processor.forward(multiTone(sampleCount: 4096))
        let other = try STFTProcessor(
            configuration: STFTConfiguration(fftSize: 1024, hopLength: 256, windowLength: 1024)
        )
        #expect(throws: STFTError.configurationMismatch) {
            _ = try other.inverse(spectrogram)
        }
    }

    @Test("STFTConfiguration decodes from a model-manifest.json shape")
    func decodesFromManifestShape() throws {
        let json = Data(#"""
        {
          "modelVersion": "melband-roformer-1.0",
          "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
          "sampleRate": 44100,
          "channels": 2,
          "nFFT": 2048,
          "hopLength": 512,
          "windowLength": 2048,
          "segmentSamples": 352800,
          "overlap": 0.5
        }
        """#.utf8)
        let configuration = try JSONDecoder().decode(STFTConfiguration.self, from: json)
        #expect(configuration.fftSize == 2048)
        #expect(configuration.hopLength == 512)
        #expect(configuration.windowLength == 2048)
    }
}
