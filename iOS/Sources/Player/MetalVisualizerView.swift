// MetalVisualizerView — the SwiftUI host for the iOS Metal visualizer surface.
//
// Wraps an `MTKView` driven by the `Visualizer` module's `MetalVisualizerBackend`
// (Metal modes only — projectM is macOS-only and intentionally absent on iOS). It
// PULLS spectra from the `VisualizerViewModel` on the view's own render cadence
// (pull-don't-push: nothing is pushed from the audio thread). The GPU is paused
// whenever the surface leaves the window or the app is inactive — ≈0% GPU when
// not visible.
//
// `MetalKit` is imported only under `#if canImport(MetalKit)`; an `#else`
// fallback keeps the shell compiling on platforms without it.
import SwiftUI
import ViewModels
import Visualizer

#if canImport(MetalKit)
    import MetalKit
    import UIKit

    // MARK: - VisualizerMTKView

    /// `MTKView` subclass that refreshes the pull-based frame on the main thread
    /// immediately before each delegate draw and reports window changes so the
    /// coordinator can gate the GPU on visibility. `MTKView` is `@MainActor`, so
    /// these overrides are main-actor isolated.
    final class VisualizerMTKView: MTKView {
        var onWillDraw: (@MainActor () -> Void)?
        var onWindowChange: (@MainActor (UIWindow?) -> Void)?

        override func draw() {
            onWillDraw?()
            super.draw()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChange?(window)
        }
    }

    // MARK: - MetalVisualizerView

    /// `UIViewRepresentable` bridging SwiftUI to the `MTKView`-backed renderer.
    struct MetalVisualizerView: UIViewRepresentable {
        let model: VisualizerViewModel
        var mode: VisualizerMode
        var accent: SIMD4<Float>
        var background: SIMD4<Float>
        var appActive: Bool
        var reduceMotion: Bool

        func makeCoordinator() -> Coordinator {
            Coordinator(model: model, accent: accent, background: background)
        }

        func makeUIView(context: Context) -> VisualizerMTKView {
            let view = VisualizerMTKView()
            view.framebufferOnly = true
            view.isPaused = true
            view.enableSetNeedsDisplay = false
            view.isOpaque = true
            view.clearColor = MTLClearColor(
                red: Double(background.x),
                green: Double(background.y),
                blue: Double(background.z),
                alpha: Double(background.w)
            )
            context.coordinator.backend.attach(to: view)
            context.coordinator.bind(view: view)
            return view
        }

        func updateUIView(_: VisualizerMTKView, context: Context) {
            context.coordinator.sync(appActive: appActive, reduceMotion: reduceMotion, mode: mode)
        }
    }

    // MARK: - Coordinator

    extension MetalVisualizerView {
        /// Owns the backend + the pull bridge and gates start/stop on visibility +
        /// app activation.
        @MainActor
        final class Coordinator {
            let backend: MetalVisualizerBackend
            let source: SnapshotSpectrumSource

            private weak var model: VisualizerViewModel?
            private weak var view: VisualizerMTKView?
            private var isVisible = false
            private var appActive = false

            init(model: VisualizerViewModel, accent: SIMD4<Float>, background: SIMD4<Float>) {
                self.model = model
                let bridge = SnapshotSpectrumSource(bandCount: model.bandCount)
                source = bridge
                backend = MetalVisualizerBackend(source: bridge, accent: accent, background: background)
                backend.seed = .random(in: .min ... .max)
            }

            /// Installs the per-frame pull hook + window observation on `view`.
            func bind(view: VisualizerMTKView) {
                self.view = view
                view.onWillDraw = { [weak self] in self?.refreshFrame() }
                view.onWindowChange = { [weak self] window in self?.windowChanged(window) }
            }

            /// Mirrors SwiftUI inputs into the backend + drives the run state.
            func sync(appActive: Bool, reduceMotion: Bool, mode: VisualizerMode) {
                self.appActive = appActive
                backend.mode = mode
                backend.motionEnabled = !reduceMotion
                view?.preferredFramesPerSecond = reduceMotion ? 30 : 60
                updateRunState()
            }

            private func refreshFrame() {
                guard let model else { return }
                model.pull()
                source.update(spectrum: model.spectrum, waveform: model.waveform)
            }

            private func windowChanged(_ window: UIWindow?) {
                isVisible = window != nil
                updateRunState()
            }

            private func updateRunState() {
                if isVisible, appActive {
                    model?.setVisible(true)
                    backend.start()
                    view?.isPaused = false
                } else {
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
