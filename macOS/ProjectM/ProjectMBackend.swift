//
//  ProjectMBackend.swift
//  MacAMP — macOS-only projectM (MilkDrop) marquee visualizer backend (Task 31).
//
//  A `VisualizerBackend` conformer that wraps the ObjC++ bridge
//  (`MacAMPProjectMRenderer`) so the host's `VisualizerPowerController` drives it
//  with the same start/stop/setSize/tick lifecycle as the Metal backend.
//
//  THREADING: libprojectM must be created AND rendered on ONE pinned thread with
//  an OpenGL context current. The `ProjectMVisualizerView` host pins all GL work
//  (prepareGL / feedAndRender / teardownGL) to its `CADisplayLink` callback on
//  the main thread, where the NSOpenGLView context is current. This type is
//  therefore only ever touched on that one thread; it is intentionally NOT
//  `Sendable` (matching the non-Sendable C library) and is never shared across
//  actors. `VisualizerMode` is stored for protocol conformance but ignored for
//  rendering — projectM advances its OWN Milkdrop presets, it has no bars /
//  oscilloscope / particles / aurora notion.
//
#if MACAMP_PROJECTM

import CoreGraphics
import Foundation
import os
import Visualizer

final class ProjectMBackend: VisualizerBackend {
    var mode: VisualizerMode = .bars
    var seed: UInt64 = 0

    private(set) var isRendering = false

    var stats: VisualizerRenderStats {
        VisualizerRenderStats(
            frameCount: frameCount,
            lastSpectrumBandCount: lastWaveformCount,
            isRendering: isRendering,
            mode: mode
        )
    }

    private let source: SpectrumSource
    private let presets: ProjectMPresetLibrary
    private let log = Logger(subsystem: "si.macamp.MacAMP", category: "projectM")

    private var renderer: MacAMPProjectMRenderer?
    private var viewport = CGSize(width: 64, height: 64)
    private var frameCount: UInt64 = 0
    private var lastWaveformCount = 0
    private var presetIndex = 0

    init(source: SpectrumSource, presets: ProjectMPresetLibrary = ProjectMPresetLibrary()) {
        self.source = source
        self.presets = presets
    }

    // MARK: VisualizerBackend lifecycle

    func start() {
        isRendering = true
    }

    func stop() {
        isRendering = false
    }

    func setSize(_ size: CGSize) {
        viewport = size
        renderer?.setViewportWidth(UInt(max(16, size.width)), height: UInt(max(16, size.height)))
    }

    /// Pulls the latest waveform and feeds it to projectM. Called on the GL
    /// thread each frame, immediately before ``renderFrame()``.
    @discardableResult
    func tick() -> VisualizerRenderStats {
        let waveform = source.latestWaveform()
        lastWaveformCount = waveform.count
        if let renderer, !waveform.isEmpty {
            waveform.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    renderer.addPCMFloat(base, count: UInt(buffer.count), stereo: false)
                }
            }
        }
        frameCount &+= 1
        return stats
    }

    // MARK: GL-thread methods (context must be current)

    /// Creates the projectM instance on the current GL context and loads the
    /// first curated preset (idle fallback if the pack is empty / create fails).
    func prepareGL(viewport: CGSize) {
        self.viewport = viewport
        guard let renderer = MacAMPProjectMRenderer(
            viewportWidth: UInt(max(16, viewport.width)),
            height: UInt(max(16, viewport.height))
        ) else {
            log.error("projectm_create failed (no/insufficient GL context); projectM unavailable")
            return
        }
        if !presets.textureSearchPaths.isEmpty {
            renderer.setTextureSearchPaths(presets.textureSearchPaths)
        }
        renderer.loadIdlePreset()
        self.renderer = renderer
        loadPreset(at: presetIndex, smooth: false)
        log.info("projectM \(renderer.libraryVersion, privacy: .public) ready; \(self.presets.count) bundled presets")
    }

    /// Renders one projectM frame into the current GL framebuffer.
    func renderFrame() {
        guard isRendering else {
            return
        }
        renderer?.renderFrame()
    }

    /// Advances to the next curated preset with a smooth blend.
    func advancePreset() {
        guard !presets.isEmpty else {
            return
        }
        presetIndex &+= 1
        loadPreset(at: presetIndex, smooth: true)
    }

    /// Releases the projectM instance (must run on the GL thread).
    func teardownGL() {
        renderer = nil
    }

    private func loadPreset(at index: Int, smooth: Bool) {
        guard let renderer, let path = presets.preset(at: index) else {
            return
        }
        renderer.loadPresetFile(path, smooth: smooth)
    }
}

#endif
