//
//  LoudnessAnalyzer.swift
//  MacAMP PlayerCore — Services
//
//  ITU-R BS.1770-4 gated loudness: K-weight every channel, square it into
//  400 ms blocks overlapping by 75 %, weight and sum the channels, then gate
//  twice.
//
//  The 75 % overlap is realised by accumulating 100 ms SUB-blocks and summing
//  four consecutive ones — identical arithmetic to sliding a 400 ms window by
//  100 ms, but each sample is squared once instead of four times, and only
//  four sub-block sums per channel are ever held. Memory is therefore flat in
//  file length apart from the block-loudness set the caller asked for.
//
//  Offline only. Nothing here may run on the audio thread: it allocates at
//  init, grows an array per block, and computes logarithms.
//
//  This file imports Foundation (+ ``KWeightingFilter``'s Accelerate); it MUST
//  NOT import AppKit or UIKit (PlayerCore portability invariant).
//

import Foundation

/// A single streaming BS.1770-4 measurement pass over one file.
///
/// `@unchecked Sendable` mirrors `SpectralWindowAnalyzer`: the filter storage
/// is owned exclusively by this instance, and one instance serves exactly one
/// pass, so two passes never share it.
public final class LoudnessAnalyzer: @unchecked Sendable {
    /// Gating block length (s) — BS.1770-4 §5.
    public static let blockDurationSeconds = 0.4

    /// Step between consecutive blocks (s), i.e. 75 % overlap.
    public static let hopDurationSeconds = 0.1

    /// Sub-blocks that make up one gating block.
    private static let subBlocksPerBlock = 4

    public let sampleRate: Double
    public let channelCount: Int

    private let weights: [Double]
    private let filters: [KWeightingFilter]
    private let subBlockFrames: Int

    /// Ring of the last ``subBlocksPerBlock`` sub-block sums-of-squares, per
    /// channel, indexed `[channel][slot]`.
    private var ring: [[Double]]
    private var ringSlot = 0

    /// Sum-of-squares accumulating into the sub-block currently being filled.
    private var pending: [Double]
    private var pendingFrames = 0

    private var completedSubBlocks = 0
    private var blocks: [Double] = []

    /// - Parameters:
    ///   - sampleRate: Frames per second of the material being fed.
    ///   - channelCount: Planar channel count, in `L, R, C, LFE, Ls, Rs` order.
    public init(sampleRate: Double, channelCount: Int) {
        let usableRate = sampleRate > 0 ? sampleRate : 0
        let usableChannels = max(0, channelCount)
        self.sampleRate = usableRate
        self.channelCount = usableChannels

        let framesPerSubBlock = Int((usableRate * Self.hopDurationSeconds).rounded())
        let channelFilters = framesPerSubBlock > 0
            ? (0 ..< usableChannels).map { _ in
                KWeightingFilter(sampleRate: usableRate, capacity: framesPerSubBlock)
            }
            : []

        subBlockFrames = framesPerSubBlock
        filters = channelFilters
        weights = LoudnessChannelWeights.weights(forChannelCount: usableChannels)
        ring = Array(
            repeating: Array(repeating: 0, count: Self.subBlocksPerBlock),
            count: channelFilters.count
        )
        pending = Array(repeating: 0, count: channelFilters.count)
    }

    /// Feeds `frameCount` frames of de-interleaved float channel data.
    ///
    /// `channels` must hold exactly ``channelCount`` pointers, each valid for
    /// `frameCount` frames. Chunks of any size may be fed; filter memory and
    /// partial sub-blocks carry across calls.
    public func append(channels: [UnsafePointer<Float>], frameCount: Int) {
        guard !filters.isEmpty, channels.count == filters.count, frameCount > 0 else { return }
        var consumed = 0
        while consumed < frameCount {
            let span = min(frameCount - consumed, subBlockFrames - pendingFrames)
            for (index, filter) in filters.enumerated() {
                pending[index] += filter.filteredSumOfSquares(channels[index] + consumed, count: span)
            }
            consumed += span
            pendingFrames += span
            if pendingFrames == subBlockFrames { closeSubBlock() }
        }
    }

    /// Feeds contiguous planar channel arrays, consuming the shortest one's
    /// length so a ragged set can never read out of bounds.
    public func append(channels: [[Float]]) {
        guard !filters.isEmpty, channels.count == filters.count else { return }
        guard let frameCount = channels.map(\.count).min(), frameCount > 0 else { return }
        appendRecursively(channels, resolved: [], frameCount: frameCount)
    }

    /// Ends the pass and returns the measurement. Any trailing audio shorter
    /// than a full 400 ms block is discarded, as BS.1770-4 requires.
    public func finish() -> LoudnessMeasurement {
        LoudnessMeasurement(
            integratedLUFS: LoudnessGating.integratedLoudness(ofAbsoluteGatedBlocks: blocks),
            gatedBlockLoudness: blocks,
            blockCount: max(0, completedSubBlocks - (Self.subBlocksPerBlock - 1))
        )
    }

    /// One-shot measurement of fully-decoded planar channel data.
    public static func measure(channels: [[Float]], sampleRate: Double) -> LoudnessMeasurement {
        let analyzer = LoudnessAnalyzer(sampleRate: sampleRate, channelCount: channels.count)
        analyzer.append(channels: channels)
        return analyzer.finish()
    }

    // MARK: Private

    /// Commits the filled sub-block into the ring and, once four are available,
    /// emits the gating block ending here.
    private func closeSubBlock() {
        for index in pending.indices {
            ring[index][ringSlot] = pending[index]
            pending[index] = 0
        }
        ringSlot = (ringSlot + 1) % Self.subBlocksPerBlock
        pendingFrames = 0
        completedSubBlocks += 1
        guard completedSubBlocks >= Self.subBlocksPerBlock else { return }
        emitBlock()
    }

    /// `L = −0.691 + 10·log10(Σ Gᵢzᵢ)` over the four sub-blocks now in the
    /// ring, retained only if it clears the ABSOLUTE gate. The relative gate is
    /// applied later, in ``LoudnessGating/integratedLoudness(ofAbsoluteGatedBlocks:)``.
    private func emitBlock() {
        let blockFrames = Double(subBlockFrames * Self.subBlocksPerBlock)
        var weighted = 0.0
        for index in ring.indices {
            let weight = index < weights.count ? weights[index] : 1.0
            guard weight > 0 else { continue }
            weighted += weight * (ring[index].reduce(0, +) / blockFrames)
        }
        let loudness = LoudnessGating.loudness(ofWeightedMeanSquare: weighted)
        guard loudness > LoudnessGating.absoluteThresholdLKFS else { return }
        blocks.append(loudness)
    }

    /// Walks `channels` one at a time so every array's buffer pointer stays
    /// alive for the single ``append(channels:frameCount:)`` call that reads
    /// them all — `withUnsafeBufferPointer` guarantees validity only inside its
    /// own closure, so the pointers must be collected by nesting, not by
    /// mapping into an escaping array.
    private func appendRecursively(
        _ remaining: [[Float]],
        resolved: [UnsafePointer<Float>],
        frameCount: Int
    ) {
        guard let next = remaining.first else {
            append(channels: resolved, frameCount: frameCount)
            return
        }
        next.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            appendRecursively(Array(remaining.dropFirst()), resolved: resolved + [base], frameCount: frameCount)
        }
    }
}
