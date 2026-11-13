import Foundation
import Testing
@testable import Visualizer

@Suite("Spectrum ballistics")
struct BallisticsTests {
    /// Source whose spectrum can be swapped between pulls, so a test can drive a
    /// burst followed by silence through a consumer's own tick loop.
    private final class MutableSpectrumSource: SpectrumSource, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Float]

        init(spectrum: [Float]) {
            stored = spectrum
        }

        var spectrum: [Float] {
            get {
                lock.lock()
                defer { lock.unlock() }
                return stored
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                stored = newValue
            }
        }

        var bandCount: Int {
            spectrum.count
        }

        func latestSpectrum() -> [Float] {
            spectrum
        }

        func latestWaveform() -> [Float] {
            []
        }
    }

    private static let tick = SpectrumBallistics.referenceInterval

    // MARK: - The envelope itself

    @Test("a band released over n 60 fps ticks lands on 0.85^n")
    func releaseFollowsThePerTickFactor() {
        var ballistics = SpectrumBallistics()
        let silence = [Float](repeating: 0, count: 4)
        _ = ballistics.step(new: [1, 1, 1, 1], elapsed: Self.tick)

        for step in 1 ... 5 {
            let levels = ballistics.step(new: silence, elapsed: Self.tick)
            let expected = pow(SpectrumBallistics.releaseFactorPerTick, Float(step))
            #expect(abs(levels[0] - expected) < 0.0001)
        }
    }

    @Test("one 30 fps step decays exactly as two 60 fps steps")
    func releaseIsWallClockScaled() {
        var slow = SpectrumBallistics()
        var fast = SpectrumBallistics()
        let silence = [Float](repeating: 0, count: 1)
        _ = slow.step(new: [1], elapsed: Self.tick)
        _ = fast.step(new: [1], elapsed: Self.tick)

        let slowLevels = slow.step(new: silence, elapsed: Self.tick * 2)
        _ = fast.step(new: silence, elapsed: Self.tick)
        let fastLevels = fast.step(new: silence, elapsed: Self.tick)

        #expect(abs(slowLevels[0] - fastLevels[0]) < 0.0001)
        #expect(abs(slowLevels[0] - pow(SpectrumBallistics.releaseFactorPerTick, 2)) < 0.0001)
    }

    @Test("a rising band reaches its new level within the same step")
    func attackIsInstant() {
        var ballistics = SpectrumBallistics()
        _ = ballistics.step(new: [0.1, 0.1], elapsed: Self.tick)
        let levels = ballistics.step(new: [0.9, 0.2], elapsed: Self.tick)
        #expect(levels[0] == 0.9)
        #expect(levels[1] == 0.2)
    }

    @Test("two instances decay independently — driving one never moves the other")
    func instancesDoNotShareState() {
        var metal = SpectrumBallistics()
        var inline = SpectrumBallistics()
        _ = metal.step(new: [1], elapsed: Self.tick)
        _ = inline.step(new: [1], elapsed: Self.tick)

        for _ in 0 ..< 10 {
            _ = metal.step(new: [0], elapsed: Self.tick)
        }

        let inlineLevels = inline.step(new: [0], elapsed: Self.tick)
        #expect(abs(inlineLevels[0] - SpectrumBallistics.releaseFactorPerTick) < 0.0001)
    }

    @Test("an empty frame clears the envelope instead of holding the last levels")
    func emptyFrameClears() {
        var ballistics = SpectrumBallistics()
        _ = ballistics.step(new: [1, 1], elapsed: Self.tick)
        #expect(ballistics.step(new: [], elapsed: Self.tick).isEmpty)
        #expect(ballistics.step(new: [0.3, 0.3], elapsed: Self.tick) == [0.3, 0.3])
    }

    @Test("a band-count change adopts the new frame outright")
    func bandCountChangeAdopts() {
        var ballistics = SpectrumBallistics()
        _ = ballistics.step(new: [1, 1, 1, 1], elapsed: Self.tick)
        #expect(ballistics.step(new: [0.2, 0.2], elapsed: Self.tick) == [0.2, 0.2])
    }

    @Test("a non-positive or non-finite elapsed holds levels rather than trapping")
    func degenerateElapsedHolds() {
        #expect(SpectrumBallistics.releaseFactor(elapsed: 0) == 1)
        #expect(SpectrumBallistics.releaseFactor(elapsed: -1) == 1)
        #expect(SpectrumBallistics.releaseFactor(elapsed: .nan) == 1)
        #expect(SpectrumBallistics.releaseFactor(elapsed: .infinity) == 1)
    }

    @Test("a long stall decays to the floor with a finite, capped factor")
    func longStallCapsAtTheFloor() {
        let factor = SpectrumBallistics.releaseFactor(elapsed: 600)
        #expect(factor.isFinite)
        #expect(factor > 0)
        #expect(factor < 0.001)
        #expect(factor == SpectrumBallistics.releaseFactor(elapsed: 1))
    }

    // MARK: - The Metal/headless consumer (VisualizerCore.tick)

    @Test("bars released by the core follow the 0.85-per-tick curve after a burst")
    func coreReleasesAfterBurst() {
        let source = MutableSpectrumSource(spectrum: [Float](repeating: 1, count: 128))
        let backend = HeadlessVisualizerBackend(source: source)
        backend.mode = .bars
        backend.tick()
        #expect(backend.lastFrame?.bars.first == 1)

        source.spectrum = [Float](repeating: 0, count: 128)
        for step in 1 ... 4 {
            backend.tick()
            let bar = try? #require(backend.lastFrame?.bars.first)
            let expected = pow(SpectrumBallistics.releaseFactorPerTick, Float(step))
            #expect(abs((bar ?? -1) - expected) < 0.0001)
        }
    }

    @Test("a burst reaches 90% of its level within two core ticks")
    func coreAttackMeetsTheTickBudget() {
        let source = MutableSpectrumSource(spectrum: [Float](repeating: 0, count: 128))
        let backend = HeadlessVisualizerBackend(source: source)
        backend.mode = .bars
        backend.tick()

        source.spectrum = [Float](repeating: 0.8, count: 128)
        backend.tick()
        let afterOne = backend.lastFrame?.bars.first ?? 0
        #expect(afterOne >= 0.8 * 0.95)

        backend.tick()
        let afterTwo = backend.lastFrame?.bars.first ?? 0
        #expect(afterTwo >= 0.8 * 0.9)
    }

    @Test("silence settles every band to the floor")
    func silenceSettlesToFloor() {
        let source = MutableSpectrumSource(spectrum: [Float](repeating: 1, count: 128))
        let backend = HeadlessVisualizerBackend(source: source)
        backend.mode = .bars
        backend.tick()

        source.spectrum = [Float](repeating: 0, count: 128)
        for _ in 0 ..< 240 {
            backend.tick()
        }
        let bars = backend.lastFrame?.bars ?? []
        #expect(bars.count == 64)
        #expect(bars.allSatisfy { $0 < 0.001 })
    }
}
