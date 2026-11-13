//
//  LoudnessMeasurement.swift
//  MacAMP PlayerCore — Services
//
//  What one BS.1770-4 pass over one file yields.
//
//  This file imports only Foundation; it MUST NOT import AppKit or UIKit
//  (PlayerCore portability invariant).
//

import Foundation

/// The result of a gated loudness measurement.
public struct LoudnessMeasurement: Sendable, Equatable {
    /// Integrated (twice-gated) loudness in LUFS.
    ///
    /// `nil` is the silence sentinel: NO 400 ms block cleared the absolute
    /// −70 LKFS gate. That covers empty input, digital silence, a clip shorter
    /// than one 400 ms block, and genuine programme quieter than the gate (a
    /// −80 dBFS tone, whose blocks each read ≈ −80 LUFS). A caller must not
    /// substitute 0 dB for `nil` — there is no measurable loudness to
    /// normalise against.
    public let integratedLUFS: Double?

    /// Every 400 ms block that cleared the **absolute** −70 LKFS gate, in time
    /// order, in LKFS.
    ///
    /// The **relative** gate is deliberately NOT pre-applied. This set is the
    /// pooling and histogramming currency: album gain concatenates the sets of
    /// every track and re-derives one Γr across the whole album, which is only
    /// correct if each track contributed its full absolute-gated set. Trimming
    /// here would raise Γr for every album that contains one quiet track.
    public let gatedBlockLoudness: [Double]

    /// How many complete 400 ms blocks the pass produced, BEFORE any gating.
    ///
    /// Distinguishes "no audio at all" (`0`) from "audio, all of it below the
    /// absolute gate" (`> 0` with an empty ``gatedBlockLoudness``).
    public let blockCount: Int

    public init(integratedLUFS: Double?, gatedBlockLoudness: [Double], blockCount: Int) {
        self.integratedLUFS = integratedLUFS
        self.gatedBlockLoudness = gatedBlockLoudness
        self.blockCount = blockCount
    }

    /// The sentinel for input that produced no measurable loudness.
    public static let silent = LoudnessMeasurement(
        integratedLUFS: nil,
        gatedBlockLoudness: [],
        blockCount: 0
    )
}
