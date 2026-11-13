// ProcessingNodeChain — the ordered description of the processing nodes MacAMP
// inserts between the player's source node and its main mixer, plus the single
// routine that wires them.
//
// The wiring used to be spelled out TWICE: once in `SFBPlaybackEngine` when the
// graph is first built, and once in the delegate's
// `audioPlayer(_:reconfigureProcessingGraph:with:)` on every format change. A
// node added to one path and forgotten in the other would silently vanish the
// first time a track changed sample rate. Both paths now traverse THIS chain, so
// a slot is described once and honoured everywhere.
//
// The chain is read from SFB's unspecified notification thread (the reconfigure
// delegate) and mutated from the main actor (the engine's optional-node seams),
// so every access goes through an `NSLock` — the same relay discipline as
// ``GlobalGainBox`` / ``BalanceBox``. It is NEVER touched from the render thread:
// wiring runs only inside `modifyProcessingGraph` / `reconfigureProcessingGraph`,
// both graph-safe contexts, so the audio-thread invariants (no allocation, no
// locks, no ARC) do not bind here.
//
// This file imports only AVFAudio + DSP + Foundation; it MUST NOT import AppKit
// or UIKit (PlayerCore portability invariant).
import AVFAudio
import DSP
import Foundation

/// The processing slots between the player's source node and its main mixer, in
/// signal-flow order — the `rawValue` IS the order.
///
/// ``equalizer`` and ``balance`` are PERMANENT. The graphic EQ is the chain head
/// (SFB connects its source to it) and also the tap host; the pan host is the
/// chain tail because `AVAudioMixing/pan` is honoured only on a node whose output
/// feeds an `AVAudioMixerNode`. The two slots in between are optional and start
/// empty.
enum ProcessingSlot: Int, CaseIterable {
    /// The ten-band graphic `AVAudioUnitEQ`. Permanent head; also the tap host.
    case equalizer
    /// The parametric `AVAudioUnitEQ`, when the user has one configured.
    case parametric
    /// The crossfeed render node, when crossfeed is enabled.
    case crossfeed
    /// The dedicated pan host. Permanent tail.
    case balance

    /// `true` for the slots a caller may fill or clear at runtime.
    ///
    /// The permanent head and tail are set once at construction: re-heading the
    /// chain would orphan the spectrum tap, and re-tailing it would move `pan`
    /// onto a node where it is silently inert.
    var isOptional: Bool {
        switch self {
        case .parametric, .crossfeed: true
        case .equalizer, .balance: false
        }
    }
}

/// The ordered processing chain `source → EQ → …optional nodes… → panHost →
/// mainMixer`, and the one routine that (re)establishes it.
///
/// `@unchecked Sendable` is sound because every access to the mutable slot table
/// goes through ``lock``; the permanent nodes are immutable references handed in
/// at construction.
final class ProcessingNodeChain: @unchecked Sendable {
    /// The permanent chain head — the node whatever feeds the chain connects to.
    let equalizer: AVAudioUnitEQ

    /// The permanent chain tail, and the only node whose `pan` has any effect.
    let balanceHost: AVAudioMixerNode

    /// The balance relay a graph rebuild reads to restore the user's pan on the
    /// fresh connection.
    let balanceBox: BalanceBox

    private let spectrumProvider: SpectrumProvider
    private let lock = NSLock()
    private var nodes: [ProcessingSlot: AVAudioNode]

    init(
        equalizer: AVAudioUnitEQ,
        balanceHost: AVAudioMixerNode,
        balanceBox: BalanceBox,
        spectrumProvider: SpectrumProvider
    ) {
        self.equalizer = equalizer
        self.balanceHost = balanceHost
        self.balanceBox = balanceBox
        self.spectrumProvider = spectrumProvider
        nodes = [.equalizer: equalizer, .balance: balanceHost]
    }

    /// The node the spectrum tap is installed on: the graphic EQ output, which is
    /// POST-EQ and PRE-pan.
    ///
    /// Deliberately NOT the chain tail — the tap reads channel 0 only, so a
    /// post-pan tap would collapse the visualizer to silence at full-right
    /// balance.
    var tapHost: AVAudioNode {
        equalizer
    }

    /// Every registered node in signal-flow order, head first. Never empty: the
    /// equalizer and the pan host are permanent.
    var orderedNodes: [AVAudioNode] {
        lock.lock()
        defer { lock.unlock() }
        return ProcessingSlot.allCases.compactMap { nodes[$0] }
    }

    /// The node currently occupying `slot`, or `nil` when the slot is empty.
    ///
    /// The read half of ``setOptionalNode(_:for:)``, and the reason an engine
    /// seam needs no stored property of its own: the chain already retains the
    /// node it was handed, so a seam can install once and find its node again on
    /// the next call instead of the engine holding a second reference that could
    /// drift out of step with the slot.
    func node(for slot: ProcessingSlot) -> AVAudioNode? {
        lock.lock()
        defer { lock.unlock() }
        return nodes[slot]
    }

    /// Fills `slot` with `node`, or clears it when `node` is `nil`.
    ///
    /// Only slots whose ``ProcessingSlot/isOptional`` is `true` can be set; a
    /// request for a permanent slot is refused and leaves the chain unchanged.
    /// Mutating a slot does NOT re-wire the graph — the caller runs
    /// ``SFBPlaybackEngine/rewireProcessingChain()`` afterwards.
    func setOptionalNode(_ node: AVAudioNode?, for slot: ProcessingSlot) {
        guard slot.isOptional else { return }
        lock.lock()
        defer { lock.unlock() }
        nodes[slot] = node
    }

    /// Attaches every registered node to `engine`, re-connects the chain in
    /// signal-flow order, terminates it into `mainMixer`, re-applies the user's
    /// balance, re-installs the spectrum tap, and returns the chain HEAD — the
    /// node whatever feeds the chain must connect to.
    ///
    /// Pass `source` when the caller owns the upstream connection (the engine's
    /// own build re-points `AudioPlayer.sourceNode` at the head); pass `nil` when
    /// the caller does not (SFB connects its source to the returned node itself).
    /// The upstream connection is made BEFORE the chain's own, because installing
    /// the tap on a head that has no input yet leaves it mismatched once the input
    /// arrives and the graph renders silence.
    ///
    /// ALWAYS wire with the format the caller was handed: during SFB's
    /// `reconfigureProcessingGraph` the nodes' own formats are stale.
    ///
    /// Re-runnable by design. `AVAudioEngine/connect(_:to:format:)` replaces the
    /// source node's existing output connection, and a node already attached is
    /// left alone, so calling this again after a format change (or after a slot
    /// changed) rebuilds the chain in place — and re-attaches any node that was
    /// detached in the meantime.
    @discardableResult
    func wire(
        into engine: AVAudioEngine,
        from source: AVAudioNode?,
        terminatingAt mainMixer: AVAudioMixerNode,
        format: AVAudioFormat
    ) -> AVAudioNode {
        let route: [AVAudioNode] = orderedNodes
        for node in route where node.engine == nil {
            engine.attach(node)
        }
        if let source {
            engine.disconnectNodeOutput(source)
            engine.connect(source, to: equalizer, format: format)
        }
        let destinations: [AVAudioNode] = Array(route.dropFirst()) + [mainMixer]
        for (upstream, downstream) in zip(route, destinations) {
            engine.connect(upstream, to: downstream, format: format)
        }
        balanceHost.pan = balanceBox.value
        SFBPlaybackEngine.installTap(on: tapHost, into: spectrumProvider)
        return equalizer
    }
}
