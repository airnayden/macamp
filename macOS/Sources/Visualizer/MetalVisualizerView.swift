// MetalVisualizerView — the SwiftUI host for the Metal visualizer surface.
//
// Wraps an `MTKView` driven by the `Visualizer` module's `MetalVisualizerBackend`
// (Task 19). It PULLS spectra from the `VisualizerViewModel` on the view's own
// render cadence (pull-don't-push: nothing is pushed from the audio thread). A
// `VisualizerPowerController` pauses the GPU whenever the surface is hidden,
// occluded, minimized, or the app is inactive — ≈0% GPU when not visible.
//
// `MetalKit` is imported only under `#if canImport(MetalKit)`; an `#else`
// fallback keeps the shell compiling on platforms without it.
import AppKit
import SwiftUI
import ViewModels
import Visualizer

#if canImport(MetalKit)
    import MetalKit

    // MARK: - VisualizerMTKView

    /// `MTKView` subclass that (1) refreshes the pull-based frame on the main
    /// thread immediately before each delegate draw and (2) reports window
    /// changes so the coordinator can (re)observe occlusion. `MTKView` is
    /// `@MainActor` in the SDK, so these overrides are main-actor isolated and
    /// may invoke the main-actor closures directly.
    final class VisualizerMTKView: MTKView {
        var onWillDraw: (@MainActor () -> Void)?
        var onWindowChange: (@MainActor (NSWindow?) -> Void)?

        override func draw() {
            onWillDraw?()
            super.draw()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    // MARK: - MetalVisualizerView

    /// `NSViewRepresentable` bridging SwiftUI to the `MTKView`-backed renderer.
    struct MetalVisualizerView: NSViewRepresentable {
        let model: VisualizerViewModel
        var mode: VisualizerMode
        var accent: SIMD4<Float>
        var background: SIMD4<Float>
        var appActive: Bool
        var reduceMotion: Bool

        func makeCoordinator() -> Coordinator {
            Coordinator(model: model, accent: accent, background: background)
        }

        func makeNSView(context: Context) -> VisualizerMTKView {
            let view = VisualizerMTKView()
            view.framebufferOnly = true
            view.isPaused = true
            view.enableSetNeedsDisplay = false
            view.clearColor = MTLClearColor(
                red: Double(background.x),
                green: Double(background.y),
                blue: Double(background.z),
                alpha: Double(background.w)
            )
            view.layer?.isOpaque = true
            context.coordinator.backend.attach(to: view)
            context.coordinator.bind(view: view)
            return view
        }

        func updateNSView(_: VisualizerMTKView, context: Context) {
            context.coordinator.sync(appActive: appActive, reduceMotion: reduceMotion, mode: mode)
        }
    }

    // MARK: - Coordinator

    extension MetalVisualizerView {
        /// Owns the backend, the power controller, and the pull bridge, and wires
        /// visibility/app-activation/reduce-motion into start/stop transitions.
        @MainActor
        final class Coordinator: NSObject, VisualizerPowerDelegate {
            let backend: MetalVisualizerBackend
            let power = VisualizerPowerController()
            let source: SnapshotSpectrumSource

            private weak var model: VisualizerViewModel?
            private weak var view: VisualizerMTKView?

            init(model: VisualizerViewModel, accent: SIMD4<Float>, background: SIMD4<Float>) {
                self.model = model
                let bridge = SnapshotSpectrumSource(bandCount: model.bandCount)
                source = bridge
                backend = MetalVisualizerBackend(source: bridge, accent: accent, background: background)
                super.init()
                backend.seed = .random(in: .min ... .max)
                power.delegate = self
            }

            deinit {
                NotificationCenter.default.removeObserver(self)
            }

            /// Installs the per-frame pull hook + window observation on `view`.
            func bind(view: VisualizerMTKView) {
                self.view = view
                view.onWillDraw = { [weak self] in self?.refreshFrame() }
                view.onWindowChange = { [weak self] window in self?.windowChanged(window) }
            }

            /// Mirrors SwiftUI inputs into the backend + power controller.
            func sync(appActive: Bool, reduceMotion: Bool, mode: VisualizerMode) {
                backend.mode = mode
                backend.motionEnabled = !reduceMotion
                power.reduceMotion = reduceMotion
                power.appActive = appActive
                view?.preferredFramesPerSecond = power.targetFrameRate
            }

            private func refreshFrame() {
                guard let model else { return }
                model.pull()
                source.update(spectrum: model.spectrum, waveform: model.waveform)
            }

            private func windowChanged(_ window: NSWindow?) {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.didChangeOcclusionStateNotification,
                    object: nil
                )
                guard let window else {
                    power.isVisible = false
                    return
                }
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(occlusionChanged),
                    name: NSWindow.didChangeOcclusionStateNotification,
                    object: window
                )
                refreshVisibility()
            }

            @objc private nonisolated func occlusionChanged(_: Notification) {
                MainActor.assumeIsolated { self.refreshVisibility() }
            }

            private func refreshVisibility() {
                power.isVisible = view?.window?.occlusionState.contains(.visible) ?? false
            }

            // MARK: VisualizerPowerDelegate

            //
            // The controller is only ever mutated on the main actor, so it fires
            // these on main; `assumeIsolated` bridges the non-isolated witnesses.

            nonisolated func powerControllerDidActivate(_: VisualizerPowerController) {
                MainActor.assumeIsolated {
                    model?.setVisible(true)
                    backend.start()
                    view?.isPaused = false
                }
            }

            nonisolated func powerControllerDidDeactivate(_: VisualizerPowerController) {
                MainActor.assumeIsolated {
                    view?.isPaused = true
                    backend.stop()
                    model?.setVisible(false)
                    source.clear()
                }
            }
        }
    }

#else

    /// Fallback when MetalKit is unavailable: renders the stage background only.
    struct MetalVisualizerView: View {
        let model: VisualizerViewModel
        var mode: VisualizerMode
        var accent: SIMD4<Float>
        var background: SIMD4<Float>
        var appActive: Bool
        var reduceMotion: Bool

        var body: some View {
            Color(
                .sRGB,
                red: Double(background.x),
                green: Double(background.y),
                blue: Double(background.z),
                opacity: Double(background.w)
            )
        }
    }

#endif
