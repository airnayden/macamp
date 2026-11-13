// CrossfeedAudioUnit — the in-process v3 audio unit that runs the bs2b crossfeed
// kernel (``CrossfeedKernel``, DSP) inside MacAMP's processing chain.
//
// The kernel is a pure `process(left:right:frameCount:)` routine with no notion of
// a graph. This unit is the only thing that gives it one: it owns a pre-allocated
// pull buffer, hands the kernel two de-interleaved channel pointers, and picks up
// parameter changes through the kernel's own wait-free ``CrossfeedCoefficientBox``
// — so a slider move lands on a block boundary and the render thread never takes a
// lock.
//
// ── WHERE IT SITS ────────────────────────────────────────────────────────────
//
//   graphic EQ ─▶ [parametric] ─▶ [CROSSFEED] ─▶ pan host ─▶ mainMixer
//                                      ▲
//                          ProcessingSlot.crossfeed
//
// The spectrum tap stays on the graphic EQ output (``ProcessingNodeChain/tapHost``),
// which is UPSTREAM of this node. That is deliberate and recorded: the visualizer
// and the stereo metering ring show the signal the user's EQ produced, not the
// headphone-image correction applied after it. Never move the tap here.
//
// ── COMPENSATION GAIN ────────────────────────────────────────────────────────
//
// bs2b's output compensation (`1/(1 − G_h + G)`) is applied INSIDE the kernel's
// output stage. It contributes NOTHING to ``GainComposer`` — crossfeed is unity at
// DC by construction, so there is no summand for the composer to hold.
//
// ── WHY A REGISTERED AUv3 AND NOT A TAP ──────────────────────────────────────
//
// `AVAudioNode` has no public "insert a closure into the signal path" seam; the
// only supported way to run custom DSP between two engine nodes is an audio unit.
// ``AUAudioUnit/registerSubclass(_:as:name:version:)`` registers this class as an
// in-process component, which `AVAudioUnitEffect` can then instantiate
// synchronously — no app extension, no bundle, no out-of-process hop.
//
// This file imports only AVFAudio + AudioToolbox + DSP + Foundation; it MUST NOT
// import AppKit or UIKit (PlayerCore portability invariant).
import AudioToolbox
import AVFAudio
import DSP
import Foundation

/// Failures constructing or preparing the crossfeed render node.
enum CrossfeedAudioUnitError: Error, Equatable {
    /// The standard stereo float format could not be constructed.
    case unconstructibleFormat
    /// The pull buffer could not be allocated for the requested frame count.
    case renderResourcesUnavailable
}

/// The crossfeed stage as an audio unit, plus the `AVAudioNode` that hosts it.
///
/// The two travel together because the chain needs the NODE and the engine seam
/// needs the UNIT (to change the level), and recovering one from the other means
/// a conditional cast at every call site.
struct CrossfeedNode {
    /// The node ``ProcessingNodeChain`` puts in ``ProcessingSlot/crossfeed``.
    let node: AVAudioUnitEffect
    /// The audio unit inside `node`, which owns the kernel.
    let unit: CrossfeedAudioUnit
}

/// An `AUAudioUnit` whose render block crossfeeds a de-interleaved stereo bus.
final class CrossfeedAudioUnit: AUAudioUnit {
    /// Sample rate the busses are born at, before the engine connects them.
    ///
    /// Never used for rendering: ``allocateRenderResources()`` re-derives the
    /// coefficients from the bus's ACTUAL rate every time the graph is prepared,
    /// which is what carries the unit across a format change.
    static let nominalSampleRate: Double = 44100

    /// The kernel this unit drives. Internal so a test can read
    /// ``CrossfeedKernel/activeCoefficients`` after a render.
    let kernel: CrossfeedKernel

    private let renderState = CrossfeedRenderState()
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private let levelLock = NSLock()
    private var storedLevel: CrossfeedLevel = .default

