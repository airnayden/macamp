@testable import AudioEngine
import AVFAudio
import Foundation
import Testing

/// Coverage of ``ProcessingNodeChain`` — the single description both the engine's
/// first graph build and SFB's `reconfigureProcessingGraph` delegate traverse.
///
/// The structural cases drive the chain against a bare `AVAudioEngine`, so they
/// need no audio hardware and run everywhere including CI. The live format-change
/// case needs a default output device to load a decoder, so — exactly like
/// ``SFBReloadTests`` — it is gated behind `MACAMP_AUDIO_HW=1`:
///   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MACAMP_AUDIO_HW=1 \
///     swift test --filter ProcessingChainTests
@MainActor
@Suite(.serialized)
struct ProcessingChainTests {
    // MARK: - Structural (headless — no audio hardware needed)

    @Test("a fresh chain holds exactly the permanent head and tail, in that order")
    func permanentSlotsOnly() {
        let harness = Harness()
        #expect(harness.chain.orderedNodes.count == 2)
        #expect(harness.chain.orderedNodes.first === harness.equalizer)
        #expect(harness.chain.orderedNodes.last === harness.panHost)
    }

    @Test("wiring attaches every node, terminates into the mixer, and returns the EQ head")
    func wiringAttachesAndReturnsHead() {
        let harness = Harness()
        let head = harness.wire()
        #expect(head === harness.equalizer)
        #expect(harness.chain.orderedNodes.allSatisfy { $0.engine != nil })
        #expect(harness.engine.mainMixerNode.engine != nil)
    }

    @Test("optional nodes take their slots in signal-flow order between EQ and pan host")
    func optionalSlotsOrderBetweenHeadAndTail() {
        let harness = Harness()
        let parametric = AVAudioUnitEQ(numberOfBands: 4)
        let crossfeed = AVAudioMixerNode()
        harness.chain.setOptionalNode(parametric, for: .parametric)
        harness.chain.setOptionalNode(crossfeed, for: .crossfeed)

        let head = harness.wire()

        #expect(head === harness.equalizer)
        let nodes = harness.chain.orderedNodes
        #expect(nodes.count == 4)
        #expect(nodes[0] === harness.equalizer)
        #expect(nodes[1] === parametric)
        #expect(nodes[2] === crossfeed)
        #expect(nodes[3] === harness.panHost)
        #expect(nodes.allSatisfy { $0.engine != nil })
    }

    @Test("clearing an optional slot drops its node from the chain")
    func clearingAnOptionalSlot() {
        let harness = Harness()
        let parametric = AVAudioUnitEQ(numberOfBands: 4)
        harness.chain.setOptionalNode(parametric, for: .parametric)
        #expect(harness.chain.orderedNodes.count == 3)

        harness.chain.setOptionalNode(nil, for: .parametric)

        #expect(harness.chain.orderedNodes.count == 2)
        #expect(harness.chain.orderedNodes.contains { $0 === parametric } == false)
    }

    /// Re-heading the chain would orphan the spectrum tap and re-tailing it would
    /// move `pan` onto a node where it is silently inert, so both permanent slots
    /// refuse replacement.
    @Test("the permanent head and tail cannot be replaced through the optional-slot seam")
    func permanentSlotsRefuseReplacement() {
        let harness = Harness()
        harness.chain.setOptionalNode(AVAudioMixerNode(), for: .equalizer)
        harness.chain.setOptionalNode(AVAudioMixerNode(), for: .balance)

        #expect(harness.chain.orderedNodes.count == 2)
        #expect(harness.chain.orderedNodes.first === harness.equalizer)
        #expect(harness.chain.orderedNodes.last === harness.panHost)
    }

    @Test("a graph rebuild restores the balance the user set before it")
    func wiringRestoresBalance() {
        let harness = Harness()
        harness.chain.balanceBox.value = -0.4
        harness.wire()
        #expect(abs(harness.panHost.pan - -0.4) < 0.0001)
    }

