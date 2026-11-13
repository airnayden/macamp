// SFBPlaybackEngine — the production ``PlaybackEngine`` (Option A).
//
// Per Spikes/ADR-audio-engine.md, SFBAudioEngine 0.12.1 ships NO public
// `SFBAudioPlayerNode`, so the high-level `AudioPlayer` (`SFBAudioPlayer`) OWNS
// the `AVAudioEngine`. We insert a ten-band `AVAudioUnitEQ` and a dedicated pan
// host between the player's source node and its main mixer via
// `modifyProcessingGraph` — `source → EQ → panHost → mainMixer` — and
// re-establish that wiring on every format change through the
// `reconfigureProcessingGraph` delegate (always using the PASSED format). The pan
// host exists solely because `AVAudioMixing/pan` is honoured only on a node whose
// output feeds an `AVAudioMixerNode`. A POST-EQ, PRE-pan tap on the EQ output
// feeds the DSP ``SpectrumProvider`` (memcpy only — see the audio-thread
// invariant note on `ingest`). ReplayGain is applied as the EQ's `globalGain`
// in `renderingWillStart`. Gapless continuation uses `enqueue`. Crossfade is
// deliberately NOT implemented (deferred — `SFBAudioPlayerNode` is absent).
//
// The audio engine's lifecycle belongs to `AudioPlayer`: we NEVER call
// `engine.start()`/`stop()` directly (the player asserts on external mutation).
//
// `@preconcurrency import SFBAudioEngine` keeps SFB's not-yet-Sendable types from
// tripping Swift 6 strict concurrency. SFB's own decode protocol is also named
// `PCMDecoding`, so it is referenced fully qualified as `SFBAudioEngine.PCMDecoding`.
// DSP is re-exported so the visualizer data path (the ``SpectrumProvider``) is
// part of the engine module's surface.
//
// This file imports only AVFAudio + DSP + Decoding + Foundation + SFBAudioEngine;
// it MUST NOT import AppKit or UIKit (PlayerCore portability invariant).
import AVFAudio
import Decoding
@_exported import DSP
import Foundation
@preconcurrency import SFBAudioEngine

/// The production ``PlaybackEngine`` backed by `SFBAudioPlayer` (Option A).
@MainActor
public final class SFBPlaybackEngine: PlaybackEngine {
    public private(set) var state: PlaybackState = .idle {
        didSet {
            guard oldValue != state else { return }
            stateDidChange?(state)
        }
    }

    public var stateDidChange: ((PlaybackState) -> Void)?
    public var onEndOfAudio: (() -> Void)?
    public var onRenderingComplete: (() -> Void)?

    public var currentTime: TimeInterval {
        player.currentTime ?? 0
    }

    public var duration: TimeInterval {
        player.totalTime ?? 0
    }

    public var volume: Float {
        #if os(macOS)
            player.volume
        #else
            shadowVolume
        #endif
    }

    public func setVolume(_ newVolume: Float) {
        let clamped = min(max(newVolume, 0), 1)
        #if os(macOS)
            try? player.setVolume(clamped)
        #else
            shadowVolume = clamped
        #endif
    }

    private var storedBalance: Float = 0

    public var balance: Float {
        storedBalance
    }

    public func setBalance(_ newBalance: Float) {
        storedBalance = min(max(newBalance, -1), 1)
        balanceBox.value = storedBalance
        panNode.pan = storedBalance
    }

    #if !os(macOS)
        /// iOS has no per-player SFB volume API (output level is system-controlled via
        /// AVAudioSession), so mirror the requested level here to keep the protocol's
        /// getter/setter consistent without driving a non-existent player control.
        private var shadowVolume: Float = 1
    #endif
    /// Internal rather than `private` so the output-routing surface can live in
    /// its own file — this file is close enough to SwiftLint's 400-line ceiling
    /// that appending to it is no longer free. Nothing outside the engine's own
    /// extensions may drive the player: its lifecycle belongs to SFB.
    let player = AudioPlayer()
    private let equalizer = makeEQUnit()
    /// Dedicated balance host. `AVAudioMixing/pan` only takes effect on a node
    /// whose output feeds an `AVAudioMixerNode`, and `mainMixerNode` feeds the
    /// OUTPUT node — so its own `pan` is silently inert. This mixer is inserted
    /// between the EQ and the main mixer purely so `pan` is honoured.
    private let panNode = AVAudioMixerNode()
    public let spectrumProvider = SpectrumProvider()
    private let decoderProvider: any DecoderProviding
    private let globalGainBox = GlobalGainBox()
    private let balanceBox = BalanceBox()
    /// The ordered `EQ → …optional nodes… → panHost` description both this engine
    /// and the reconfigure delegate wire the graph from.
    ///
    /// Internal for the same reason as ``player``: the routing extension reads its
    /// tap host to report the live connection format.
    lazy var processingChain = ProcessingNodeChain(
        equalizer: equalizer,
        balanceHost: panNode,
        balanceBox: balanceBox,
        spectrumProvider: spectrumProvider
    )

