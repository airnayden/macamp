//
//  ProjectMVisualizerView.swift
//  MacAMP — macOS-only projectM (MilkDrop) marquee visualizer backend (Task 31).
//
//  SwiftUI host for the projectM surface: an `NSOpenGLView` (Core Profile 3.2 —
//  macOS caps OpenGL at 4.1) driven by a main-thread `CADisplayLink`. It PULLS
//  the latest waveform from the `VisualizerViewModel` each tick and feeds it to
//  projectM via the ObjC++ bridge (pull-don't-push: nothing is pushed from the
//  audio thread). A `VisualizerPowerController` pauses the display link + GPU
//  whenever the surface is hidden, occluded, or the app is inactive — ≈0% GPU
//  when not visible, identical to the Metal host.
//
//  projectM requires its instance be created AND rendered on ONE pinned thread
//  with a current GL context; both happen here, on the main thread, in the
//  display-link callback where the NSOpenGLView context is current.
//
#if MACAMP_PROJECTM

import AppKit
import OpenGL.GL3
import QuartzCore
import SwiftUI
import ViewModels
import Visualizer

// MARK: - ProjectMVisualizerView

struct ProjectMVisualizerView: NSViewRepresentable {
    let model: VisualizerViewModel
    var appActive: Bool
    var reduceMotion: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> ProjectMGLView {
        let format = ProjectMGLView.coreProfilePixelFormat()
        let view = ProjectMGLView(frame: .zero, pixelFormat: format) ?? ProjectMGLView(frame: .zero)
        view.wantsBestResolutionOpenGLSurface = true
        context.coordinator.bind(view: view)
        return view
    }

    func updateNSView(_: ProjectMGLView, context: Context) {
        context.coordinator.sync(appActive: appActive, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_: ProjectMGLView, coordinator: Coordinator) {
        coordinator.teardown()
    }
}

// MARK: - ProjectMGLView

/// `NSOpenGLView` subclass that forwards lifecycle callbacks to its coordinator.
/// The default framebuffer (FBO 0) of this view IS the on-screen drawable, which
/// is what the (patched) projectM composites its final frame into.
final class ProjectMGLView: NSOpenGLView {
    var onPrepare: (() -> Void)?
    var onReshape: ((CGSize) -> Void)?
    var onWindowChange: ((NSWindow?) -> Void)?

    static func coreProfilePixelFormat() -> NSOpenGLPixelFormat {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFADepthSize), 24,
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAAccelerated),
            0,
        ]
        return NSOpenGLPixelFormat(attributes: attributes) ?? NSOpenGLPixelFormat()
    }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        var swap: GLint = 1
        openGLContext?.setValues(&swap, for: .swapInterval)
        onPrepare?()
    }

    override func reshape() {
        super.reshape()
        onReshape?(convertToBacking(bounds).size)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

// MARK: - Coordinator

extension ProjectMVisualizerView {
    @MainActor
    final class Coordinator: NSObject, VisualizerPowerDelegate {
        private let backend: ProjectMBackend
        private let power = VisualizerPowerController()
        private let source: SnapshotSpectrumSource

        private weak var model: VisualizerViewModel?
        private weak var view: ProjectMGLView?
        private var displayLink: CADisplayLink?
        private var prepared = false

        init(model: VisualizerViewModel) {
            self.model = model
            let bridge = SnapshotSpectrumSource(bandCount: model.bandCount)
            source = bridge
            backend = ProjectMBackend(source: bridge)
            super.init()
            backend.seed = .random(in: .min ... .max)
            power.delegate = self
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func bind(view: ProjectMGLView) {
            self.view = view
            view.onPrepare = { [weak self] in self?.prepareGL() }
            view.onReshape = { [weak self] size in self?.backend.setSize(size) }
            view.onWindowChange = { [weak self] window in self?.windowChanged(window) }
        }

        func sync(appActive: Bool, reduceMotion: Bool) {
            power.reduceMotion = reduceMotion
            power.appActive = appActive
        }

        func teardown() {
            stopDisplayLink()
            withCurrentContext { backend.teardownGL() }
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: GL setup + render

        private func prepareGL() {
            guard let view, let context = view.openGLContext else {
                return
            }
            context.makeCurrentContext()
            backend.prepareGL(viewport: view.convertToBacking(view.bounds).size)
            prepared = true
        }

        private func startDisplayLink() {
            guard displayLink == nil, let view else {
                return
            }
            let link = view.displayLink(target: self, selector: #selector(renderTick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func renderTick() {
            guard prepared, backend.isRendering, let model else {
                return
            }
            withCurrentContext {
                model.pull()
                source.update(spectrum: model.spectrum, waveform: model.waveform)
                backend.tick()
                let size = view?.convertToBacking(view?.bounds ?? .zero).size ?? .zero
                glViewport(0, 0, GLsizei(max(1, size.width)), GLsizei(max(1, size.height)))
                glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
                backend.renderFrame()
                view?.openGLContext?.flushBuffer()
            }
        }

        private func withCurrentContext(_ body: () -> Void) {
            guard let context = view?.openGLContext, let cgl = context.cglContextObj else {
                return
            }
            context.makeCurrentContext()
            CGLLockContext(cgl)
            body()
            CGLUnlockContext(cgl)
        }

        // MARK: Visibility / occlusion

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

        nonisolated func powerControllerDidActivate(_: VisualizerPowerController) {
            MainActor.assumeIsolated {
                model?.setVisible(true)
                backend.start()
                startDisplayLink()
            }
        }

        nonisolated func powerControllerDidDeactivate(_: VisualizerPowerController) {
            MainActor.assumeIsolated {
                stopDisplayLink()
                backend.stop()
                model?.setVisible(false)
                source.clear()
            }
        }
    }
}

#endif
