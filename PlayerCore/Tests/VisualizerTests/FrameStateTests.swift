import Testing
@testable import Visualizer

@Suite("Visualizer frame state")
struct FrameStateTests {
    // MARK: Band → bar mapping

    @Test("mapBandsToBars averages bands into the requested bar count")
    func mapBandsCount() {
        let spectrum = [Float](repeating: 0.5, count: 128)
        let bars = VisualizerFrameState.mapBandsToBars(spectrum, barCount: 64)
        #expect(bars.count == 64)
        #expect(bars.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    @Test("mapBandsToBars clamps every bar into 0...1")
    func mapBandsClamp() {
        let spectrum: [Float] = [2.0, -1.0, 0.5, 10.0]
        let bars = VisualizerFrameState.mapBandsToBars(spectrum, barCount: 4)
        #expect(bars.count == 4)
        #expect(bars.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("mapBandsToBars maps an empty spectrum to all zeros")
    func mapBandsEmpty() {
        let bars = VisualizerFrameState.mapBandsToBars([], barCount: 8)
        #expect(bars.count == 8)
        #expect(bars.allSatisfy { $0 == 0 })
    }

    @Test("spectrumEnergy is the clamped mean magnitude")
    func energyMean() {
        #expect(abs(VisualizerFrameState.spectrumEnergy([0.2, 0.4, 0.6]) - 0.4) < 0.0001)
        #expect(VisualizerFrameState.spectrumEnergy([]) == 0)
        #expect(VisualizerFrameState.spectrumEnergy([5, 5]) == 1)
    }

    // MARK: Particles

    @Test("simulateParticles is deterministic for a fixed seed")
    func particlesDeterministic() {
        let spectrum = [Float](repeating: 0.3, count: 64)
        let first = VisualizerFrameState.simulateParticles(
            spectrum: spectrum, count: 32, time: 1.5, seed: 99, motionEnabled: true
        )
        let second = VisualizerFrameState.simulateParticles(
            spectrum: spectrum, count: 32, time: 1.5, seed: 99, motionEnabled: true
        )
        #expect(first.count == 32)
        #expect(first == second)
    }

    @Test("simulateParticles differs across seeds")
    func particlesSeedVaries() {
        let spectrum = [Float](repeating: 0.3, count: 64)
        let lowSeed = VisualizerFrameState.simulateParticles(
            spectrum: spectrum, count: 32, time: 1.5, seed: 1, motionEnabled: true
        )
        let highSeed = VisualizerFrameState.simulateParticles(
            spectrum: spectrum, count: 32, time: 1.5, seed: 2, motionEnabled: true
        )
        #expect(lowSeed != highSeed)
    }

    @Test("simulateParticles applies no drift when motion is disabled")
    func particlesMotionOff() {
        let spectrum = [Float](repeating: 0.3, count: 64)
        let early = VisualizerFrameState.simulateParticles(
            spectrum: spectrum, count: 24, time: 0, seed: 7, motionEnabled: false
        )
        let later = VisualizerFrameState.simulateParticles(
            spectrum: spectrum, count: 24, time: 9, seed: 7, motionEnabled: false
        )
        // Time is irrelevant when motion is off.
        #expect(early == later)
        let moving = VisualizerFrameState.simulateParticles(
            spectrum: spectrum, count: 24, time: 9, seed: 7, motionEnabled: true
        )
        #expect(moving != later)
    }

    @Test("simulateParticles keeps positions within the unit square")
    func particlesWrapped() {
        let spectrum = [Float](repeating: 0.9, count: 64)
        let particles = VisualizerFrameState.simulateParticles(
            spectrum: spectrum, count: 48, time: 123.4, seed: 5, motionEnabled: true
        )
        #expect(particles.allSatisfy {
            $0.position.x >= 0 && $0.position.x < 1 && $0.position.y >= 0 && $0.position.y < 1
        })
    }

    // MARK: Waveform

    @Test("resolveWaveform resamples provided samples to the requested count")
    func waveformResample() {
        let provided = [Float](repeating: 0.5, count: 100)
        let resolved = VisualizerFrameState.resolveWaveform(provided, spectrum: [], sampleCount: 256)
        #expect(resolved.count == 256)
        #expect(resolved.allSatisfy { abs($0 - 0.5) < 0.0001 })
    }

    @Test("resolveWaveform synthesises a bounded wave from the spectrum")
    func waveformSynth() {
        let spectrum = [Float](repeating: 0.8, count: 32)
        let resolved = VisualizerFrameState.resolveWaveform([], spectrum: spectrum, sampleCount: 128)
        #expect(resolved.count == 128)
        #expect(resolved.contains { $0 != 0 })
        #expect(resolved.allSatisfy { $0 >= -1 && $0 <= 1 })
    }

    @Test("resolveWaveform with no input yields zeros")
    func waveformEmpty() {
        let resolved = VisualizerFrameState.resolveWaveform([], spectrum: [], sampleCount: 64)
        #expect(resolved.count == 64)
        #expect(resolved.allSatisfy { $0 == 0 })
    }

    // MARK: Frame assembly

    @Test("make computes only the data the mode renders")
    func makeComputesPerMode() {
        let spectrum = [Float](repeating: 0.5, count: 128)
        let inputs = FrameInputs(spectrum: spectrum, waveform: [], time: 0, seed: 3, motionEnabled: true)
        let accent = SIMD4<Float>(1, 1, 1, 1)
        let background = SIMD4<Float>(0, 0, 0, 1)

        let bars = VisualizerFrameState.make(
            mode: .bars, inputs: inputs, config: VisualizerConfig(), accent: accent, background: background
        )
        #expect(!bars.bars.isEmpty)
        #expect(bars.particles.isEmpty)

        let particles = VisualizerFrameState.make(
            mode: .particles, inputs: inputs, config: VisualizerConfig(), accent: accent, background: background
        )
        #expect(particles.bars.isEmpty)
        #expect(!particles.particles.isEmpty)
    }
}