    private lazy var delegateProxy = PlayerDelegateProxy(
        chain: processingChain,
        globalGainBox: globalGainBox
    )

    public init(decoderProvider: any DecoderProviding = SFBDecoderProvider()) {
        self.decoderProvider = decoderProvider
        player.delegate = delegateProxy
        wireEndOfAudioCallbacks()
        rewireProcessingChain()
    }

    // MARK: - Loading

    public func load(_ url: URL) throws {
        try load(source: DecoderSource(url: url))
    }

    public func enqueue(_ url: URL) throws {
        try enqueue(source: DecoderSource(url: url))
    }

    public func load(source: DecoderSource) throws {
        try enqueueResolved(source, immediate: true)
        state = .stopped
    }

    public func enqueue(source: DecoderSource) throws {
        try enqueueResolved(source, immediate: false)
    }

    /// Resolves `source` to a decoder and hands THAT OBJECT to the player,
    /// mapping any residual SFB failure to a typed ``DecodingError`` so the
    /// engine never leaks a raw error.
    ///
    /// The object hand-off is the whole point: `player.enqueue(url:immediate:)`
    /// makes the player re-open the file through SFB's PCM-only `AudioDecoder`
    /// factory, so a DSD file (which needs the DSD→PCM stage) or a CUE region
    /// (which needs an `AudioRegionDecoder` wrapper) could never reach the graph
    /// no matter what ``DecoderProviding`` produced. A provider whose decoders
    /// carry no SFB backend (the hermetic ``FakeDecoderProvider``) still falls
    /// back to the URL path — its source was already proven whole-stream by
    /// ``DecoderProviding/makeDecoder(for:)``, which rejects a range it cannot
    /// honour.
    private func enqueueResolved(_ source: DecoderSource, immediate: Bool) throws {
        let decoder = try decoderProvider.makeDecoder(for: source)
        do {
            if let backed = decoder as? any SFBBackedDecoding {
                try player.enqueue(backed.sfbBackend, immediate: immediate)
            } else {
                try player.enqueue(source.url, immediate: immediate)
            }
        } catch {
            throw DecodingError.corruptedFile(url: source.url, reason: error.localizedDescription)
        }
    }

    // MARK: - Transport

    public func play() {
        guard state != .idle else { return }
        if state == .paused {
            _ = player.resume()
        } else {
            do {
                try player.play()
            } catch {
                return
            }
        }
        state = .playing
    }

    public func pause() {
        guard state == .playing else { return }
        _ = player.pause()
        state = .paused
    }

    public func stop() {
        player.stop()
        state = .stopped
    }

    public func seek(to time: TimeInterval) {
        _ = player.seek(time: time)
    }

    /// Swaps the current source to `url` in place (mid-song variant swap), then
    /// re-seeks and either resumes playback or stays paused.
    ///
    /// `load` re-enqueues immediately, so on a format change SFB re-fires
    /// `reconfigureProcessingGraph` (re-wiring `EQ → panHost → mainMixer`,
    /// re-applying the balance pan, and re-installing the tap). The ten-band EQ
    /// is a RETAINED `AVAudioUnitEQ`, so its band gains persist across the
    /// reconnection; the ReplayGain global gain is restored from
    /// ``globalGainBox`` in `renderingWillStart`; and balance is re-applied from
    /// ``balanceBox`` — so band gains, global gain, and balance all survive the
    /// swap. Because `load` validates the decoder before mutating anything, a
    /// decode failure leaves the prior position, state, and EQ untouched.
    public func reload(url: URL, at time: TimeInterval, resumePlaying: Bool) throws {
        try reload(source: DecoderSource(url: url), at: time, resumePlaying: resumePlaying)
    }

    public func reload(source: DecoderSource, at time: TimeInterval, resumePlaying: Bool) throws {
        try load(source: source)
        seek(to: time)
        if resumePlaying {
            play()
        } else {
            _ = player.pause()
            state = .paused
        }
    }

