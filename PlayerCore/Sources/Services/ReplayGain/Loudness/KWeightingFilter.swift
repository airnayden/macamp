//
//  KWeightingFilter.swift
//  MacAMP PlayerCore — Services
//
//  One channel's K-weighting state: the two ``KWeightingCoefficients`` stages
//  cascaded as Direct-Form-I biquads over `vDSP_deq22D`.
//
//  Double precision, deliberately. Stage 2's poles sit at |z| ≈ 0.995 — a very
//  narrow high-pass right against DC — and a Float recursion accumulates
//  visible error over a multi-minute file. This runs OFFLINE (never on the
//  audio thread), so the wider accumulator costs nothing that matters.
//
//  Every buffer is allocated once in `init` and reused, mirroring
//  `DSP.SpectrumAnalyzer` and `SpectralWindowAnalyzer`.
//
//  This file imports Accelerate + Foundation; it MUST NOT import AppKit or
//  UIKit (PlayerCore portability invariant).
//

import Accelerate
import Foundation

/// Cascaded K-weighting for exactly ONE channel, with filter memory that
/// carries across calls so a stream can be fed in arbitrary chunks.
///
/// Not thread-safe and not shareable: one instance belongs to one channel of
/// one measurement pass for that pass's whole lifetime.
final class KWeightingFilter {
    /// Largest `count` a single ``filteredSumOfSquares(_:count:)`` accepts.
    let capacity: Int

    /// `[b0, b1, b2, a1, a2]` for stage 1 at offsets 0…4 and stage 2 at 5…9.
    private let coefficients: UnsafeMutablePointer<Double>

    /// Stage-1 input history + samples. Slots 0…1 hold `x[n−2]`, `x[n−1]`.
    private let stage1Input: UnsafeMutablePointer<Double>

    /// Stage-1 output — which is simultaneously stage 2's input array, because
    /// its two history slots hold exactly the samples stage 2 last consumed.
    private let stage1Output: UnsafeMutablePointer<Double>

    /// Stage-2 output. Slots 0…1 hold `y[n−2]`, `y[n−1]`.
    private let stage2Output: UnsafeMutablePointer<Double>

    /// Coefficients per biquad section, in `vDSP_deq22D` order.
    private static let sectionStride = 5

    init(sampleRate: Double, capacity: Int) {
        self.capacity = capacity
        let slots = capacity + 2
        let packed = KWeightingCoefficients.stage1(sampleRate: sampleRate).deq22Coefficients
            + KWeightingCoefficients.stage2(sampleRate: sampleRate).deq22Coefficients

        coefficients = .allocate(capacity: packed.count)
        coefficients.initialize(repeating: 0, count: packed.count)
        for (offset, value) in packed.enumerated() {
            coefficients[offset] = value
        }

        stage1Input = .allocate(capacity: slots)
        stage1Output = .allocate(capacity: slots)
        stage2Output = .allocate(capacity: slots)
        stage1Input.initialize(repeating: 0, count: slots)
        stage1Output.initialize(repeating: 0, count: slots)
        stage2Output.initialize(repeating: 0, count: slots)
    }

    deinit {
        coefficients.deallocate()
        stage1Input.deallocate()
        stage1Output.deallocate()
        stage2Output.deallocate()
    }

    /// Runs `count` samples through both stages and returns the **sum of
    /// squares** of the K-weighted result.
    ///
    /// Energy is all the caller ever wants — no filtered signal escapes, which
    /// keeps the scratch buffers strictly private and reusable.
    ///
    /// - Parameters:
    ///   - source: Planar float samples for this filter's channel.
    ///   - count: How many to consume. Must not exceed ``capacity``.
    /// - Returns: `Σ y[n]²` over the K-weighted output of this chunk.
    func filteredSumOfSquares(_ source: UnsafePointer<Float>, count: Int) -> Double {
        guard count > 0 else { return 0 }
        guard count <= capacity else {
            fatalError("KWeightingFilter fed \(count) samples with capacity \(capacity)")
        }

        let length = vDSP_Length(count)
        vDSP_vspdp(source, 1, stage1Input + 2, 1, length)
        vDSP_deq22D(stage1Input, 1, coefficients, stage1Output, 1, length)
        vDSP_deq22D(stage1Output, 1, coefficients + Self.sectionStride, stage2Output, 1, length)

        var energy = 0.0
        vDSP_svesqD(stage2Output + 2, 1, &energy, length)

        carryHistory(of: stage1Input, after: count)
        carryHistory(of: stage1Output, after: count)
        carryHistory(of: stage2Output, after: count)
        return energy
    }

    // MARK: Private

    /// Moves a stage's last two samples into its history slots so the next
    /// chunk continues the recursion exactly where this one stopped.
    private func carryHistory(of buffer: UnsafeMutablePointer<Double>, after count: Int) {
        buffer[0] = buffer[count]
        buffer[1] = buffer[count + 1]
    }
}
