@testable import AudioEngine
import AVFAudio
import Foundation
import PlayerCoreTestSupport
import Testing

/// Whether a chain render had the crossfeed stage in its slot, and whether that
/// slot was cleared again before wiring.
private enum SlotState {
    case never
    case installed
    case installedThenCleared
}

/// Renders a fixed probe tone through a real ``ProcessingNodeChain`` in `slot`'s
/// configuration and returns every sample.
///
/// The chain terminates at the main mixer exactly as it does in production, so
/// the comparison between two `SlotState`s is a comparison of the SHIPPING
/// signal path rather than of a simplified stand-in.
private func renderChain(_ slot: SlotState) throws -> [[Float]] {
    let format = try CrossfeedProbe.stereoFormat()
    let chain = ProcessingNodeChain(
        equalizer: makeEQUnit(),
        balanceHost: AVAudioMixerNode(),
        balanceBox: BalanceBox(),
        spectrumProvider: SpectrumProvider()
    )
    switch slot {
    case .never:
        break
    case .installed:
        try chain.setOptionalNode(#require(CrossfeedAudioUnit.makeNode()).node, for: .crossfeed)
    case .installedThenCleared:
        try chain.setOptionalNode(#require(CrossfeedAudioUnit.makeNode()).node, for: .crossfeed)
        chain.setOptionalNode(nil, for: .crossfeed)
    }

    let rendered = try OfflineRenderHarness.render(format: format, duration: 0.25) { engine in
        let source = CrossfeedProbe.leftOnlySine(format: format, frequency: 1000)
        engine.attach(source)
        chain.wire(
            into: engine,
            from: source,
            terminatingAt: engine.mainMixerNode,
            format: format
        )
        return engine.mainMixerNode
    }
    return try CrossfeedProbe.samples(rendered)
}

/// Coverage of ``SFBPlaybackEngine/setCrossfeed(enabled:fcut:feedDB:)`` — the seam
/// that puts the crossfeed stage into the chain's ``ProcessingSlot/crossfeed``
/// slot — plus the ``FakePlaybackEngine`` mirror of the same contract.
///
/// Headless throughout: the production engine's chain is inspected structurally
/// and the render comparisons drive a bare `AVAudioEngine` offline, so no output
/// device is required.
@MainActor
@Suite(.serialized)
struct CrossfeedSeamTests {
    // MARK: Insertion

    @Test("enabling crossfeed inserts the stage and reports the clamped level")
    func enablingInsertsTheStage() {
        let engine = SFBPlaybackEngine()
        #expect(engine.crossfeedLevel == nil)

        engine.setCrossfeed(enabled: true, fcut: 700, feedDB: 4.5)

        #expect(engine.crossfeedLevel == CrossfeedLevel.default)
        #expect(engine.chainNodes.count == 3)
        #expect(engine.isChainFullyAttached)
    }

    @Test("the stage takes the slot between the parametric stage and the pan host")
    func stageSitsBetweenParametricAndPanHost() {
        let engine = SFBPlaybackEngine()
        let parametric = AVAudioUnitEQ(numberOfBands: 4)
        engine.processingChainForTesting.setOptionalNode(parametric, for: .parametric)
        engine.setCrossfeed(enabled: true, fcut: 700, feedDB: 4.5)

        let nodes = engine.chainNodes
        #expect(nodes.count == 4)
        #expect(nodes[1] === parametric)
        #expect(nodes[2] === engine.processingChainForTesting.node(for: .crossfeed))
        #expect(nodes[3] === engine.processingChainForTesting.balanceHost)
        #expect(engine.isChainFullyAttached)
    }

    /// The recorded decision: the visualizer tap — and the stereo metering ring
    /// built on the same host — stay UPSTREAM of crossfeed.
    @Test("inserting the stage leaves the spectrum tap on the graphic EQ")
    func tapStaysPreCrossfeed() {
        let engine = SFBPlaybackEngine()
        let chain = engine.processingChainForTesting
        engine.setCrossfeed(enabled: true, fcut: 700, feedDB: 4.5)

        #expect(chain.tapHost === chain.equalizer)
        #expect(chain.tapHost !== chain.node(for: .crossfeed))
        #expect(engine.chainNodes.first === chain.tapHost)
    }

    // MARK: Retuning

    @Test("retuning an inserted stage keeps the same node and re-programmes it")
    func retuningKeepsTheSameNode() {
        let engine = SFBPlaybackEngine()
        engine.setCrossfeed(enabled: true, fcut: 700, feedDB: 4.5)
        let inserted = engine.processingChainForTesting.node(for: .crossfeed)

        engine.setCrossfeed(enabled: true, fcut: 650, feedDB: 9.5)

        #expect(engine.processingChainForTesting.node(for: .crossfeed) === inserted)
        #expect(engine.crossfeedLevel == CrossfeedLevel.jmeier)
        #expect(engine.chainNodes.count == 3)
    }

    @Test("an out-of-range request is clamped per component, never refused")
    func outOfRangeRequestIsClamped() {
        let engine = SFBPlaybackEngine()
        engine.setCrossfeed(enabled: true, fcut: 50, feedDB: 99)

        #expect(engine.crossfeedLevel == CrossfeedLevel(cutFrequency: 300, feedDB: 15))
        #expect(engine.chainNodes.count == 3)
        #expect(engine.isChainFullyAttached)
    }

    // MARK: Removal

    @Test("disabling crossfeed clears the slot and restores the permanent chain")
    func disablingClearsTheSlot() {
        let engine = SFBPlaybackEngine()
        engine.setCrossfeed(enabled: true, fcut: 700, feedDB: 4.5)
        #expect(engine.chainNodes.count == 3)

        engine.setCrossfeed(enabled: false, fcut: 700, feedDB: 4.5)

        #expect(engine.crossfeedLevel == nil)
        #expect(engine.chainNodes.count == 2)
        #expect(engine.processingChainForTesting.node(for: .crossfeed) == nil)
        #expect(engine.isChainFullyAttached)
    }

    @Test("disabling crossfeed that was never enabled is inert")
    func disablingWhenOffIsInert() {
        let engine = SFBPlaybackEngine()
        engine.setCrossfeed(enabled: false, fcut: 700, feedDB: 4.5)

        #expect(engine.crossfeedLevel == nil)
        #expect(engine.chainNodes.count == 2)
        #expect(engine.isChainFullyAttached)
    }

    // MARK: Format change

    @Test("a re-wire at a new sample rate keeps the stage attached and in its slot")
    func formatChangeKeepsTheStageInTheChain() throws {
        let format = try CrossfeedProbe.stereoFormat(48000)
        let chain = ProcessingNodeChain(
            equalizer: makeEQUnit(),
            balanceHost: AVAudioMixerNode(),
            balanceBox: BalanceBox(),
            spectrumProvider: SpectrumProvider()
        )
        let crossfeed = try #require(CrossfeedAudioUnit.makeNode())
        chain.setOptionalNode(crossfeed.node, for: .crossfeed)

        let engine = AVAudioEngine()
        for rate in [CrossfeedProbe.sampleRate, 48000.0] {
            let wiringFormat = try CrossfeedProbe.stereoFormat(rate)
            chain.wire(
                into: engine,
                from: nil,
                terminatingAt: engine.mainMixerNode,
                format: wiringFormat
            )
        }

        #expect(chain.node(for: .crossfeed) === crossfeed.node)
        #expect(chain.orderedNodes.allSatisfy { $0.engine != nil })
        #expect(crossfeed.node.outputFormat(forBus: 0).sampleRate == format.sampleRate)
    }

    // MARK: Bit-identity — OFF leaves nothing behind

    @Test("clearing the slot renders bit-identically to a chain that never had one")
    func clearedSlotRendersBitIdenticalToBaseline() throws {
        let baseline = try renderChain(.never)
        let cleared = try renderChain(.installedThenCleared)
        let crossfed = try renderChain(.installed)

        #expect(baseline.count == 2)
        #expect(cleared == baseline, "clearing the crossfeed slot changed the rendered signal")
        #expect(crossfed != baseline, "the crossfeed stage did not change the rendered signal")
    }

    // MARK: Fake mirror

    @Test("the fake mirrors the seam: clamped level in, history recorded")
    func fakeMirrorsTheSeam() {
        let engine = FakePlaybackEngine()
        #expect(engine.crossfeedLevel == nil)

        engine.setCrossfeed(enabled: true, fcut: 700, feedDB: 6.0)
        #expect(engine.crossfeedLevel == CrossfeedLevel.cmoy)

        engine.setCrossfeed(enabled: true, fcut: 50, feedDB: 99)
        #expect(engine.crossfeedLevel == CrossfeedLevel(cutFrequency: 300, feedDB: 15))

        engine.setCrossfeed(enabled: false, fcut: 700, feedDB: 6.0)
        #expect(engine.crossfeedLevel == nil)

        #expect(engine.requestedCrossfeedLevels.count == 3)
        #expect(engine.requestedCrossfeedLevels[0] == CrossfeedLevel.cmoy)
        #expect(engine.requestedCrossfeedLevels[2] == nil)
    }

    /// The seam has to reach a conformer through the existential, or the
    /// coordinator and the view models that own an `any PlaybackEngine` cannot
    /// drive it at all.
    @Test("the seam dispatches through the protocol existential")
    func seamDispatchesThroughTheExistential() {
        let fake = FakePlaybackEngine()
        let engine: any PlaybackEngine = fake

        engine.setCrossfeed(enabled: true, fcut: 650, feedDB: 9.5)

        #expect(engine.crossfeedLevel == CrossfeedLevel.jmeier)
        #expect(fake.requestedCrossfeedLevels == [CrossfeedLevel.jmeier])
    }

    @Test("a conformer with no processing chain gets the inert default")
    func defaultIsInert() {
        let engine: any PlaybackEngine = ChainlessEngine()
        engine.setCrossfeed(enabled: true, fcut: 700, feedDB: 4.5)
        #expect(engine.crossfeedLevel == nil)
    }
}

/// A conformer that declares none of the crossfeed surface — the shape a
/// coordinator spy has, and the reason the requirements carry defaults.
@MainActor
private final class ChainlessEngine: PlaybackEngine {
    var state: PlaybackState = .idle
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var stateDidChange: ((PlaybackState) -> Void)?
    var volume: Float = 1
    var balance: Float = 0
    var onEndOfAudio: (() -> Void)?
    var onRenderingComplete: (() -> Void)?

    func load(_: URL) throws {}
    func enqueue(_: URL) throws {}
    func load(source _: DecoderSource) throws {}
    func enqueue(source _: DecoderSource) throws {}
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to _: TimeInterval) {}
    func reload(url _: URL, at _: TimeInterval, resumePlaying _: Bool) throws {}
    func reload(source _: DecoderSource, at _: TimeInterval, resumePlaying _: Bool) throws {}
    func setBandGain(_: Int, dB _: Float) {}
    func setGlobalGain(_: Float) {}
    func setVolume(_: Float) {}
    func setBalance(_: Float) {}
}