    // MARK: - Equaliser

    public func setBandGain(_ index: Int, dB decibels: Float) {
        guard equalizer.bands.indices.contains(index) else { return }
        equalizer.bands[index].gain = decibels
    }

    public func setGlobalGain(_ decibels: Float) {
        let clamped = clampGlobalGain(decibels)
        globalGainBox.value = clamped
        equalizer.globalGain = clamped
    }

    /// The latest 128-band spectrum, pulled on demand from the POST-EQ tap. Safe
    /// to call at any time; returns a flat (zeroed) spectrum when no audio has
    /// flowed yet.
    public func latestSpectrum() -> [Float] {
        spectrumProvider.latestSpectrum()
    }

    // MARK: - End-of-audio wiring

    private func wireEndOfAudioCallbacks() {
        delegateProxy.onRenderingCompleteCallback = { [weak self] in
            Task { @MainActor in self?.onEndOfAudio?() }
        }
        delegateProxy.onRenderingWillCompleteCallback = { [weak self] in
            Task { @MainActor in self?.onRenderingComplete?() }
        }
    }

    // MARK: - Graph wiring

    /// Builds — or rebuilds — the processing chain between the player's source
    /// node and its main mixer, and re-installs the spectrum tap.
    ///
    /// Run once at construction, and again whenever a chain slot changes. SFB's
    /// `reconfigureProcessingGraph` delegate runs the SAME traversal on every
    /// format change, so the chain is described once, in ``ProcessingNodeChain``.
    func rewireProcessingChain() {
        let chain = processingChain
        let player = player
        player.modifyProcessingGraph { engine in
            let format = Self.connectionFormat(for: player.sourceNode.outputFormat(forBus: 0))
            chain.wire(
                into: engine,
                from: player.sourceNode,
                terminatingAt: player.mainMixerNode,
                format: format
            )
        }
    }

    /// The source format when valid, else the standby 44.1 kHz stereo float
    /// format (the source node reports 0 channels before the first decoder is
    /// enqueued).
    ///
    /// The sample rate is checked alongside the channel count because this also
    /// normalises what ``currentConnectionFormat`` reports: a node queried before
    /// it is connected can answer with a placeholder that would otherwise be
    /// published to the signal-path readout as a 0 Hz graph.
    static func connectionFormat(for sourceFormat: AVAudioFormat) -> AVAudioFormat {
        guard sourceFormat.channelCount > 0, sourceFormat.sampleRate > 0 else {
            return PlaybackEngineFormats.standby
        }
        return sourceFormat
    }
}

// MARK: - Test hooks

extension SFBPlaybackEngine {
    /// `true` once the EQ node is attached to the player's engine.
    var isEQInstalled: Bool {
        equalizer.engine != nil
    }

    /// The clamped global gain currently stored for `renderingWillStart`.
    var storedGlobalGain: Float {
        globalGainBox.value
    }

    /// The live per-band EQ gains (dB) — lets tests assert they survive a reload.
    var bandGains: [Float] {
        equalizer.bands.map(\.gain)
    }

    /// The graph's terminal mixer. Lets tests attach a temporary assertion tap to
    /// measure what actually reaches the output, and assert that this node's own
    /// `pan` stays at its inert default (see ``balanceHostPan``).
    var outputMixerNode: AVAudioMixerNode {
        player.mainMixerNode
    }

    /// The pan actually programmed on the balance host — the node whose output
    /// feeds the main mixer, and therefore the only place `pan` has any effect.
    var balanceHostPan: Float {
        panNode.pan
    }

    /// `true` once the balance host is attached to the player's engine.
    var isBalanceHostInstalled: Bool {
        panNode.engine != nil
    }

    /// Every node registered in the processing chain, in signal-flow order —
    /// head first, pan host last.
    ///
    /// The seam for pluggable nodes: a slot filled through
    /// ``ProcessingNodeChain/setOptionalNode(_:for:)`` shows up here, so a test
    /// can assert its node survives a format change.
    var chainNodes: [AVAudioNode] {
        processingChain.orderedNodes
    }

    /// `true` when every registered chain node is attached to the player's
    /// engine — the property a format-change test asserts.
    var isChainFullyAttached: Bool {
        processingChain.orderedNodes.allSatisfy { $0.engine != nil }
    }

    /// The chain itself, so a test can fill or clear an optional slot.
    var processingChainForTesting: ProcessingNodeChain {
        processingChain
    }
}
