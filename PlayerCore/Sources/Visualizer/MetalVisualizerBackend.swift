import CoreGraphics
import Foundation
#if canImport(MetalKit)
    import MetalKit
#endif

// MARK: - VisualizerCore

/// The GPU-free heart of every backend: it owns the deterministic render clock
/// and turns a pulled spectrum/waveform into a ``VisualizerFrameState``.
///
/// Kept as a value type so both the live Metal backend and the headless test
/// backend share identical frame-building logic with zero duplication.
struct VisualizerCore {
    var mode: VisualizerMode = .bars
    var seed: UInt64 = 0
    var motionEnabled = true
    var config = VisualizerConfig()

    private(set) var time: Float = 0
    private(set) var frameCount: UInt64 = 0
    private(set) var lastSpectrumBandCount = 0

    private let frameInterval: Float = 1.0 / 60.0

    /// This core's OWN envelope. Every on-screen consumer keeps a private
    /// instance — the compact player-bar spectrum runs a second one on its own
    /// 30 fps cadence — so neither can bleed decay state into the other.
    private var ballistics = SpectrumBallistics()

    /// Advances the clock by one frame, PULLS the latest analysis from `source`,
    /// envelopes it, and builds the frame state for the current mode.
    ///
    /// The DSP layer ships raw, unsmoothed bands, so the attack/release lives
    /// here in the consumer (PlayerCore README §5).
    mutating func tick(
        pulling source: SpectrumSource,
        accent: SIMD4<Float>,
        background: SIMD4<Float>
    ) -> VisualizerFrameState {
        time += frameInterval
        frameCount += 1
        let pulled = source.latestSpectrum()
        lastSpectrumBandCount = pulled.count
        let spectrum = ballistics.step(new: pulled, elapsed: Double(frameInterval))
        let inputs = FrameInputs(
            spectrum: spectrum,
            waveform: source.latestWaveform(),
            time: time,
            seed: seed,
            motionEnabled: motionEnabled
        )
        return VisualizerFrameState.make(
            mode: mode,
            inputs: inputs,
            config: config,
            accent: accent,
            background: background
        )
    }

    /// GPU-free snapshot for observation/testing.
    func stats(isRendering: Bool) -> VisualizerRenderStats {
        VisualizerRenderStats(
            frameCount: frameCount,
            lastSpectrumBandCount: lastSpectrumBandCount,
            isRendering: isRendering,
            mode: mode
        )
    }
}

// MARK: - HeadlessVisualizerBackend

/// CPU-only ``VisualizerBackend`` for logic tests and offline use: it ticks the
/// ``VisualizerCore`` and exposes the last built frame, never touching a GPU.
public final class HeadlessVisualizerBackend: VisualizerBackend {
    public var mode: VisualizerMode {
        get { core.mode }
        set { core.mode = newValue }
    }

    public var seed: UInt64 {
        get { core.seed }
        set { core.seed = newValue }
    }

    public private(set) var isRendering = false

    public var stats: VisualizerRenderStats {
        core.stats(isRendering: isRendering)
    }

    /// The most recent frame built by ``tick()`` — for assertions in tests.
    private(set) var lastFrame: VisualizerFrameState?

    private var core = VisualizerCore()
    private let source: SpectrumSource
    private let accent: SIMD4<Float>
    private let background: SIMD4<Float>

    public init(
        source: SpectrumSource,
        seed: UInt64 = 0,
        motionEnabled: Bool = true,
        accent: SIMD4<Float> = SIMD4<Float>(0.2, 0.8, 1.0, 1.0),
        background: SIMD4<Float> = SIMD4<Float>(0.02, 0.02, 0.05, 1.0)
    ) {
        self.source = source
        self.accent = accent
        self.background = background
        core.seed = seed
        core.motionEnabled = motionEnabled
    }

    public func start() {
        isRendering = true
    }

    public func stop() {
        isRendering = false
    }

    public func setSize(_: CGSize) {}

    @discardableResult
    public func tick() -> VisualizerRenderStats {
        lastFrame = core.tick(pulling: source, accent: accent, background: background)
        return stats
    }
}

#if canImport(MetalKit)

    // MARK: - MetalVisualizerBackend

    /// Live `MTKView` backend. Pulls a fresh frame each `draw(in:)` and submits
    /// it through the reusable ``MetalRenderer``.
    ///
    /// `MTKViewDelegate`'s methods are `@MainActor` in the SDK, so only those
    /// witnesses (and ``attach(to:)``) are main-actor isolated; the
    /// ``VisualizerBackend`` requirements stay non-isolated. The view is forced
    /// to `rgba8Unorm` so the live and offline pipelines share one format.
    public final class MetalVisualizerBackend: NSObject, MTKViewDelegate, VisualizerBackend {
        public var mode: VisualizerMode {
            get { core.mode }
            set { core.mode = newValue }
        }

        public var seed: UInt64 {
            get { core.seed }
            set { core.seed = newValue }
        }

        public private(set) var isRendering = false

        public var stats: VisualizerRenderStats {
            core.stats(isRendering: isRendering)
        }

        /// Reduce-motion gate; forwarded into the renderer's uniforms each draw.
        public var motionEnabled = true {
            didSet { core.motionEnabled = motionEnabled }
        }

        private var core = VisualizerCore()
        private let source: SpectrumSource
        private let accent: SIMD4<Float>
        private let background: SIMD4<Float>
        private var renderer: MetalRenderer?
        private var drawableSize = CGSize(width: 1, height: 1)

        public init(
            source: SpectrumSource,
            accent: SIMD4<Float> = SIMD4<Float>(0.2, 0.8, 1.0, 1.0),
            background: SIMD4<Float> = SIMD4<Float>(0.02, 0.02, 0.05, 1.0)
        ) {
            self.source = source
            self.accent = accent
            self.background = background
            super.init()
        }

        /// Binds a GPU renderer to `view` and installs self as its delegate.
        @MainActor
        public func attach(to view: MTKView) {
            guard let device = view.device ?? MTLCreateSystemDefaultDevice() else { return }
            view.device = device
            view.colorPixelFormat = .rgba8Unorm
            view.delegate = self
            drawableSize = view.drawableSize
            renderer = MetalRenderer(device: device, pixelFormat: .rgba8Unorm)
        }

        public func start() {
            isRendering = true
        }

        public func stop() {
            isRendering = false
        }

        public func setSize(_ size: CGSize) {
            drawableSize = size
        }

        @discardableResult
        public func tick() -> VisualizerRenderStats {
            _ = core.tick(pulling: source, accent: accent, background: background)
            return stats
        }

        // MARK: MTKViewDelegate

        @MainActor
        public func mtkView(_: MTKView, drawableSizeWillChange size: CGSize) {
            drawableSize = size
        }

        @MainActor
        public func draw(in view: MTKView) {
            guard isRendering, let renderer else { return }
            guard let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable
            else { return }
            renderer.motionEnabled = motionEnabled
            let frame = core.tick(pulling: source, accent: accent, background: background)
            renderer.renderLive(
                frame,
                mode: core.mode,
                descriptor: descriptor,
                drawable: drawable,
                size: drawableSize
            )
        }
    }

#endif
