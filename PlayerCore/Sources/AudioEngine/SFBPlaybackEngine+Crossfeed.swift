// SFBPlaybackEngine+Crossfeed — the engine seam that puts MacAMP's bs2b crossfeed
// stage into (and takes it out of) the processing chain.
//
// Split out of `SFBPlaybackEngine.swift` for the same reason
// `SFBPlaybackEngine+OutputRouting.swift` was: that file sits near SwiftLint's
// 400-line ceiling, and the module's `Type+Facet.swift` pattern keeps each seam
// readable on its own. Extension members in the SAME module satisfy protocol
// requirements and are entered into the witness table, so the two members below
// dispatch dynamically through `any PlaybackEngine` exactly as the transport
// members do.
//
// The seam holds NO state of its own: ``ProcessingNodeChain`` already retains the
// node it was handed, so ``ProcessingNodeChain/node(for:)`` IS the
// installed-or-not answer. A stored property here would be a second reference
// that could drift out of step with the slot.
//
// ── ENABLE IS NODE PRESENCE, NOT A BYPASS FLAG ───────────────────────────────
//
// Disabling crossfeed CLEARS ``ProcessingSlot/crossfeed`` and re-wires, so the
// signal path returns to exactly the graph it had before crossfeed was ever
// switched on — bit-identical output, not a bypassed node whose presence still
// costs a buffer copy. A bypass flag would also have to be read from the render
// thread on every block; node presence is read once, at wiring time.
//
// ── WHAT THIS SEAM DELIBERATELY DOES NOT TOUCH ───────────────────────────────
//
//   * THE TAP. ``ProcessingNodeChain/tapHost`` stays the graphic EQ, which is
//     UPSTREAM of the crossfeed slot, so the visualizer and the stereo metering
//     ring both read the PRE-crossfeed signal. That is the recorded decision.
//   * THE GAIN. bs2b's output compensation lives inside ``CrossfeedKernel``'s
//     output stage and contributes no summand to ``GainComposer``.
//
// This file imports only AVFAudio + DSP + Foundation; it MUST NOT import AppKit
// or UIKit (PlayerCore portability invariant).
import AVFAudio
import DSP
import Foundation

public extension SFBPlaybackEngine {
    /// The crossfeed strength currently in the signal path, or `nil` when the
    /// stage is not inserted.
    var crossfeedLevel: CrossfeedLevel? {
        installedCrossfeedUnit?.level
    }

    /// Inserts, retunes, or removes the crossfeed stage.
    ///
    /// `fcut` and `feedDB` are clamped into the legal bs2b range per component by
    /// ``CrossfeedLevel``'s initialiser, so an out-of-range value from a stale
    /// preference is honoured on the component that WAS legal rather than
    /// discarded wholesale. Nothing here throws: a refused value is a clamped
    /// value, not a failure.
    ///
    /// Retuning an already-inserted stage does NOT re-wire the graph — the new
    /// coefficients travel through the kernel's wait-free box and are adopted on
    /// the next render block, so a slider move never disturbs playback.
    func setCrossfeed(enabled: Bool, fcut: Double, feedDB: Double) {
        guard enabled else {
            removeCrossfeedStage()
            return
        }
        let level = CrossfeedLevel(cutFrequency: fcut, feedDB: feedDB)
        if let installed = installedCrossfeedUnit {
            installed.setLevel(level)
            return
        }
        guard let created = CrossfeedAudioUnit.makeNode() else { return }
        created.unit.setLevel(level)
        processingChain.setOptionalNode(created.node, for: .crossfeed)
        rewireProcessingChain()
    }

    /// The audio unit inside the chain's crossfeed slot, or `nil` when empty.
    private var installedCrossfeedUnit: CrossfeedAudioUnit? {
        guard let node = processingChain.node(for: .crossfeed) as? AVAudioUnit else { return nil }
        return node.auAudioUnit as? CrossfeedAudioUnit
    }

    /// Clears the crossfeed slot and re-wires, leaving the chain exactly as it was
    /// before the stage was inserted. Inert when nothing is installed.
    private func removeCrossfeedStage() {
        guard installedCrossfeedUnit != nil else { return }
        processingChain.setOptionalNode(nil, for: .crossfeed)
        rewireProcessingChain()
    }
}
