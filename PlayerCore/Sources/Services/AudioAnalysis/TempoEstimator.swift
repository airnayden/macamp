// TempoEstimator — onset envelope in, BPM (or an honest `nil`) out.
//
// The envelope is the multi-band spectral flux ``SpectralWindowAnalyzer`` emits,
// one value per hop. Autocorrelating it over the lags that correspond to
// 60…200 BPM finds the period at which onsets repeat; the winning lag is refined
// to sub-frame precision and converted back to BPM.
//
// Pure value math with no reusable state, so it is a caseless enum rather than a
// class: the envelope is short (~86 values per second) and only ~60 lags are
// searched, so a `vDSP_dotprD` sweep costs microseconds even for an hour-long
// file.
//
// KNOWN BOUND — a SUSTAINED PURE TONE gets a tempo it does not deserve. A single
// unbroken sine's spectral leakage shifts with its phase relative to each window,
// producing a small but genuinely PERIODIC flux ripple, and the confidence gate
// is scale-invariant so it cannot tell that ripple from quiet beats. Aperiodic
// broadband material (white noise) is correctly rejected, and real music never
// holds one unbroken sine for minutes, so this is characterised rather than
// gated: any absolute flux floor that would suppress it is uncalibrated against
// real recordings and would silently drop tempo from quiet real tracks.
//
// PlayerCore portability: Accelerate + Foundation only.
import Accelerate
import Foundation

/// Autocorrelation tempo estimation over an onset-strength envelope.
enum TempoEstimator {
    /// Slowest tempo the detector will report.
    static let minimumBPM = 60.0

    /// Fastest tempo the detector will report.
    static let maximumBPM = 200.0

    /// Confidence gate: the winning lag's correlation, as a fraction of the
    /// envelope's own variance (its zero-lag correlation), must reach this.
    /// Read it as "the beat period explains at least 20 % of the envelope" —
    /// below that the envelope has no periodic structure and the estimate is
    /// reported as `nil` rather than as a confident wrong number.
    static let minimumConfidence = 0.20

    /// A periodic onset train correlates almost as strongly at 2× and 3× its
    /// period as at the period itself, so taking the raw maximum reports half- or
    /// third-tempo roughly as often as the real one. Any local peak within this
    /// fraction of the strongest one wins if it sits at a SHORTER lag.
    static let octaveTolerance = 0.85

    /// Estimates tempo from an onset-strength envelope.
    ///
    /// - Parameters:
    ///   - envelope: Onset strength, one value per analysis hop.
    ///   - frameRate: Envelope frames per second (`sampleRate / hopSize`).
    /// - Returns: Tempo in BPM within ``minimumBPM``…``maximumBPM``, or `nil`
    ///   when the confidence gate rejects the estimate.
    static func estimateBPM(envelope: [Float], frameRate: Double) -> Double? {
        guard frameRate > 0 else { return nil }
        let shortestLag = Int((60.0 / maximumBPM * frameRate).rounded())
        let longestLag = Int((60.0 / minimumBPM * frameRate).rounded())
        // Two full slow-tempo periods is the shortest envelope worth correlating.
        guard shortestLag >= 1, longestLag > shortestLag, envelope.count > longestLag * 2 else {
            return nil
        }

        let centred = meanRemoved(envelope)
        let variance = centred.reduce(0) { $0 + $1 * $1 } / Double(centred.count)
        guard variance > 0 else { return nil }

        let correlations = autocorrelation(centred, from: shortestLag, through: longestLag)
        guard let peak = correlations.max(), peak > 0, peak / variance >= minimumConfidence else {
            return nil
        }

        let index = fundamentalIndex(in: correlations, peak: peak)
        let lag = refinedLag(in: correlations, at: index, offset: shortestLag)
        guard lag > 0 else { return nil }
        return 60.0 * frameRate / lag
    }

    // MARK: Private

    private static func meanRemoved(_ envelope: [Float]) -> [Double] {
        let mean = envelope.reduce(0.0) { $0 + Double($1) } / Double(envelope.count)
        return envelope.map { Double($0) - mean }
    }

    /// Correlation at each lag, normalized by the number of overlapping terms so
    /// long lags are not penalised for having fewer of them.
    private static func autocorrelation(_ values: [Double], from shortest: Int, through longest: Int) -> [Double] {
        var result = [Double](repeating: 0, count: longest - shortest + 1)
        let count = values.count
        values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for lag in shortest ... longest {
                var sum = 0.0
                vDSP_dotprD(base, 1, base + lag, 1, &sum, vDSP_Length(count - lag))
                result[lag - shortest] = sum / Double(count - lag)
            }
        }
        return result
    }

    /// The shortest LOCAL peak that reaches ``octaveTolerance`` of the strongest
    /// one — the fundamental beat period rather than one of its multiples.
    /// Requiring a local maximum (not merely a high value) keeps the shoulder of
    /// the real peak from being mistaken for a faster tempo.
    private static func fundamentalIndex(in correlations: [Double], peak: Double) -> Int {
        let threshold = peak * octaveTolerance
        let last = correlations.count - 1
        for index in correlations.indices where correlations[index] >= threshold {
            let risesFromLeft = index == 0 || correlations[index] >= correlations[index - 1]
            let fallsToRight = index == last || correlations[index] >= correlations[index + 1]
            if risesFromLeft, fallsToRight { return index }
        }
        return correlations.firstIndex(of: peak) ?? 0
    }

    /// Sub-frame peak position from a parabola through the winning lag and its
    /// two neighbours. One envelope frame is ~2.8 BPM at 120 BPM, so integer lags
    /// alone would quantize the answer far too coarsely.
    private static func refinedLag(in correlations: [Double], at index: Int, offset: Int) -> Double {
        let lag = Double(offset + index)
        guard index > 0, index < correlations.count - 1 else { return lag }
        let left = correlations[index - 1]
        let centre = correlations[index]
        let right = correlations[index + 1]
        let curvature = left - 2 * centre + right
        guard curvature < 0 else { return lag }
        let delta = 0.5 * (left - right) / curvature
        return lag + min(max(delta, -0.5), 0.5)
    }
}
