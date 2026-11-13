// SFBPlaybackEngine+Parametric — the parametric-EQ half of the engine's seam.
//
// Lives in its own file for two reasons. `SFBPlaybackEngine.swift` is close
// enough to SwiftLint's 400-line ceiling that appending to it is no longer free
// (``SFBPlaybackEngine+OutputRouting.swift`` was split out for the same reason),
// and the parametric stage is an OPTIONAL chain slot rather than part of the
// engine's permanent graph — keeping it apart is what makes "the stage is absent
// unless a configuration installed it" legible.
//
// The stage owns no stored property on the engine: ``ProcessingNodeChain``
// already retains whatever occupies ``ProcessingSlot/parametric``, so the node is
// found through ``ProcessingNodeChain/node(for:)`` instead of through a second
// reference that could drift out of step with the slot.
//
// This file imports only AVFAudio + Foundation; it MUST NOT import AppKit or
// UIKit (PlayerCore portability invariant).
import AVFAudio
import Foundation

public extension SFBPlaybackEngine {
    /// Installs `configuration` on the parametric stage, or removes the stage
    /// when `configuration` is `nil`.
    ///
    /// Three orderings here are load-bearing:
    ///
    /// 1. **Validate before mutating.** The capacity check runs before a node is
    ///    created, programmed, or installed, so a refused configuration leaves
    ///    the graph and the pre-amp summand exactly as they were.
    /// 2. **Re-wire only when MEMBERSHIP changes.** Re-programming an installed
    ///    node's bands is a parameter write on a retained `AVAudioUnitEQ` and
    ///    needs no graph edit; re-wiring anyway would re-install the spectrum tap
    ///    mid-stream for nothing.
    /// 3. **Re-wire BEFORE detaching.** Clearing the slot and re-wiring restores
    ///    `EQ → panHost` first, so the outgoing node's output connection is
    ///    replaced rather than severed — the graph is never left with a hole.
    ///
    /// The pre-amp goes to ``GainComposer/setParametricPreamp(_:)`` and NOWHERE
    /// else: neither this node's `globalGain` (which
    /// ``AVAudioUnitEQ/applyParametricConfiguration(_:)`` pins to 0) nor the
    /// graphic unit's, which is the composed total's output PORT.
    func setParametricConfiguration(_ configuration: ParametricEQConfiguration?) throws {
        guard let configuration else {
            removeParametricStage()
            return
        }
        try configuration.validateFilterCapacity()
        let installed = processingChain.node(for: .parametric) as? AVAudioUnitEQ
        let node = installed ?? makeParametricEQUnit()
        node.applyParametricConfiguration(configuration)
        gainComposer.setParametricPreamp(Float(configuration.preampDB))
        guard installed == nil else { return }
        processingChain.setOptionalNode(node, for: .parametric)
        rewireProcessingChain()
    }
}

private extension SFBPlaybackEngine {
    func removeParametricStage() {
        gainComposer.setParametricPreamp(0)
        guard let node = processingChain.node(for: .parametric) else { return }
        processingChain.setOptionalNode(nil, for: .parametric)
        rewireProcessingChain()
        detachFromGraph(node)
    }

    /// Detaches `node` from the player's engine once the chain has been re-wired
    /// around it.
    ///
    /// Without this the node stays in the engine's attached set forever: the
    /// chain no longer references it, so nothing else can ever release it, and it
    /// would be pulled as a second, silent input of the balance host.
    func detachFromGraph(_ node: AVAudioNode) {
        player.modifyProcessingGraph { engine in
            guard node.engine === engine else { return }
            engine.detach(node)
        }
    }
}

// MARK: - Test hooks

extension SFBPlaybackEngine {
    /// The node currently occupying the parametric slot, or `nil` when the stage
    /// is bypassed — the one observation that distinguishes "installed" from
    /// "detached" without reaching into the chain from a test.
    var parametricEQNode: AVAudioUnitEQ? {
        processingChain.node(for: .parametric) as? AVAudioUnitEQ
    }
}
