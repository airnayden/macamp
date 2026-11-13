// SpectralCutoffEstimator — estimates where a stream's spectral content stops, by
// averaging many short-time magnitude spectra into one long-term picture.
//
// Built on ``SpectrumAnalyzer``'s primitives: the same 4096-point Hann window and
// the same `vDSP_fft_zrip` real FFT, reached through `powerSpectrum(_:into:)` so
// this gets BIN resolution instead of the visualizer's 128 log bands. It is
// DELIBERATELY not built on `Separation`'s `STFTProcessor`: that exists to
// reconstruct audio (it must keep phase and invert perfectly), which is a much
// heavier contract than a magnitude average needs.
//
// OFFLINE analysis, never audio-thread code — it allocates and sorts.
//
// PlayerCore portability: Accelerate + Foundation.
import Accelerate
import Foundation

/// Accumulates windowed magnitude spectra and estimates the frequency above which
/// a stream carries no meaningful content.
///
/// Feed the whole stream through ``append(_:)-(UnsafeBufferPointer<Float>)`` in
/// bounded blocks, then call ``finish()``. Memory is constant in stream length: the
/// estimator keeps one 4096-sample staging window and one 2048-bin accumulator, no
/// matter how long the input runs.
public final class SpectralCutoffEstimator {
    /// Real samples per analysis window (``SpectrumAnalyzer``'s transform size).
    public static let fftSize = SpectrumAnalyzer.fftSize

    /// 50% overlap (Welch averaging) — enough windows from a short file without
    /// paying for a hop that re-reads most of the previous window.
    public static let hopSize = SpectrumAnalyzer.fftSize / 2

    /// Below this many averaged windows the spectrum is too noisy to read an edge
    /// off, and the estimator declines rather than guessing.
    public static let minimumWindowCount = 8

    /// How far above the measured dead-band floor a bin must sit to count as
    /// content. 25 dB is many times the ±3 dB bin-to-bin scatter that survives
    /// averaging, so floor noise can never be mistaken for signal.
    public static let noiseFloorMarginDB = 25.0

    /// Ceiling on the threshold, relative to the reference band.
    ///
    /// This is what stops a FLAT spectrum producing a phantom cutoff. In a true
    /// wideband recording the dead-band probe lands ON signal, so
    /// `floor + margin` would sit ABOVE every bin and no bin would qualify. Capping
    /// the threshold 50 dB below the reference band means a spectrum with no dead
    /// band always resolves its cutoff at Nyquist, which is the honest answer.
    public static let maximumReferenceDropDB = 50.0

    /// The band whose median anchors every relative level. Chosen to sit below any
    /// plausible lossy cutoff while still carrying content in real material.
    public static let referenceBandLowHz = 1000.0
    public static let referenceBandHighHz = 5000.0

    /// Fewer reference bins than this and the median is not worth trusting.
    public static let minimumReferenceBinCount = 16

    /// Overall RMS below which the stream is treated as silence. Guards the
    /// reference-band division as well as the verdict.
    public static let silenceGateRMS = 1e-5

    /// Fraction of the top of the spectrum used to probe for a dead band.
    public static let noiseFloorProbeFraction = 0.02

    public let sampleRate: Double

    private let analyzer = SpectrumAnalyzer()
    private var binPower = [Float](repeating: 0, count: SpectrumAnalyzer.binCount)
    private var powerSum = [Double](repeating: 0, count: SpectrumAnalyzer.binCount)
    private var pending = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var pendingCount = 0
    private var windowCount = 0
    private var squareSum = 0.0
    private var sampleCount = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    // MARK: - Accumulation

    public func append(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        var energy: Float = 0
        vDSP_svesq(base, 1, &energy, vDSP_Length(samples.count))
        squareSum += Double(energy)
        sampleCount += samples.count

        var offset = 0
        while offset < samples.count {
            offset += stage(base + offset, available: samples.count - offset)
            if pendingCount == Self.fftSize {
                consumeStagedWindow()
            }
        }
    }

    public func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    // MARK: - Estimation

    public func finish() -> SpectralCutoffOutcome {
        guard sampleCount > 0 else { return .indeterminate(.insufficientAudio) }
        guard (squareSum / Double(sampleCount)).squareRoot() >= Self.silenceGateRMS else {
            return .indeterminate(.silentOrTooQuiet)
        }
        guard windowCount >= Self.minimumWindowCount else {
            return .indeterminate(.insufficientAudio)
        }
        guard let referenceBins = referenceBandBins() else {
            return .indeterminate(.unusableSampleRate)
        }
        return .estimated(estimate(referenceBins: referenceBins))
    }

    // MARK: - Private

    private func stage(_ source: UnsafePointer<Float>, available: Int) -> Int {
        let taken = min(Self.fftSize - pendingCount, available)
        pending.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            (base + pendingCount).update(from: source, count: taken)
        }
        pendingCount += taken
        return taken
    }

    private func consumeStagedWindow() {
        pending.withUnsafeBufferPointer { window in
            guard let windowBase = window.baseAddress else { return }
            binPower.withUnsafeMutableBufferPointer { bins in
                guard let binBase = bins.baseAddress else { return }
                analyzer.powerSpectrum(windowBase, into: binBase)
            }
        }
        for bin in 0 ..< SpectrumAnalyzer.binCount {
            powerSum[bin] += Double(binPower[bin])
        }
        windowCount += 1
        slideStagingWindow()
    }

    /// Drops the oldest hop and keeps the tail for the next window. `hopSize` is
    /// exactly half of `fftSize`, so source and destination never overlap.
    private func slideStagingWindow() {
        let carried = Self.fftSize - Self.hopSize
        pending.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            base.update(from: base + Self.hopSize, count: carried)
        }
        pendingCount = carried
    }

    private var binWidthHz: Double {
        sampleRate / Double(Self.fftSize)
    }

    private func referenceBandBins() -> Range<Int>? {
        guard binWidthHz > 0 else { return nil }
        let low = max(1, Int(Self.referenceBandLowHz / binWidthHz))
        let high = min(SpectrumAnalyzer.binCount, Int(Self.referenceBandHighHz / binWidthHz))
        guard high - low >= Self.minimumReferenceBinCount else { return nil }
        return low ..< high
    }

    private func estimate(referenceBins: Range<Int>) -> SpectralCutoffEstimate {
        let averaged = powerSum.map { $0 / Double(windowCount) }
        let reference = max(median(of: averaged[referenceBins]), .leastNormalMagnitude)
        let decibels = averaged.map { 10 * log10(max($0, .leastNormalMagnitude) / reference) }

        let probeStart = Int(Double(SpectrumAnalyzer.binCount) * (1 - Self.noiseFloorProbeFraction))
        let noiseFloorDB = median(of: decibels[probeStart...])
        let thresholdDB = min(noiseFloorDB + Self.noiseFloorMarginDB, -Self.maximumReferenceDropDB)
        let cutoffBin = (1 ..< SpectrumAnalyzer.binCount).reversed()
            .first { decibels[$0] >= thresholdDB } ?? 0

        return SpectralCutoffEstimate(
            cutoffHz: Double(cutoffBin) * binWidthHz,
            nyquistHz: sampleRate / 2,
            noiseFloorDB: noiseFloorDB,
            thresholdDB: thresholdDB,
            windowCount: windowCount
        )
    }

    private func median(of values: ArraySlice<Double>) -> Double {
        let ordered = values.sorted()
        guard !ordered.isEmpty else { return 0 }
        return ordered[ordered.count / 2]
    }
}
