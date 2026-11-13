// Coverage for the CoreML separator actor: the chunk → predict → subtract path
// (driven by the deterministic FakeSpectrogramPredictor + the committed sample
// manifest) and every unified-unavailable discovery outcome. No `.mlmodelc` is
// needed — availability is proven through injected URLs and a swapped-in predictor.
import Foundation
import PlayerCoreTestSupport
@testable import Separation
import Testing

@Suite("CoreMLSeparator")
struct CoreMLSeparatorTests {
    // MARK: Chunked prediction + complex subtraction

    @Test("chunked predict yields input-length output and attenuates the configured band")
    func chunkedPredictAttenuatesBand() async throws {
        let manifestData = try Data(contentsOf: Self.sampleManifestURL())
        let manifest = try JSONDecoder().decode(SeparationManifest.self, from: manifestData)
        let spec = try manifest.modelSpec()
        let band = 10 ..< 20
        // frameCount (900) exceeds the manifest's segmentFrames (352800/441 = 800),
        // so separation runs across two overlapping segments — exercising the
        // overlap-add reassembly, not just a single window.
        let channel = Self.makeMixture(frameCount: 900, binCount: 64, band: band, configuration: spec.configuration)
        let mixture = StereoSpectrogramSegment(left: channel, right: channel)
        let separator = CoreMLSeparator(predictor: FakeSpectrogramPredictor(band: band), spec: spec)

        #expect(await separator.availability.isAvailable)
        let instrumental = try await separator.separate(mixture: mixture)

        for (before, after) in [(mixture.left, instrumental.vocalLeft), (mixture.right, instrumental.vocalRight)] {
            // Same shape as the input (so downstream iSTFT trims to exact length).
            #expect(after.frameCount == before.frameCount)
            #expect(after.binCount == before.binCount)
            #expect(after.real.count == before.real.count)
            #expect(after.imag.count == before.imag.count)

            // The vocal band is subtracted out; everything else is untouched.
            let bandBefore = Self.energy(before, bins: band)
            let bandAfter = Self.energy(after, bins: band)
            #expect(bandBefore > 0)
            #expect(bandAfter < bandBefore * 1e-6)

            let restBefore = Self.energy(before, bins: 20 ..< 64)
            let restAfter = Self.energy(after, bins: 20 ..< 64)
            #expect(restBefore > 0)
            #expect(abs(restAfter - restBefore) < restBefore * 1e-4)
        }
    }

    // MARK: Unified unavailable path

    @Test("no model in the injected bundle ⇒ unavailable and separate throws modelUnavailable")
    func missingModelIsUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let separator = CoreMLSeparator(
            modelURL: root.appending(component: "MelBandRoformer.mlmodelc"),
            manifestURL: root.appending(component: "model-manifest.json")
        )

        #expect(await separator.availability == .unavailable(reason: .modelNotBundled))

        let configuration = try STFTConfiguration(fftSize: 2048, hopLength: 441, windowLength: 2048)
        let channel = Self.makeMixture(frameCount: 4, binCount: 5, band: 0 ..< 1, configuration: configuration)
        await #expect(throws: SeparationError.modelUnavailable) {
            _ = try await separator.separate(mixture: StereoSpectrogramSegment(left: channel, right: channel))
        }
    }

    @Test("manifest with invalid STFT params ⇒ unavailable(incompatibleModel)")
    func incompatibleStftIsUnavailable() async throws {
        let directory = try Self.makeTempDirectory()
        try Data().write(to: directory.appending(component: "MelBandRoformer.mlmodelc"))
        let manifestURL = directory.appending(component: "model-manifest.json")
        try Self.invalidStftManifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        let separator = CoreMLSeparator(
            modelURL: directory.appending(component: "MelBandRoformer.mlmodelc"),
            manifestURL: manifestURL
        )
        #expect(await separator.availability == .unavailable(reason: .incompatibleModel))
    }

    @Test("corrupt manifest ⇒ unavailable(modelLoadFailed)")
    func corruptManifestIsUnavailable() async throws {
        let directory = try Self.makeTempDirectory()
        try Data().write(to: directory.appending(component: "MelBandRoformer.mlmodelc"))
        let manifestURL = directory.appending(component: "model-manifest.json")
        try "{ not valid json".write(to: manifestURL, atomically: true, encoding: .utf8)

        let separator = CoreMLSeparator(
            modelURL: directory.appending(component: "MelBandRoformer.mlmodelc"),
            manifestURL: manifestURL
        )
        #expect(await separator.availability == .unavailable(reason: .modelLoadFailed))
    }

    // MARK: Fixtures

    /// Repo-root `SeparationTests/Fixtures/model-manifest.sample.json`, located
    /// relative to this test file (four directories up: SeparationTests → Tests →
    /// PlayerCore → repo root).
    private static func sampleManifestURL() -> URL {
        var directory = URL(filePath: #filePath)
        for _ in 0 ..< 4 {
            directory.deleteLastPathComponent()
        }
        return directory.appending(path: "SeparationTests/Fixtures/model-manifest.sample.json")
    }

    private static func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A well-formed manifest whose STFT parameters are invalid (non-power-of-two
    /// FFT), so `STFTConfiguration` rejects them and availability must resolve to
    /// `.incompatibleModel`.
    private static let invalidStftManifest = #"""
    {
      "channels": 2,
      "hopLength": 441,
      "modelVersion": "test-model@invalid-stft",
      "nFFT": 1000,
      "overlap": 0.5,
      "sampleRate": 44100,
      "segmentSamples": 352800,
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "windowLength": 1000
    }
    """#

    /// A synthetic mixture whose `band` bins carry twice the amplitude of the rest,
    /// so a band-keeping vocal estimate leaves a cleanly measurable attenuation.
    private static func makeMixture(
        frameCount: Int,
        binCount: Int,
        band: Range<Int>,
        configuration: STFTConfiguration
    ) -> ComplexSpectrogram {
        var real = [Float](repeating: 0, count: frameCount * binCount)
        var imag = [Float](repeating: 0, count: frameCount * binCount)
        for frame in 0 ..< frameCount {
            let base = frame * binCount
            for bin in 0 ..< binCount {
                let amplitude: Float = band.contains(bin) ? 1.0 : 0.3
                real[base + bin] = amplitude
                imag[base + bin] = amplitude * 0.5
            }
        }
        return ComplexSpectrogram(
            frameCount: frameCount,
            binCount: binCount,
            real: real,
            imag: imag,
            originalSampleCount: frameCount * configuration.hopLength,
            configuration: configuration
        )
    }

    private static func energy(_ spectrogram: ComplexSpectrogram, bins: Range<Int>) -> Double {
        var total = 0.0
        for frame in 0 ..< spectrogram.frameCount {
            let base = frame * spectrogram.binCount
            for bin in bins {
                let real = Double(spectrogram.real[base + bin])
                let imag = Double(spectrogram.imag[base + bin])
                total += real * real + imag * imag
            }
        }
        return total
    }
}
