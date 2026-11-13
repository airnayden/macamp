import Foundation

// MARK: - VizParticle

/// A single particle in the particle-field mode.
///
/// Packed to 16 bytes (`SIMD2<Float>` + two `Float`) so the Swift array can be
/// `memcpy`-ed straight into an `MTLBuffer` whose Metal struct has the identical
/// layout — zero per-frame translation. Uses the native SIMD types (no
/// `import simd`).
struct VizParticle: Equatable {
    /// Normalised position in `0...1` (origin bottom-left, matching the shader).
    var position: SIMD2<Float>
    /// Relative glow radius factor in `0...1`.
    var size: Float
    /// Brightness multiplier in `0...1`, scaled by spectral energy.
    var intensity: Float
}

// MARK: - VisualizerConfig

/// Tunables for the CPU-side frame builder. Counts MUST stay within the
/// renderer's pre-allocated buffer capacities (bars ≤ 128, waveform ≤ 512,
/// particles ≤ 64).
struct VisualizerConfig {
    var barCount = 64
    var particleCount = 48
    var waveformSamples = 256
}

// MARK: - FrameInputs

/// Per-tick inputs bundled into one value so ``VisualizerFrameState/make(mode:inputs:config:accent:background:)``
/// stays within SwiftLint's 5-parameter ceiling.
struct FrameInputs {
    var spectrum: [Float]
    var waveform: [Float]
    var time: Float
    var seed: UInt64
    var motionEnabled: Bool
}

// MARK: - VisualizerFrameState

/// One frame's worth of CPU-side render state, produced by pulling the latest
/// spectrum/waveform and integrating deterministic effects.
///
/// Separated from GPU submission so all logic (band→bar mapping, particle
/// integration, waveform synthesis) is testable WITHOUT a Metal device.
struct VisualizerFrameState {
    var bars: [Float]
    var waveform: [Float]
    var particles: [VizParticle]
    var energy: Float
    var time: Float
    var accent: SIMD4<Float>
    var background: SIMD4<Float>

    // MARK: Band → bar mapping

    /// Averages `spectrum` bands into `barCount` bars, each clamped to `0...1`.
    /// An empty spectrum yields all-zero bars; a non-positive `barCount` yields
    /// an empty array.
    static func mapBandsToBars(_ spectrum: [Float], barCount: Int) -> [Float] {
        guard barCount > 0 else { return [] }
        guard !spectrum.isEmpty else { return [Float](repeating: 0, count: barCount) }
        var bars = [Float](repeating: 0, count: barCount)
        let bandsPerBar = Double(spectrum.count) / Double(barCount)
        for bar in 0 ..< barCount {
            let start = Int(Double(bar) * bandsPerBar)
            let rawEnd = Int(Double(bar + 1) * bandsPerBar)
            let end = min(max(rawEnd, start + 1), spectrum.count)
            var sum: Float = 0
            for index in start ..< end {
                sum += spectrum[index]
            }
            let average = sum / Float(end - start)
            bars[bar] = min(max(average, 0), 1)
        }
        return bars
    }

    /// Mean spectral magnitude, clamped to `0...1`. Empty → `0`.
    static func spectrumEnergy(_ spectrum: [Float]) -> Float {
        guard !spectrum.isEmpty else { return 0 }
        var sum: Float = 0
        for value in spectrum {
            sum += value
        }
        return min(max(sum / Float(spectrum.count), 0), 1)
    }

    // MARK: Particles

    /// Seeded particle field. Positions are deterministic for a given `seed`;
    /// each particle drifts by `time` ONLY when `motionEnabled` is true (drift
    /// is `0` otherwise). Positions wrap into `0...1`.
    static func simulateParticles(
        spectrum: [Float],
        count: Int,
        time: Float,
        seed: UInt64,
        motionEnabled: Bool
    ) -> [VizParticle] {
        guard count > 0 else { return [] }
        var generator = SeededGenerator(seed: seed)
        let energy = spectrumEnergy(spectrum)
        var particles = [VizParticle]()
        particles.reserveCapacity(count)
        for _ in 0 ..< count {
            let baseX = Float.random(in: 0 ... 1, using: &generator)
            let baseY = Float.random(in: 0 ... 1, using: &generator)
            let speed = Float.random(in: 0.05 ... 0.3, using: &generator)
            let direction = Float.random(in: -1 ... 1, using: &generator)
            let size = Float.random(in: 0.3 ... 1.0, using: &generator)
            let drift = motionEnabled ? time * speed : 0
            let position = SIMD2<Float>(
                wrapUnit(baseX + drift * direction),
                wrapUnit(baseY + drift)
            )
            let intensity = min(max(0.2 + energy, 0), 1)
            particles.append(VizParticle(position: position, size: size, intensity: intensity))
        }
        return particles
    }

    // MARK: Waveform

    /// Returns a `sampleCount`-length waveform in `-1...1`: resamples `provided`
    /// when non-empty, otherwise synthesises a tone shaped by `spectrum`.
    static func resolveWaveform(_ provided: [Float], spectrum: [Float], sampleCount: Int) -> [Float] {
        guard sampleCount > 0 else { return [] }
        if !provided.isEmpty {
            return resample(provided, to: sampleCount)
        }
        guard !spectrum.isEmpty else { return [Float](repeating: 0, count: sampleCount) }
        var samples = [Float](repeating: 0, count: sampleCount)
        for index in 0 ..< sampleCount {
            let phase = Float(index) / Float(sampleCount) * 2 * .pi
            let bandIndex = min(index * spectrum.count / sampleCount, spectrum.count - 1)
            samples[index] = sin(phase * 4) * spectrum[bandIndex]
        }
        return samples
    }

    // MARK: Frame assembly

    /// Builds a frame for `mode`, computing only the data that mode renders.
    static func make(
        mode: VisualizerMode,
        inputs: FrameInputs,
        config: VisualizerConfig,
        accent: SIMD4<Float>,
        background: SIMD4<Float>
    ) -> VisualizerFrameState {
        let energy = spectrumEnergy(inputs.spectrum)
        var bars: [Float] = []
        var waveform: [Float] = []
        var particles: [VizParticle] = []
        switch mode {
        case .bars, .aurora:
            bars = mapBandsToBars(inputs.spectrum, barCount: config.barCount)
        case .oscilloscope:
            waveform = resolveWaveform(
                inputs.waveform,
                spectrum: inputs.spectrum,
                sampleCount: config.waveformSamples
            )
        case .particles:
            particles = simulateParticles(
                spectrum: inputs.spectrum,
                count: config.particleCount,
                time: inputs.time,
                seed: inputs.seed,
                motionEnabled: inputs.motionEnabled
            )
        }
        return VisualizerFrameState(
            bars: bars,
            waveform: waveform,
            particles: particles,
            energy: energy,
            time: inputs.time,
            accent: accent,
            background: background
        )
    }

    // MARK: Helpers

    /// Wraps `value` into the half-open range `[0, 1)`.
    private static func wrapUnit(_ value: Float) -> Float {
        var result = value.truncatingRemainder(dividingBy: 1)
        if result < 0 { result += 1 }
        return result
    }

    /// Nearest-neighbour resample of `input` to exactly `count` samples.
    private static func resample(_ input: [Float], to count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !input.isEmpty else { return [Float](repeating: 0, count: count) }
        guard input.count != count else { return input }
        var output = [Float](repeating: 0, count: count)
        for index in 0 ..< count {
            let source = min(Int(Float(index) / Float(count) * Float(input.count)), input.count - 1)
            output[index] = input[source]
        }
        return output
    }
}
