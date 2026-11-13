//
//  LoudnessScanResult.swift
//  MacAMP PlayerCore — Services
//
//  What one offline BS.1770-4 scan of one file yields, and the ReplayGain 2.0
//  mapping that turns it into the ``ReplayGain`` value the playback path already
//  understands.
//
//  The scan result is deliberately WIDER than ``ReplayGain``: the batch service
//  also needs the absolute-gated block set (to histogram for album pooling) and
//  the raw block count (to tell "no audio" from "audio, all of it below the
//  gate"). ``replayGain`` is the narrowing, applied at the seam where a caller
//  only wants the two numbers the calculator consumes.
//
//  This file imports only Foundation + Metadata; it MUST NOT import AppKit or
//  UIKit (PlayerCore portability invariant).
//

import Foundation
import Metadata

// MARK: - ReplayGainSynthesis

/// The ReplayGain 2.0 reference level and the gain it implies for a measurement.
public enum ReplayGainSynthesis {
    /// The ReplayGain 2.0 reference loudness, in LUFS.
    ///
    /// RG 2.0 replaced RG 1.0's psychoacoustic "89 dB SPL" reference with a flat
    /// −18 LUFS target measured per BS.1770. Storing it in
    /// ``ReplayGain/referenceLoudness`` states truthfully what a synthesized gain
    /// targets; nothing in ``ReplayGainCalculator`` reads the field, so it is
    /// provenance rather than arithmetic.
    public static let referenceLoudnessLUFS = -18.0

    /// `gain = −18 − LUFS`, the whole of the RG 2.0 track-gain mapping.
    ///
    /// - Returns: `nil` when `integratedLUFS` is absent — the silence sentinel
    ///   todo 4 defines. Substituting `0` would claim the file is already at the
    ///   reference level, which is exactly the opposite of "nothing cleared the
    ///   absolute gate", so absence propagates instead.
    public static func gainDB(forIntegratedLUFS integratedLUFS: Double?) -> Double? {
        guard let integratedLUFS, integratedLUFS.isFinite else { return nil }
        return referenceLoudnessLUFS - integratedLUFS
    }
}

// MARK: - LoudnessScanResult

/// One file's measured loudness and true peak, plus the gating blocks that back
/// album pooling.
public struct LoudnessScanResult: Sendable, Equatable {
    /// Integrated (twice-gated) loudness in LUFS, or `nil` when nothing cleared
    /// the absolute −70 LKFS gate.
    public let integratedLUFS: Double?

    /// The 4×-oversampled true peak, linear (`1.0` == full scale, `> 1.0` is
    /// normal and expected on a loud master). Always present: a peak is always
    /// computable, and digital silence measures exactly `0`.
    public let truePeak: Double

    /// Every 400 ms block that cleared the **absolute** gate, in time order.
    ///
    /// The relative gate is NOT pre-applied — see ``LoudnessMeasurement``. This
    /// is what gets histogrammed into `trackLoudness.blockPowersHistogram`, and
    /// trimming it here would bias every album containing one quiet track.
    public let gatedBlockLoudness: [Double]

    /// Complete 400 ms blocks the pass produced BEFORE any gating.
    public let blockCount: Int

    public init(
        integratedLUFS: Double?,
        truePeak: Double,
        gatedBlockLoudness: [Double],
        blockCount: Int
    ) {
        self.integratedLUFS = integratedLUFS
        self.truePeak = truePeak
        self.gatedBlockLoudness = gatedBlockLoudness
        self.blockCount = blockCount
    }

    /// Pairs a ``LoudnessMeasurement`` with the true peak measured beside it.
    public init(measurement: LoudnessMeasurement, truePeak: Double) {
        self.init(
            integratedLUFS: measurement.integratedLUFS,
            truePeak: truePeak,
            gatedBlockLoudness: measurement.gatedBlockLoudness,
            blockCount: measurement.blockCount
        )
    }
}

// MARK: - Derived reads

public extension LoudnessScanResult {
    /// The RG 2.0 track gain in dB, or `nil` for the silence sentinel.
    var trackGainDB: Double? {
        ReplayGainSynthesis.gainDB(forIntegratedLUFS: integratedLUFS)
    }

    /// This measurement as the tag value type the playback path consumes.
    ///
    /// Album fields stay `nil`: they are a property of a GROUP, resolved by
    /// ``LoudnessScanService`` once every member of an album has been measured,
    /// and a single-file scan has no group to speak for.
    var replayGain: ReplayGain {
        ReplayGain(
            referenceLoudness: ReplayGainSynthesis.referenceLoudnessLUFS,
            trackGain: trackGainDB,
            trackPeak: truePeak
        )
    }
}
