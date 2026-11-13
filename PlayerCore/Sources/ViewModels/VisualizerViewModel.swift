// VisualizerViewModel — the pull-based bridge for the visualizer UI.
//
// It holds the current ``VisualizerMode`` and PULLS the latest analysed frame
// from a ``SpectrumSource`` (the DSP `SpectrumProvider` in production) on the
// UI's own render cadence. Nothing is ever pushed from the audio thread
// (pull-don't-push invariant). Start/stop is gated by view visibility so a
// hidden visualizer does zero work.
//
// `Visualizer` re-exports `DSP` (`@_exported import DSP`) so `SpectrumProvider`
// is reachable here without an explicit `import DSP`.
//
// This file imports only Foundation + Observation + Visualizer; it MUST NOT
// import AppKit or UIKit (PlayerCore portability invariant).
import Foundation
import Observation
import Visualizer

/// Exposes the visualizer mode + the latest pulled spectrum/waveform frame.
@MainActor
@Observable
public final class VisualizerViewModel {
    /// The selected visual mode.
    public private(set) var mode: VisualizerMode
    /// Whether the host view is currently visible.
    public private(set) var isVisible = false
    /// Whether the model is actively pulling frames.
    public private(set) var isActive = false
    /// The latest magnitude spectrum (normalized `0...1`).
    public private(set) var spectrum: [Float] = []
    /// The latest time-domain waveform (normalized `-1...1`).
    public private(set) var waveform: [Float] = []

    @ObservationIgnored private let source: any SpectrumSource

    /// Number of frequency bands the source vends.
    public var bandCount: Int {
        source.bandCount
    }

    /// Creates a visualizer view model over a pull-based `source`.
    public init(source: any SpectrumSource, mode: VisualizerMode = .bars) {
        self.source = source
        self.mode = mode
    }

    /// Drives start/stop from view visibility (the power-aware lifecycle gate).
    public func setVisible(_ visible: Bool) {
        isVisible = visible
        isActive = visible
        if !visible { clearFrame() }
    }

    /// Pulls the latest analysed frame from the ``SpectrumSource``.
    ///
    /// No-op while inactive — nothing is ever pushed from the audio thread; the
    /// UI drives this on its own render cadence.
    public func pull() {
        guard isActive else { return }
        spectrum = source.latestSpectrum()
        waveform = source.latestWaveform()
    }

    /// Returns the latest spectrum directly from the source WITHOUT mutating the
    /// shared ``spectrum`` — so multiple views can each sample independently on
    /// their own render cadence instead of contending for one shared property.
    public func sample() -> [Float] {
        source.latestSpectrum()
    }

    /// Switches the visual mode.
    public func setMode(_ newMode: VisualizerMode) {
        mode = newMode
    }
}

private extension VisualizerViewModel {
    func clearFrame() {
        spectrum = []
        waveform = []
    }
}
