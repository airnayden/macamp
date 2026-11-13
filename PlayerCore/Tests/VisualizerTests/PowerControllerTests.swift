import Testing
@testable import Visualizer

@Suite("Visualizer power controller")
struct PowerControllerTests {
    /// Records activation transitions for assertions.
    final class SpyDelegate: VisualizerPowerDelegate {
        private(set) var activations = 0
        private(set) var deactivations = 0

        func powerControllerDidActivate(_: VisualizerPowerController) {
            activations += 1
        }

        func powerControllerDidDeactivate(_: VisualizerPowerController) {
            deactivations += 1
        }
    }

    @Test("activates only when visible and app-active")
    func activatesWhenVisibleAndActive() {
        let controller = VisualizerPowerController()
        let spy = SpyDelegate()
        controller.delegate = spy
        controller.appActive = true
        controller.isVisible = true
        #expect(controller.shouldRender)
        #expect(spy.activations == 1)
        #expect(spy.deactivations == 0)
    }

    @Test("deactivates when the view is hidden")
    func deactivatesWhenHidden() {
        let controller = VisualizerPowerController()
        let spy = SpyDelegate()
        controller.delegate = spy
        controller.isVisible = true
        controller.isVisible = false
        #expect(!controller.shouldRender)
        #expect(spy.activations == 1)
        #expect(spy.deactivations == 1)
    }

    @Test("never renders when the app is backgrounded")
    func deactivatesWhenBackgrounded() {
        let controller = VisualizerPowerController()
        let spy = SpyDelegate()
        controller.delegate = spy
        controller.isVisible = true
        controller.appActive = false
        #expect(!controller.shouldRender)
        #expect(spy.deactivations == 1)
    }

    @Test("menu-bar-only mode suppresses rendering")
    func menuBarOnlySuppresses() {
        let controller = VisualizerPowerController()
        let spy = SpyDelegate()
        controller.delegate = spy
        controller.isVisible = true
        controller.menuBarOnly = true
        #expect(!controller.shouldRender)
        #expect(spy.deactivations == 1)
    }

    @Test("reduce-motion lowers the target frame rate to 30")
    func reduceMotionFrameRate() {
        let controller = VisualizerPowerController()
        #expect(controller.targetFrameRate == 60)
        controller.reduceMotion = true
        #expect(controller.targetFrameRate == 30)
    }

    @Test("no redundant transitions fire on no-op updates")
    func noRedundantTransitions() {
        let controller = VisualizerPowerController()
        let spy = SpyDelegate()
        controller.delegate = spy
        controller.isVisible = true
        controller.appActive = true
        #expect(spy.activations == 1)
        #expect(spy.deactivations == 0)
    }
}
