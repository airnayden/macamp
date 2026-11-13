//
//  AlbumLoudnessPooling.swift
//  MacAMP PlayerCore — Services
//
//  Album gain, the beets way: pool the gating blocks of EVERY track on the album
//  into one set and re-derive ONE relative gate across it. Not an average of the
//  per-track LUFS figures — that would weight a 40-second interlude the same as
//  an eight-minute closer and re-gate material that was already gated.
//
//  The pooled set is carried as a ``BlockLoudnessHistogram`` rather than the raw
//  blocks, which is what makes pooling possible at all across a page-50 batch: a
//  member outside the current page contributes its STORED histogram instead of
//  being decoded a second time. Pooling is then elementwise addition (todo 9's
//  ``BlockLoudnessHistogram/pooled(blobs:)``) and this file's gate recomputation.
//
//  Gate recomputation runs over the 751 bin CENTRES weighted by their counts,
//  which is arithmetically identical to expanding the histogram back into a block
//  array and calling ``LoudnessGating/integratedLoudness(ofAbsoluteGatedBlocks:)``
//  — but O(binCount) instead of O(blocks), so a 50-track box set costs the same
//  751 iterations as a single. The only difference is bin resolution: every block
//  is read as its bin centre, so the answer is accurate to ±0.05 dB.
//
//  This file imports only Foundation + Persistence (for the histogram layout); it
//  MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
//

import Foundation
import Persistence

/// Gate recomputation over a pooled block-loudness histogram.
public enum AlbumLoudnessPooling {
    /// The largest album group that will be pooled.
    ///
    /// Bounded because both halves of the operation are bounded:
    /// ``TrackLoudnessRepository/loudness(forTrackIds:)`` and
    /// ``TrackLoudnessRepository/applyAlbumLoudness(trackIds:albumLUFS:albumPeak:)``
    /// each cap at ``TrackLoudnessRepository/fetchLimit``, and this pass chunks
    /// both to that size. A "group" larger than this is a data error (one
    /// `albumId` shared by half a library), not a box set, and is left unpooled
    /// rather than half-pooled.
    public static let maximumMembers = TrackLoudnessRepository.fetchLimit

    /// Integrated loudness (BS.1770-4 §5) of a pooled histogram, in LUFS.
    ///
    /// `counts` must hold only ABSOLUTE-gate-passing blocks — which is what
    /// ``BlockLoudnessHistogram`` stores, since it drops everything at or below
    /// −70 LKFS. The RELATIVE gate is applied here and nowhere else, derived from
    /// the ungated mean of the whole pooled set.
    ///
    /// - Returns: `nil` when the pooled set is empty (every member was silence),
    ///   or when `counts` is not ``BlockLoudnessHistogram/binCount`` long.
    public static func integratedLoudness(ofPooledHistogram counts: [UInt32]) -> Double? {
        guard counts.count == BlockLoudnessHistogram.binCount else { return nil }
        guard let ungatedMean = meanLoudness(of: counts, above: -.infinity) else { return nil }
        return meanLoudness(of: counts, above: ungatedMean + LoudnessGating.relativeGateOffsetLU)
    }

    // MARK: Private

    /// Mean **power** (not mean dB) of every bin whose centre sits above
    /// `threshold`, converted back to LKFS — the histogram form of
    /// ``LoudnessGating/meanLoudness(of:)``.
    private static func meanLoudness(of counts: [UInt32], above threshold: Double) -> Double? {
        var total = 0.0
        var population = 0.0
        for (bin, count) in counts.enumerated() where count > 0 {
            let centre = BlockLoudnessHistogram.binCentreLKFS(bin)
            guard centre > threshold else { continue }
            let weight = Double(count)
            total += weight * LoudnessGating.weightedMeanSquare(ofLoudness: centre)
            population += weight
        }
        guard population > 0 else { return nil }
        let mean = total / population
        guard mean > 0 else { return nil }
        return LoudnessGating.loudness(ofWeightedMeanSquare: mean)
    }
}
