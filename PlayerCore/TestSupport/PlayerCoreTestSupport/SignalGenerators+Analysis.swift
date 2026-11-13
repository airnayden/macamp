// SignalGenerators+Analysis — raw sample fixtures for offline feature analysis.
//
// The generators in `SignalGenerators` vend `AVAudioSourceNode`s for the offline
// RENDER harness. Offline ANALYSIS pulls through a decoder instead, so it needs
// the same signals as plain `[Float]` — pair these with `BufferDecoderProvider`.
//
// Two signals the tone generators cannot express:
//
//   * a click train, because a steady sine has no onsets at all and therefore
//     nothing for a tempo detector to lock onto; its period is exactly
//     `60 / bpm` seconds, so the expected answer comes from the fixture rather
//     than from eyeballing a recording, and
//   * broadband noise, the aperiodic control that proves a tempo detector
//     reports nothing rather than inventing a beat.
import Foundation

public extension SignalGenerators {
    /// A metronome click train: `bpm` bursts per minute across `duration` seconds.
    ///
    /// Each click is a short, exponentially decaying BROADBAND noise burst — not a
    /// tone — so every band of a multi-band onset detector fires on it. The noise
    /// PRNG is re-seeded per burst, making every click byte-identical and the
    /// train exactly periodic.
    ///
    /// - Parameters:
    ///   - bpm: Beats per minute; the click period is `60 / bpm` seconds.
    ///   - duration: Total length in seconds.
    ///   - sampleRate: Output sample rate in Hz.
    ///   - amplitude: Linear peak amplitude of each burst (default 0.9).
    /// - Returns: Mono float samples, silent between clicks.
    static func clickTrack(
        bpm: Double,
        duration: Double,
        sampleRate: Double,
        amplitude: Float = 0.9
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: frameCount(duration: duration, sampleRate: sampleRate))
        guard bpm > 0, sampleRate > 0 else { return samples }

        let period = 60.0 / bpm * sampleRate
        let burst = max(Int((clickBurstSeconds * sampleRate).rounded()), 1)
        let decay = Float(-1.0 / (clickDecaySeconds * sampleRate))
        var click = 0
        while true {
            let start = Int((Double(click) * period).rounded())
            if start >= samples.count { break }
            var noise = DeterministicNoise(seed: analysisSeed)
            for offset in 0 ..< burst where start + offset < samples.count {
                samples[start + offset] = amplitude * exp(decay * Float(offset)) * noise.nextSigned()
            }
            click += 1
        }
        return samples
    }

    /// Deterministic broadband noise as raw mono samples — the `[Float]`
    /// counterpart of ``SignalGenerators/whiteNoise(sampleRate:amplitude:seed:)``.
    static func whiteNoiseSamples(
        duration: Double,
        sampleRate: Double,
        amplitude: Float = 0.5
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: frameCount(duration: duration, sampleRate: sampleRate))
        var noise = DeterministicNoise(seed: analysisSeed)
        for index in samples.indices {
            samples[index] = noise.nextSigned() * amplitude
        }
        return samples
    }

    private static func frameCount(duration: Double, sampleRate: Double) -> Int {
        max(Int((duration * sampleRate).rounded()), 1)
    }

    /// Click burst length. Shorter than one 512-sample analysis hop at 44.1 kHz,
    /// so a click yields one sharp onset frame rather than a smear.
    private static var clickBurstSeconds: Double {
        0.008
    }

    /// Exponential decay constant — a burst is down to `e⁻⁴` by its end.
    private static var clickDecaySeconds: Double {
        0.002
    }

    private static var analysisSeed: UInt64 {
        0x2545_F491_4F6C_DD1D
    }
}

/// Seeded xorshift64* noise. A value type, so re-creating it restarts the exact
/// same sequence — which is what makes every click in a train byte-identical.
private struct DeterministicNoise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    /// The next value mapped into `[-1, 1)`.
    mutating func nextSigned() -> Float {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let unit = Double((state &* 0x2545_F491_4F6C_DD1D) >> 11) * (1.0 / 9_007_199_254_740_992.0)
        return Float(unit * 2.0 - 1.0)
    }
}