    /// The failure path: a node detached behind the chain's back (which is what a
    /// mid-flight graph teardown looks like) must come back on the next wiring
    /// pass, because `reconfigureProcessingGraph` is the only repair opportunity.
    @Test("re-wiring re-attaches a chain node that was detached in the meantime")
    func rewiringReattachesADetachedNode() {
        let harness = Harness()
        let crossfeed = AVAudioMixerNode()
        harness.chain.setOptionalNode(crossfeed, for: .crossfeed)
        harness.wire()
        #expect(harness.chain.orderedNodes.allSatisfy { $0.engine != nil })

        harness.engine.detach(harness.panHost)
        harness.engine.detach(crossfeed)
        #expect(harness.panHost.engine == nil)
        #expect(crossfeed.engine == nil)

        harness.wire(sampleRate: 48000)

        #expect(
            harness.chain.orderedNodes.allSatisfy { $0.engine != nil },
            "the reconfigure pass left a chain node detached"
        )
    }

    // MARK: - Production engine hooks (headless)

    @Test("the production engine exposes its chain fully attached from construction")
    func productionChainAttachedAtConstruction() {
        let engine = SFBPlaybackEngine()
        #expect(engine.chainNodes.count == 2)
        #expect(engine.isChainFullyAttached)
        #expect(engine.isEQInstalled)
        #expect(engine.isBalanceHostInstalled)
    }

    @Test("a node plugged into an optional slot joins the production chain on a re-wire")
    func productionChainAcceptsAnOptionalNode() {
        let engine = SFBPlaybackEngine()
        let parametric = AVAudioUnitEQ(numberOfBands: 4)
        engine.processingChainForTesting.setOptionalNode(parametric, for: .parametric)

        engine.rewireProcessingChain()

        #expect(engine.chainNodes.count == 3)
        #expect(engine.chainNodes[1] === parametric)
        #expect(engine.isChainFullyAttached)
    }

    // MARK: - Live format change (real playback through the SFB graph)

    @Test(
        "a 44.1 → 48 kHz format change leaves every chain node attached",
        .enabled(if: ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1")
    )
    func formatChangeKeepsEveryChainNodeAttached() throws {
        let first = try SFBReloadTests.makeSilentWAV(seconds: 2.0)
        let second = try SFBReloadTests.makeSilentWAV(seconds: 2.0, sampleRate: 48000)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let engine = SFBPlaybackEngine()
        let parametric = AVAudioUnitEQ(numberOfBands: 4)
        let crossfeed = AVAudioMixerNode()
        engine.processingChainForTesting.setOptionalNode(parametric, for: .parametric)
        engine.processingChainForTesting.setOptionalNode(crossfeed, for: .crossfeed)
        engine.rewireProcessingChain()
        engine.setBalance(0.25)
        try engine.load(first)
        engine.play()
        #expect(engine.isChainFullyAttached)

        // The differing sample rate forces SFB to fire reconfigureProcessingGraph,
        // which must re-establish the WHOLE chain, not just the EQ and pan host.
        try engine.reload(url: second, at: 0.5, resumePlaying: true)

        #expect(engine.chainNodes.count == 4)
        #expect(engine.isChainFullyAttached, "the reconfigure pass dropped a chain node")
        #expect(engine.isEQInstalled)
        #expect(engine.isBalanceHostInstalled)
        #expect(abs(engine.balanceHostPan - 0.25) < 0.0001)
        engine.stop()
    }

    // MARK: - Harness

    /// A chain wired against a bare `AVAudioEngine`, so the structural cases never
    /// touch `SFBAudioPlayer` or an output device.
    @MainActor
    final class Harness {
        let equalizer = makeEQUnit()
        let panHost = AVAudioMixerNode()
        let engine = AVAudioEngine()
        let chain: ProcessingNodeChain

        init() {
            chain = ProcessingNodeChain(
                equalizer: equalizer,
                balanceHost: panHost,
                balanceBox: BalanceBox(),
                spectrumProvider: SpectrumProvider()
            )
        }

        @discardableResult
        func wire(sampleRate: Double = 44100) -> AVAudioNode {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
                fatalError("unconstructible standard format")
            }
            return chain.wire(
                into: engine,
                from: nil,
                terminatingAt: engine.mainMixerNode,
                format: format
            )
        }
    }
}
