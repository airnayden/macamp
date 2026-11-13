import CoreGraphics
import Foundation

// MARK: - VisualizerMode

/// The visual style rendered by a ``VisualizerBackend``.
///
/// All modes are cross-platform (Metal). The macOS-only projectM backend is a
/// separate product (Task 31) and is intentionally NOT represented here.
public enum VisualizerMode: String, CaseIterable, Sendable, Codable {
    /// Classic frequency-domain spectrum bars (128 bands → N bars).
    case bars
    /// Time-domain oscilloscope / waveform line.
    case oscilloscope
    /// Spectrum-reactive particle field (seeded, reproducible).
    case particles
    /// Designed "art" mode: a flowing aurora driven by spectral energy.
    case aurora

    /// Stable key for localization lookups. The host app maps this to a
    /// localized, user-facing string; the raw value is the fallback.
    public var localizationKey: String {
        "visualizer.mode.\(rawValue)"
    }

    /// Non-localized fallback label (English). Hosts SHOULD localize via
    /// ``localizationKey``.
    public var fallbackDisplayName: String {
        switch self {
        case .bars: "Spectrum Bars"
        case .oscilloscope: "Oscilloscope"
        case .particles: "Particles"
        case .aurora: "Aurora"
        }
    }
}

// MARK: - SpectrumSource

/// A **pull-based** source of audio-analysis data.
///
/// The visualizer PULLS the latest analyzed frame on each render tick. Data is
/// NEVER pushed from the audio thread into the visualizer — this keeps the
/// realtime audio thread free of UI/GPU work and decouples render cadence from
/// audio callback cadence.
///
/// Conformers MUST be safe to call from the render thread (a non-main thread).
/// The DSP `SpectrumProvider` (Task 10) is the production conformer; tests
/// supply a fake.
public protocol SpectrumSource: AnyObject, Sendable {
    /// Number of frequency bands returned by ``latestSpectrum()``.
    var bandCount: Int { get }

    /// Latest magnitude spectrum, normalized to `0...1`, `bandCount` entries.
    ///
    /// Returns an empty array (or all-zeros) when no audio has been analyzed.
    func latestSpectrum() -> [Float]

    /// Latest time-domain waveform samples, normalized to `-1...1`.
    ///
    /// Returns an empty array when no audio has been analyzed.
    func latestWaveform() -> [Float]
}

public extension SpectrumSource {
    var bandCount: Int {
        128
    }

    func latestWaveform() -> [Float] {
        []
    }
}

// MARK: - VisualizerRenderStats

/// Lightweight, GPU-free snapshot of backend state, used by tests and the host
/// UI to observe the render loop without touching Metal.
public struct VisualizerRenderStats: Sendable, Equatable {
    public var frameCount: UInt64
    public var lastSpectrumBandCount: Int
    public var isRendering: Bool
    public var mode: VisualizerMode

    public init(
        frameCount: UInt64 = 0,
        lastSpectrumBandCount: Int = 0,
        isRendering: Bool = false,
        mode: VisualizerMode = .bars
    ) {
        self.frameCount = frameCount
        self.lastSpectrumBandCount = lastSpectrumBandCount
        self.isRendering = isRendering
        self.mode = mode
    }
}

// MARK: - VisualizerBackend

/// Abstraction over a concrete visualizer renderer.
///
/// Lifecycle contract:
/// - ``start()`` / ``stop()`` gate the render loop. The power controller (see
///   ``VisualizerPowerController``) drives these based on visibility, app
///   activation state, and reduce-motion.
/// - ``setSize(_:)`` updates the drawable size on layout changes.
/// - The backend PULLS from its ``SpectrumSource`` each frame; nothing is
///   pushed into it.
///
/// Determinism: ``seed`` controls all pseudo-random behavior (particles, art
/// mode) so a given (`seed`, `mode`, spectrum) tuple renders reproducibly. This
/// enables golden-image testing.
public protocol VisualizerBackend: AnyObject {
    /// The currently selected visual mode. Switching MUST NOT leak GPU
    /// resources from the previous mode.
    var mode: VisualizerMode { get set }

    /// Seed for deterministic pseudo-random effects.
    var seed: UInt64 { get set }

    /// `true` while the render loop is actively producing frames.
    var isRendering: Bool { get }

    /// GPU-free state snapshot for observation/testing.
    var stats: VisualizerRenderStats { get }

    /// Begin the render loop (idempotent). Pulls spectra each tick.
    func start()

    /// Suspend the render loop and release per-frame transient state
    /// (idempotent). Persistent GPU resources MAY be retained for fast resume.
    func stop()

    /// Update the drawable size (points or pixels per the platform view).
    func setSize(_ size: CGSize)

    /// Advance and produce exactly one frame's worth of CPU-side render state
    /// by pulling the latest spectrum/waveform from the ``SpectrumSource``.
    ///
    /// Separated from GPU submission so logic (band→bar mapping, particle
    /// integration, frame counting) is testable WITHOUT a Metal device.
    @discardableResult
    func tick() -> VisualizerRenderStats
}
