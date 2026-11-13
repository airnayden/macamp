// SpectralWindowAnalyzer — the per-window vDSP math behind the feature pass.
//
// One Hann-windowed real FFT per hop yields two descriptors:
//
//   * a MULTI-BAND onset value (spectral flux, relative per band) that
//     ``TempoEstimator`` autocorrelates into a BPM, and
//   * the window's spectral centroid in Hz, which averages into "brightness".
//
// Every scratch buffer is allocated once in `init` and reused, mirroring
// `DSP.SpectrumAnalyzer` — the difference is only the transform size (1024 here
// vs 4096 there) and that this one runs offline, not off a render tap.
//
// PlayerCore portability: Accelerate + Foundation only.
import Accelerate
import Foundation

/// Fixed-size spectral analysis of one mono window, with reusable vDSP scratch.
///
/// `@unchecked Sendable` mirrors `SpectrumAnalyzer`: the pointers are owned
/// exclusively by one instance, and ``AudioFeatureExtractor`` checks an instance
/// out for the duration of a single pass, so two passes never share one.
final class SpectralWindowAnalyzer: @unchecked Sendable {
    /// Analysis window in samples. At 44.1 kHz this is 23.2 ms — a 43 Hz bin
    /// resolution, fine enough to place a spectral centroid, short enough that a
    /// percussive onset does not smear across several hops.
    static let windowSize = 1024

    /// Hop between consecutive windows (50 % overlap). At 44.1 kHz this makes the
    /// onset envelope an 86.13 Hz signal — the frame rate ``TempoEstimator``
    /// converts autocorrelation lags back into BPM with.
    static let hopSize = 512

    /// Logarithmically spaced bands the onset flux is averaged over. Four is
    /// enough to stop a loud bass line from masking a hi-hat pattern without
    /// making any single band too sparse to be meaningful.
    static let bandCount = 4

    /// Magnitude sums below this are treated as "no energy here" — it keeps
    /// digital silence at exactly zero flux instead of amplifying float noise
    /// through the per-band ratio.
    private static let energyEpsilon: Float = 1e-6

    private let halfN = SpectralWindowAnalyzer.windowSize / 2
    private let log2n = vDSP_Length(10)

    private let fftSetup: FFTSetup
    private let window: [Float]
    private let bandEdges: [Int]
    private let realp: UnsafeMutablePointer<Float>
    private let imagp: UnsafeMutablePointer<Float>
    private let magnitude: UnsafeMutablePointer<Float>
    private let previous: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private var hasPreviousWindow = false

    init() {
        let size = SpectralWindowAnalyzer.windowSize
        let bins = size / 2
        guard let setup = vDSP_create_fftsetup(vDSP_Length(10), FFTRadix(kFFTRadix2)) else {
            fatalError("SpectralWindowAnalyzer: failed to create FFT setup")
        }
        fftSetup = setup

        var hann = [Float](repeating: 0, count: size)
        vDSP_hann_window(&hann, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        window = hann

        // Same logarithmic edge formula as SpectrumAnalyzer, at 4 bands instead
        // of 128. Edge 0 is bin 1, so DC never contributes.
        let bands = SpectralWindowAnalyzer.bandCount
        bandEdges = (0 ... bands).map { index in
            max(1, Int(pow(Double(bins), Double(index) / Double(bands)).rounded()))
        }

        realp = .allocate(capacity: bins)
        imagp = .allocate(capacity: bins)
        magnitude = .allocate(capacity: bins)
        previous = .allocate(capacity: bins)
        windowed = .allocate(capacity: size)
        realp.initialize(repeating: 0, count: bins)
        imagp.initialize(repeating: 0, count: bins)
        magnitude.initialize(repeating: 0, count: bins)
        previous.initialize(repeating: 0, count: bins)
        windowed.initialize(repeating: 0, count: size)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        realp.deallocate()
        imagp.deallocate()
        magnitude.deallocate()
        previous.deallocate()
        windowed.deallocate()
    }

    /// Forgets the previous window, so the next ``analyze(_:sampleRate:)`` starts a
    /// fresh pass with no flux carried over from the last track.
    func reset() {
        previous.update(repeating: 0, count: halfN)
        hasPreviousWindow = false
    }

    /// Analyzes one ``windowSize``-sample mono window.
    ///
    /// - Parameters:
    ///   - samples: Exactly ``windowSize`` mono float samples.
    ///   - sampleRate: The stream's sample rate, used to turn bins into Hz.
    /// - Returns: The window's multi-band onset flux (`0` for the first window of
    ///   a pass, which has no predecessor to differ from) and its spectral
    ///   centroid in Hz — `nil` when the window carries no measurable energy.
    func analyze(_ samples: UnsafePointer<Float>, sampleRate: Double) -> (flux: Float, centroidHz: Double?) {
        computeMagnitude(samples)
        let flux = hasPreviousWindow ? multiBandFlux() : 0
        let centroid = spectralCentroid(sampleRate: sampleRate)
        previous.update(from: magnitude, count: halfN)
        hasPreviousWindow = true
        return (flux, centroid)
    }

    // MARK: Private

    private func computeMagnitude(_ samples: UnsafePointer<Float>) {
        let size = SpectralWindowAnalyzer.windowSize
        vDSP_vmul(samples, 1, window, 1, windowed, 1, vDSP_Length(size))
        var split = DSPSplitComplex(realp: realp, imagp: imagp)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { interleaved in
            vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(halfN))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvabs(&split, 1, magnitude, 1, vDSP_Length(halfN))
    }

    /// Mean over the log-spaced bands of each band's positive spectral flux
    /// RELATIVE to that band's own magnitude, so a bass onset and a cymbal onset
    /// contribute equally regardless of their absolute levels. A steady tone has
    /// no rise from window to window and therefore scores ~0.
    private func multiBandFlux() -> Float {
        var total: Float = 0
        for band in 0 ..< SpectralWindowAnalyzer.bandCount {
            let low = min(bandEdges[band], halfN - 1)
            let high = min(max(low + 1, bandEdges[band + 1]), halfN)
            var rise: Float = 0
            var reference: Float = 0
            for bin in low ..< high {
                rise += max(0, magnitude[bin] - previous[bin])
                reference += magnitude[bin] + previous[bin]
            }
            if reference > Self.energyEpsilon {
                total += rise / (0.5 * reference)
            }
        }
        return total / Float(SpectralWindowAnalyzer.bandCount)
    }

    /// Magnitude-weighted mean bin frequency in Hz — the classic "brightness"
    /// descriptor. Bin 0 is skipped: `vDSP_fft_zrip` packs the Nyquist term into
    /// its imaginary slot, so its magnitude is not a real DC reading.
    private func spectralCentroid(sampleRate: Double) -> Double? {
        var weighted = 0.0
        var total = 0.0
        for bin in 1 ..< halfN {
            let value = Double(magnitude[bin])
            weighted += value * Double(bin)
            total += value
        }
        guard total > Double(Self.energyEpsilon) else { return nil }
        let binWidth = sampleRate / Double(SpectralWindowAnalyzer.windowSize)
        return (weighted / total) * binWidth
    }
}
