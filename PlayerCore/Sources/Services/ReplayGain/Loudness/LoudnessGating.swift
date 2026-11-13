//
//  LoudnessGating.swift
//  MacAMP PlayerCore — Services
//
//  The pure BS.1770-4 summation and gating math, with no signal and no state:
//  the channel weights Gᵢ, the block-loudness formula, the two gate
//  thresholds, and the mean-power pooling that turns a set of block loudnesses
//  into one integrated figure.
//
//  Pooling is exposed as a free function on purpose. ``LoudnessAnalyzer`` calls
//  it over ONE track's blocks; album gain calls the very same function over the
//  concatenated blocks of every track on the album. One implementation, so the
//  two can never disagree.
//
//  This file imports only Foundation; it MUST NOT import AppKit or UIKit
//  (PlayerCore portability invariant).
//

import Foundation

// MARK: - LoudnessGating

/// Thresholds, the loudness formula, and gated mean-power pooling.
public enum LoudnessGating {
    /// The absolute gate, Γa (LKFS). Blocks at or below it are discarded
    /// outright — they are silence or near-silence, not programme material.
    public static let absoluteThresholdLKFS = -70.0

    /// The relative gate offset (LU) below the ungated mean, giving Γr.
    public static let relativeGateOffsetLU = -10.0

    /// The `−0.691` calibration term in `L = −0.691 + 10·log10(Σ Gᵢzᵢ)`. It
    /// exactly cancels the K-weighting's +0.691 dB gain at 997 Hz, which is why
    /// a −23 dBFS 997 Hz sine reads −23.0 LUFS.
    public static let calibrationOffsetDB = -0.691

    /// `L = −0.691 + 10·log10(Σ Gᵢzᵢ)` for one block's weighted mean square.
    ///
    /// - Returns: `-.infinity` for a digitally silent block, which then fails
    ///   every gate rather than producing a NaN.
    public static func loudness(ofWeightedMeanSquare weighted: Double) -> Double {
        guard weighted > 0 else { return -.infinity }
        return calibrationOffsetDB + 10.0 * log10(weighted)
    }

    /// The inverse of ``loudness(ofWeightedMeanSquare:)`` — recovers `Σ Gᵢzᵢ`
    /// from a block loudness so a set can be averaged in the linear domain.
    public static func weightedMeanSquare(ofLoudness loudness: Double) -> Double {
        guard loudness.isFinite else { return 0 }
        return pow(10.0, (loudness - calibrationOffsetDB) / 10.0)
    }

    /// Mean **power** (not mean dB) of a block set, back in LKFS.
    ///
    /// - Returns: `nil` for an empty set or one carrying no energy at all.
    public static func meanLoudness(of blocks: [Double]) -> Double? {
        guard !blocks.isEmpty else { return nil }
        var total = 0.0
        for block in blocks {
            total += weightedMeanSquare(ofLoudness: block)
        }
        let mean = total / Double(blocks.count)
        guard mean > 0 else { return nil }
        return loudness(ofWeightedMeanSquare: mean)
    }

    /// Integrated loudness (BS.1770-4 §5) over blocks that have ALREADY cleared
    /// the absolute gate.
    ///
    /// Applies the second, relative gate here and nowhere else: the ungated
    /// mean of `blocks` sets Γr, and only blocks above Γr are pooled. Callers
    /// must NOT pre-apply the relative gate to `blocks` — doing so would
    /// re-derive Γr from an already-trimmed set and bias the answer upward,
    /// which is exactly the trap album pooling walks into.
    ///
    /// - Returns: `nil` when `blocks` is empty, i.e. nothing cleared the
    ///   absolute gate.
    public static func integratedLoudness(ofAbsoluteGatedBlocks blocks: [Double]) -> Double? {
        guard let ungatedMean = meanLoudness(of: blocks) else { return nil }
        let relativeThreshold = ungatedMean + relativeGateOffsetLU
        return meanLoudness(of: blocks.filter { $0 > relativeThreshold })
    }
}

// MARK: - LoudnessChannelWeights

/// The per-channel weights Gᵢ of BS.1770-4 Table 3.
public enum LoudnessChannelWeights {
    /// Weight for a surround channel (Ls / Rs).
    public static let surround = 1.41

    /// Weight for the LFE channel — excluded from the measurement entirely.
    public static let lowFrequencyEffects = 0.0

    /// Weights for a channel count, in the standard interleave order
    /// (`L, R, C, LFE, Ls, Rs`).
    ///
    /// BS.1770-4 defines weights only up to 5.1. Mono is measured as a single
    /// unweighted channel, and any channel beyond the sixth is given weight 1.0
    /// rather than dropped — an unrecognised extra channel still carries
    /// programme material, and silently discarding it would read low.
    public static func weights(forChannelCount count: Int) -> [Double] {
        switch count {
        case ..<1: []
        case 1: [1.0]
        case 2: [1.0, 1.0]
        case 3: [1.0, 1.0, 1.0]
        case 4: [1.0, 1.0, surround, surround]
        case 5: [1.0, 1.0, 1.0, surround, surround]
        default: surroundBase + Array(repeating: 1.0, count: count - surroundBase.count)
        }
    }

    /// The 5.1 layout — the widest one BS.1770-4 actually specifies.
    private static let surroundBase = [1.0, 1.0, 1.0, lowFrequencyEffects, surround, surround]
}
