// SignalGenerators — deterministic test signal sources for the offline harness.
//
// All generators produce mono, non-interleaved float (the standard processing
// format). `AVAudioSourceNode` render blocks are `@Sendable` (Swift 6 strict
// concurrency); mutable per-render state lives in small `@unchecked Sendable`
// reference boxes mutated only on the (single) offline render thread.
import AVFAudio
import Foundation

/// Static factory functions producing test signals as `AVAudioSourceNode`s or
/// pre-filled `AVAudioPCMBuffer`s.
public enum SignalGenerators {
    /// Standard mono float format for a given sample rate.
    public static func monoFormat(sampleRate: Double) -> AVAudioFormat {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            fatalError("standard mono float AVAudioFormat is unconstructible at \(sampleRate) Hz")
        }
        return format
    }

    /// A continuous sine tone source node.
    ///
    /// - Parameters:
    ///   - frequency: Tone frequency in Hz.
    ///   - sampleRate: Output sample rate in Hz.
    ///   - amplitude: Linear peak amplitude (default 0.9, below full scale).
    public static func sine(
        frequency: Double,
        sampleRate: Double,
        amplitude: Float = 0.9
    ) -> AVAudioSourceNode {
        let phaseBox = PhaseBox()
        let increment = 2.0 * Double.pi * frequency / sampleRate
        let block: AVAudioSourceNodeRenderBlock = { _, _, frameCount, audioBufferList in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var phase = phaseBox.phase
            for frame in 0 ..< Int(frameCount) {
                let value = Float(sin(phase)) * amplitude
                phase += increment
                if phase >= 2.0 * Double.pi { phase -= 2.0 * Double.pi }
                for buffer in ablPointer {
                    let samples = UnsafeMutableBufferPointer<Float>(buffer)
                    samples[frame] = value
                }
            }
            phaseBox.phase = phase
            return noErr
        }
        return AVAudioSourceNode(format: monoFormat(sampleRate: sampleRate), renderBlock: block)
    }

    /// A digital-silence source node (every sample exactly 0.0).
    public static func silence(sampleRate: Double) -> AVAudioSourceNode {
        let block: AVAudioSourceNodeRenderBlock = { isSilence, _, frameCount, audioBufferList in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in ablPointer {
                let samples = UnsafeMutableBufferPointer<Float>(buffer)
                for frame in 0 ..< Int(frameCount) {
                    samples[frame] = 0
                }
            }
            isSilence.pointee = true
            return noErr
        }
        return AVAudioSourceNode(format: monoFormat(sampleRate: sampleRate), renderBlock: block)
    }

    /// A deterministic white-noise source node (seeded xorshift PRNG).
    ///
    /// Determinism keeps RMS-based assertions stable across runs.
    public static func whiteNoise(
        sampleRate: Double,
        amplitude: Float = 0.5,
        seed: UInt64 = 0x2545_F491_4F6C_DD1D
    ) -> AVAudioSourceNode {
        let rng = RNGBox(seed: seed)
        let block: AVAudioSourceNodeRenderBlock = { _, _, frameCount, audioBufferList in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0 ..< Int(frameCount) {
                // Map to [-1, 1) then scale by amplitude.
                let unit = Float(rng.nextUnit()) * 2.0 - 1.0
                let value = unit * amplitude
                for buffer in ablPointer {
                    let samples = UnsafeMutableBufferPointer<Float>(buffer)
                    samples[frame] = value
                }
            }
            return noErr
        }
        return AVAudioSourceNode(format: monoFormat(sampleRate: sampleRate), renderBlock: block)
    }

    /// Two tones rendered back-to-back into a single buffer with **no** silence
    /// gap at the boundary — for gapless-continuity testing.
    ///
    /// Each tone resets phase to 0 at its start (so both begin at sample 0.0),
    /// guaranteeing the only boundary artifact is the frequency change itself,
    /// never an inserted silence gap.
    public static func concatenated(
        toneA: (freq: Double, duration: Double),
        toneB: (freq: Double, duration: Double),
        sampleRate: Double,
        amplitude: Float = 0.9
    ) -> AVAudioPCMBuffer {
        let format = monoFormat(sampleRate: sampleRate)
        let framesA = AVAudioFrameCount((toneA.duration * sampleRate).rounded())
        let framesB = AVAudioFrameCount((toneB.duration * sampleRate).rounded())
        let total = framesA + framesB
        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(total, 1)),
            let data = buffer.floatChannelData?[0]
        else {
            fatalError("PCM buffer for \(total) concatenated frames is unallocatable")
        }

        var index = 0
        let incrementA = 2.0 * Double.pi * toneA.freq / sampleRate
        let incrementB = 2.0 * Double.pi * toneB.freq / sampleRate
        fillTone(into: data, at: &index, frames: Int(framesA), increment: incrementA, amplitude: amplitude)
        fillTone(into: data, at: &index, frames: Int(framesB), increment: incrementB, amplitude: amplitude)

        buffer.frameLength = total
        return buffer
    }

    // MARK: - Private helpers

    private static func fillTone(
        into data: UnsafeMutablePointer<Float>,
        at index: inout Int,
        frames: Int,
        increment: Double,
        amplitude: Float
    ) {
        var phase = 0.0
        for _ in 0 ..< frames {
            data[index] = Float(sin(phase)) * amplitude
            phase += increment
            if phase >= 2.0 * Double.pi { phase -= 2.0 * Double.pi }
            index += 1
        }
    }
}

// MARK: - Sendable mutable state boxes

/// Holds sine phase across render blocks. Mutated only on the offline render
/// thread, so `@unchecked Sendable` is sound here.
private final class PhaseBox: @unchecked Sendable {
    var phase: Double = 0
}

/// Seeded xorshift64* PRNG box for deterministic white noise.
private final class RNGBox: @unchecked Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        // Avoid the all-zero state (xorshift fixed point).
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    /// Returns the next raw 64-bit value.
    private func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    /// Returns the next value mapped into the half-open unit interval [0, 1).
    func nextUnit() -> Double {
        // Use the top 53 bits for a double in [0, 1).
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
