// GATED integration coverage for real separation quality. It runs ONLY where a
// compiled `MelBandRoformer.mlmodelc` and the `voice_over_music.m4a` fixture both
// exist next to this suite's fixtures; absent either (CI, fresh clones, iOS, App
// Store builds, and this development environment), `.enabled(if:)` reports the test
// as SKIPPED — never failed. The fixture is produced by the checked-in
// `Fixtures/generate-voice-over-music.sh` on a machine that has the model; see the
// karaoke ADR for the calibrated dB threshold.
import AVFAudio
import Decoding
import Foundation
@testable import Separation
import Testing

@Suite("SeparationPipeline quality (gated)")
struct SeparationQualityTests {
    @Test(
        "instrumental band reductions match the calibrated PyTorch ground truth ranges",
        .enabled(if: QualityFixture.isAvailable)
    )
    func vocalBandIsAttenuated() async throws {
        let manifest = try QualityFixture.manifest()
        let spec = try manifest.modelSpec()
        let separator = CoreMLSeparator(modelURL: QualityFixture.modelURL, manifestURL: QualityFixture.manifestURL)
        guard await separator.availability.isAvailable else { return }

        let cacheDirectory = try QualityFixture.makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let pipeline = try SeparationPipeline(
            decoderProvider: SFBDecoderProvider(),
            separator: separator,
            cache: InstrumentalCache(directory: cacheDirectory),
            spec: spec,
            scratchDirectory: cacheDirectory.appendingPathComponent("scratch")
        )

        let original = QualityFixture.voiceOverURL
        let instrumental = try await pipeline.separate(url: original)

        // CALIBRATED 2026-07-16 against the authoritative PyTorch complex-path model
        // on this exact fixture (see the karaoke ADR): vocal band 12.07 dB, low end
        // 34.52 dB — the model genuinely strips the SYNTHETIC sine-chord bed's low
        // end too (sustained sines read as vocal-like; the plan's blind "< 2 dB bed
        // change" predates any real run). RANGES pin both numbers so a marshalling
        // regression in either direction fails loudly: mixture-passthrough ⇒ ~0 dB
        // (below both floors); silence ⇒ huge dB (above both ceilings).
        let voiceReduction = try QualityFixture.reductionDB(original, instrumental, band: BandHz(low: 300, high: 3000))
        let lowEndReduction = try QualityFixture.reductionDB(original, instrumental, band: BandHz(low: 20, high: 150))
        #expect(voiceReduction >= 6.0 && voiceReduction <= 25.0)
        #expect(lowEndReduction >= 20.0 && lowEndReduction <= 45.0)
    }
}

// MARK: - Fixtures + measurement

private struct BandHz {
    let low: Double
    let high: Double
}

private enum QualityFixture {
    static var fixturesDirectory: URL {
        var directory = URL(filePath: #filePath)
        for _ in 0 ..< 4 {
            directory.deleteLastPathComponent()
        }
        return directory.appending(path: "SeparationTests/Fixtures")
    }

    static var modelURL: URL {
        fixturesDirectory.appending(path: "MelBandRoformer.mlmodelc")
    }

    static var manifestURL: URL {
        fixturesDirectory.appending(path: "model-manifest.sample.json")
    }

    static var voiceOverURL: URL {
        fixturesDirectory.appending(path: "voice_over_music.m4a")
    }

    static var isAvailable: Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: modelURL.path) && manager.fileExists(atPath: voiceOverURL.path)
    }

    static func manifest() throws -> SeparationManifest {
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode(SeparationManifest.self, from: data)
    }

    static func makeCacheDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("separation-quality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func reductionDB(_ original: URL, _ instrumental: URL, band: BandHz) throws -> Double {
        let originalEnergy = try bandEnergy(of: original, band: band)
        let instrumentalEnergy = try bandEnergy(of: instrumental, band: band)
        guard originalEnergy > 0, instrumentalEnergy > 0 else { return 0 }
        return 10.0 * log10(originalEnergy / instrumentalEnergy)
    }

    static func bandEnergy(of url: URL, band: BandHz) throws -> Double {
        let samples = try monoSamples(of: url)
        let configuration = try STFTConfiguration(fftSize: 2048, hopLength: 441, windowLength: 2048)
        let spectrogram = STFTProcessor(configuration: configuration).forward(samples)
        let lowBin = max(0, Int(band.low / 44100.0 * 2048.0))
        let highBin = min(spectrogram.binCount - 1, Int(band.high / 44100.0 * 2048.0))
        guard lowBin <= highBin else { return 0 }
        var total = 0.0
        for frame in 0 ..< spectrogram.frameCount {
            let base = frame * spectrogram.binCount
            for bin in lowBin ... highBin {
                let real = Double(spectrogram.real[base + bin])
                let imag = Double(spectrogram.imag[base + bin])
                total += real * real + imag * imag
            }
        }
        return total
    }

    static func monoSamples(of url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            return []
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for frame in 0 ..< frames {
            var sum: Float = 0
            for channel in 0 ..< channels {
                sum += data[channel][frame]
            }
            mono[frame] = sum / Float(max(channels, 1))
        }
        return mono
    }
}