    private lazy var cachedInputBusses = AUAudioUnitBusArray(
        audioUnit: self,
        busType: .input,
        busses: [inputBus]
    )
    private lazy var cachedOutputBusses = AUAudioUnitBusArray(
        audioUnit: self,
        busType: .output,
        busses: [outputBus]
    )

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Self.nominalSampleRate,
            channels: 2
        ) else {
            throw CrossfeedAudioUnitError.unconstructibleFormat
        }
        kernel = CrossfeedKernel(level: .default, sampleRate: Self.nominalSampleRate)
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
    }

    override var inputBusses: AUAudioUnitBusArray {
        cachedInputBusses
    }

    override var outputBusses: AUAudioUnitBusArray {
        cachedOutputBusses
    }

    // MARK: - Parameters

    /// The crossfeed strength currently programmed, already clamped into the
    /// legal bs2b range by ``CrossfeedLevel``'s initialiser.
    var level: CrossfeedLevel {
        levelLock.lock()
        defer { levelLock.unlock() }
        return storedLevel
    }

    /// Programmes `newLevel` and publishes the derived coefficients for the
    /// render thread to adopt on its next block.
    ///
    /// Safe to call while audio is running: the hand-off goes through the
    /// kernel's wait-free coefficient box, so nothing blocks and nothing is
    /// mutated underneath a block in flight.
    func setLevel(_ newLevel: CrossfeedLevel) {
        levelLock.lock()
        storedLevel = newLevel
        levelLock.unlock()
        publishCoefficients()
    }

    // MARK: - Render resources

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        guard renderState.allocate(
            format: inputBus.format,
            maximumFrames: maximumFramesToRender
        ) else {
            super.deallocateRenderResources()
            throw CrossfeedAudioUnitError.renderResourcesUnavailable
        }
        // A graph rebuild is exactly the moment ``CrossfeedKernel/reset()`` is
        // for: nothing is streaming, so discarding the filter tails costs no
        // transient — and re-deriving here is what retunes the one-pole poles
        // when the new connection runs at a different sample rate.
        kernel.reset()
        publishCoefficients()
    }

    override func deallocateRenderResources() {
        renderState.deallocate()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        // Capture the pre-allocated collaborators, never `self`: the block runs on
        // the render thread, where an implicit `self` capture would both add ARC
        // traffic and (under Swift 6) inherit the creating context's isolation.
        let kernel = kernel
        let state = renderState
        return { @Sendable _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            guard let pullList = state.pullList else { return kAudioUnitErr_Uninitialized }
            state.prepare(frameCount: frameCount)
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, pullList)
            guard status == noErr else { return status }
            CrossfeedRenderMix.process(
                kernel: kernel,
                input: pullList,
                output: outputData,
                frameCount: frameCount
            )
            return noErr
        }
    }

    // MARK: - Private

    /// Re-derives the coefficients for the programmed level at the bus's current
    /// sample rate and publishes them.
    private func publishCoefficients() {
        let rate = outputBus.format.sampleRate
        kernel.setLevel(level, sampleRate: rate > 0 ? rate : Self.nominalSampleRate)
    }
}

// MARK: - Registration

extension CrossfeedAudioUnit {
    /// The in-process component identity. `'xfed'` / `'MCAM'`.
    ///
    /// Spelled as hexadecimal `OSType`s rather than derived from strings so the
    /// value is stable, greppable, and needs no run-time parsing.
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x7866_6564,
        componentManufacturer: 0x4D43_414D,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    /// Registers the subclass with AudioComponent exactly once per process.
    ///
    /// A `static let` rather than a guarded flag: Swift initialises it lazily
    /// under `swift_once`, so concurrent first calls cannot double-register.
    private static let registration: Bool = {
        AUAudioUnit.registerSubclass(
            CrossfeedAudioUnit.self,
            as: componentDescription,
            name: "MacAMP Crossfeed",
            version: 1
        )
        var description = componentDescription
        return AudioComponentFindNext(nil, &description) != nil
    }()

    /// Builds a fresh crossfeed node, registering the component on first use.
    ///
    /// Returns `nil` when registration did not take or the instantiated unit is
    /// not ours — both "cannot happen" conditions that must still not crash a
    /// music player. The caller leaves the graph untouched in that case.
    static func makeNode() -> CrossfeedNode? {
        guard registration else { return nil }
        let node = AVAudioUnitEffect(audioComponentDescription: componentDescription)
        guard let unit = node.auAudioUnit as? CrossfeedAudioUnit else { return nil }
        return CrossfeedNode(node: node, unit: unit)
    }
}
