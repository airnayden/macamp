import Foundation
import Testing
@testable import ViewModels
import Visualizer

@MainActor
struct VisualizerViewModelTests {
    @Test func pullUpdatesSpectrumWhenVisible() {
        let source = FakeSpectrumSource(spectrum: [0.1, 0.5, 0.9], waveform: [0.0, -0.5, 0.5])
        let model = VisualizerViewModel(source: source)
        model.setVisible(true)
        #expect(model.isActive)
        model.pull()
        #expect(model.spectrum == [0.1, 0.5, 0.9])
        #expect(model.waveform == [0.0, -0.5, 0.5])
    }

    @Test func hiddenStopsAndClears() {
        let source = FakeSpectrumSource(spectrum: [0.2, 0.4])
        let model = VisualizerViewModel(source: source)
        model.setVisible(true)
        model.pull()
        #expect(!model.spectrum.isEmpty)

        model.setVisible(false)
        #expect(!model.isActive)
        #expect(model.spectrum.isEmpty)
        model.pull()
        #expect(model.spectrum.isEmpty)
    }

    @Test func sampleReadsSourceIndependentlyWithoutMutatingSharedState() {
        let source = FakeSpectrumSource(spectrum: [0.3, 0.6, 0.9])
        let model = VisualizerViewModel(source: source)

        let frame = model.sample()
        #expect(frame == [0.3, 0.6, 0.9])
        #expect(model.spectrum.isEmpty)

        model.setVisible(true)
        model.pull()
        let independent = model.sample()
        #expect(independent == [0.3, 0.6, 0.9])
    }

    @Test func modeSwitches() {
        let model = VisualizerViewModel(source: FakeSpectrumSource(spectrum: [0.1]))
        #expect(model.mode == .bars)
        model.setMode(.aurora)
        #expect(model.mode == .aurora)
    }

    @Test func bandCountFromSource() {
        let model = VisualizerViewModel(source: FakeSpectrumSource(spectrum: [0, 0, 0, 0]))
        #expect(model.bandCount == 4)
    }

    /// The compact player-bar spectrum bypasses `VisualizerCore.tick` entirely —
    /// `InlineSpectrumNSView.tick()` pulls `sample()` and envelopes it with its own
    /// ``SpectrumBallistics``. That view is macOS app-shell code the package suite
    /// cannot host, so this drives the exact PlayerCore seam it runs.
    @Test func inlinePullPathEnvelopesSampleAtThirtyFps() {
        let source = FakeSpectrumSource(spectrum: [1, 1, 1])
        let model = VisualizerViewModel(source: source)
        var ballistics = SpectrumBallistics()
        let interval = 1.0 / 30.0

        #expect(ballistics.step(new: model.sample(), elapsed: interval) == [1, 1, 1])

        let silent = VisualizerViewModel(source: FakeSpectrumSource(spectrum: [0, 0, 0]))
        for step in 1 ... 3 {
            let levels = ballistics.step(new: silent.sample(), elapsed: interval)
            let expected = pow(SpectrumBallistics.releaseFactorPerTick, Float(step * 2))
            #expect(abs(levels[0] - expected) < 0.0001)
        }
    }

    /// The inline view and the Metal visualizer each own an instance, so a burst
    /// rendered by one must not perturb the other's decay.
    @Test func inlineAndMetalEnvelopesStayIndependent() {
        let model = VisualizerViewModel(source: FakeSpectrumSource(spectrum: [1]))
        var inline = SpectrumBallistics()
        var metal = SpectrumBallistics()
        _ = inline.step(new: model.sample(), elapsed: 1.0 / 30.0)
        _ = metal.step(new: model.sample(), elapsed: 1.0 / 60.0)

        let quiet = VisualizerViewModel(source: FakeSpectrumSource(spectrum: [0]))
        for _ in 0 ..< 20 {
            _ = metal.step(new: quiet.sample(), elapsed: 1.0 / 60.0)
        }

        let inlineLevels = inline.step(new: quiet.sample(), elapsed: 1.0 / 30.0)
        let expected = pow(SpectrumBallistics.releaseFactorPerTick, 2)
        #expect(abs(inlineLevels[0] - expected) < 0.0001)
    }
}
