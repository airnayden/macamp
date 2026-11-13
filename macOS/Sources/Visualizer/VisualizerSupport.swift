// VisualizerSupport — backend seam + the pull-based spectrum bridge.
//
// `VisualizerBackendKind` is the host-level selector seam: today only the
// cross-platform Metal backend ships; the macOS-only projectM backend (Task 31)
// slots in here behind `#if MACAMP_PROJECTM` without the host hard-coding a
// single renderer.
//
// `SnapshotSpectrumSource` bridges the `@MainActor` `VisualizerViewModel` to the
// non-isolated, `Sendable` `SpectrumSource` the Metal backend PULLS each frame:
// the host copies the model's latest pulled frame into this snapshot on the
// render cadence (main thread), and the backend reads it from its draw loop.
// Nothing is ever written from the audio thread (pull-don't-push invariant).
import DesignSystem
import Foundation
import os
import Visualizer

// MARK: - VisualizerBackendKind

/// Selectable visualizer rendering backends.
///
/// Only `.metal` ships today. projectM (Task 31) appends itself to ``available``
/// behind `#if MACAMP_PROJECTM`; the host renders whatever this vends, so adding
/// a backend never touches the surrounding UI. Renderer names are technology
/// tokens (`Text(verbatim:)`), never localized.
enum VisualizerBackendKind: String, CaseIterable, Identifiable {
    case metal
    #if MACAMP_PROJECTM
        case projectM
    #endif

    var id: String {
        rawValue
    }

    /// Non-localized technology name shown in the renderer menu.
    var verbatimName: String {
        switch self {
        case .metal: "Metal"
        #if MACAMP_PROJECTM
            case .projectM: "projectM"
        #endif
        }
    }

    /// Backends compiled into this build. `macampMac` defines `MACAMP_PROJECTM`, so
    /// the shipping macOS app vends both; the `#else` is what keeps this file
    /// compiling for a target without the projectM folder (iOS reuses none of it).
    static var available: [VisualizerBackendKind] {
        #if MACAMP_PROJECTM
            [.metal, .projectM]
        #else
            [.metal]
        #endif
    }
}

// MARK: - SnapshotSpectrumSource

/// Thread-safe snapshot bridging the `@MainActor` view model's latest pulled
/// frame to the visualizer backend's non-isolated pull.
///
/// The host writes (`update`) on the main thread immediately before each draw;
/// the backend reads (`latestSpectrum`/`latestWaveform`) from its draw loop. The
/// lock keeps the type `Sendable`-correct even though both touch points are on
/// main in practice. Never written from the audio thread.
final class SnapshotSpectrumSource: SpectrumSource {
    private struct Frame {
        var spectrum: [Float] = []
        var waveform: [Float] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: Frame())
    private let bands: Int

    init(bandCount: Int) {
        bands = max(1, bandCount)
    }

    var bandCount: Int {
        bands
    }

    /// Copies the model's latest pulled frame into the snapshot.
    func update(spectrum: [Float], waveform: [Float]) {
        state.withLock { frame in
            frame.spectrum = spectrum
            frame.waveform = waveform
        }
    }

    /// Drops the retained frame so a paused surface holds no stale energy.
    func clear() {
        state.withLock { frame in
            frame.spectrum = []
            frame.waveform = []
        }
    }

    func latestSpectrum() -> [Float] {
        state.withLock { $0.spectrum }
    }

    func latestWaveform() -> [Float] {
        state.withLock { $0.waveform }
    }
}

// MARK: - Color bridging

extension ColorValue {
    /// The color as a linear `SIMD4<Float>` RGBA the Metal backend ingests.
    var simd4: SIMD4<Float> {
        SIMD4<Float>(Float(red), Float(green), Float(blue), Float(opacity))
    }
}
