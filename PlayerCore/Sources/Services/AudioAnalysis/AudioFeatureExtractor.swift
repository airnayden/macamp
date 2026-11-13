// AudioFeatureExtractor — the production ``AudioFeatureExtracting``.
//
// An actor, so the reusable vDSP scratch it owns is isolated and one library-wide
// pass never runs two extractions over the same buffers. The work itself is
// `Task.detached(priority: .utility)`: heavy offline DSP has no business on the
// caller's executor, and utility is the same tier the separation and lyrics
// passes use.
//
// A detached task does NOT inherit cancellation, and `Task.value` is not
// cancellation-aware, so `withTaskCancellationHandler` is what makes a cancelled
// caller actually reach the decode loop — the same construction as
// ``LyricsSweepService``.
//
// This type NEVER touches the live engine, the render callback, or the tap: it
// opens its own decoder and reads the file from scratch, exactly like the
// separation pipeline.
//
// PlayerCore portability: Decoding + Foundation.
import Decoding
import Foundation

/// Extracts tempo, energy and brightness from an audio file, offline.
public actor AudioFeatureExtractor: AudioFeatureExtracting {
    /// RMS of a full-scale (±1.0) sine, `1/√2`. Material at that level maps to an
    /// ``AudioFeatureResult/energy`` of exactly `1.0`; anything louder clamps.
    static let fullScaleRMS = 0.707_106_781_186_547_6

    /// Lower bound of the logarithmic scale ``AudioFeatureResult/brightness`` maps
    /// spectral centroids onto — below it everything reads as `0`.
    static let brightnessFloorHz = 20.0

    /// Upper bound of that scale; a centroid at or above it reads as `1`.
    static let brightnessCeilingHz = 20000.0

    private let decoderProvider: any DecoderProviding

    /// Reusable FFT setup and scratch. Held here so a pass over a 100k-track
    /// library allocates it once rather than once per file, and CHECKED OUT for
    /// the duration of each extraction: the `await` below is an actor suspension
    /// point, so a re-entrant call must build its own rather than share these.
    private var pooledAnalyzer: SpectralWindowAnalyzer?

    public init(decoderProvider: any DecoderProviding) {
        self.decoderProvider = decoderProvider
    }

    public func extractFeatures(from url: URL) async throws -> AudioFeatureResult {
        let analyzer = pooledAnalyzer ?? SpectralWindowAnalyzer()
        pooledAnalyzer = nil
        let pass = AudioFeaturePass(decoderProvider: decoderProvider, analyzer: analyzer)

        let work = Task.detached(priority: .utility) { try await pass.run(url: url) }
        let outcome = await withTaskCancellationHandler {
            await work.result
        } onCancel: {
            work.cancel()
        }

        pooledAnalyzer = analyzer
        return try outcome.get()
    }
}
