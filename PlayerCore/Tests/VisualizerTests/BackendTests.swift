import Foundation
import Testing
@testable import Visualizer

@Suite("Visualizer backends")
struct BackendTests {
    /// Thread-safe fake source that counts how often it is pulled.
    final class FakeSpectrumSource: SpectrumSource, @unchecked Sendable {
        private let lock = NSLock()
        private var pulls = 0
        private let spectrum: [Float]
        private let waveform: [Float]

        init(spectrum: [Float], waveform: [Float] = []) {
            self.spectrum = spectrum
            self.waveform = waveform
        }

        var pullCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return pulls
        }

        var bandCount: Int {
            spectrum.count
        }

        func latestSpectrum() -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            pulls += 1
            return spectrum
        }

        func latestWaveform() -> [Float] {
            waveform
        }
    }

    @Test("headless tick pulls the source and builds a frame")
    func headlessTickPulls() {
        let source = FakeSpectrumSource(spectrum: [Float](repeating: 0.4, count: 128))
        let backend = HeadlessVisualizerBackend(source: source)
        backend.mode = .bars
        let stats = backend.tick()
        #expect(source.pullCount == 1)
        #expect(stats.frameCount == 1)
        #expect(stats.lastSpectrumBandCount == 128)
        #expect(stats.mode == .bars)
        #expect(backend.lastFrame?.bars.count == 64)
    }

    @Test("repeated ticks advance the frame counter and keep pulling")
    func headlessTickAdvances() {
        let source = FakeSpectrumSource(spectrum: [Float](repeating: 0.4, count: 128))
        let backend = HeadlessVisualizerBackend(source: source)
        for _ in 0 ..< 5 {
            backend.tick()
        }
        #expect(source.pullCount == 5)
        #expect(backend.stats.frameCount == 5)
    }

    @Test("switching mode is reflected in stats and frame output")
    func modeSwitchUpdatesStats() {
        let source = FakeSpectrumSource(
            spectrum: [Float](repeating: 0.6, count: 128),
            waveform: [Float](repeating: 0.2, count: 64)
        )
        let backend = HeadlessVisualizerBackend(source: source)
        backend.mode = .oscilloscope
        backend.tick()
        #expect(backend.stats.mode == .oscilloscope)
        #expect(backend.lastFrame?.waveform.isEmpty == false)
        #expect(backend.lastFrame?.bars.isEmpty == true)

        backend.mode = .particles
        backend.tick()
        #expect(backend.stats.mode == .particles)
        #expect(backend.lastFrame?.particles.isEmpty == false)
    }

    @Test("start and stop toggle the rendering flag")
    func startStopToggles() {
        let source = FakeSpectrumSource(spectrum: [Float](repeating: 0.4, count: 128))
        let backend = HeadlessVisualizerBackend(source: source)
        #expect(!backend.isRendering)
        backend.start()
        #expect(backend.isRendering)
        backend.stop()
        #expect(!backend.isRendering)
    }
}
