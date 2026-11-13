@testable import AudioEngine
import AVFAudio
import Foundation
import Testing

/// Coverage of ``PlaybackEngine/setParametricConfiguration(_:)`` — the seam that
/// installs a second, independent `AVAudioUnitEQ` into the chain's
/// ``ProcessingSlot/parametric`` slot.
///
/// The contract is mostly NEGATIVE, so most cases assert what the stage does NOT
/// touch: the ten-band graphic unit's layout and gains, either node's
/// `globalGain`, and — once the stage is cleared — the graph itself, which must
/// be indistinguishable from one the stage was never installed on.
///
/// Everything here is headless except the format-change case, which needs a
/// default output device to load a decoder and is therefore gated behind
/// `MACAMP_AUDIO_HW=1` exactly like ``SFBReloadTests``:
///   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MACAMP_AUDIO_HW=1 \
///     swift test --filter ParametricEQSeamTests
/// File scope, not a member: `@Test`'s `.enabled(if:)` trait is a `Sendable`
/// closure, so it cannot read a static on the `@MainActor` suite.
private let audioHardwareAvailable = ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1"

@MainActor
@Suite(.serialized)
struct ParametricEQSeamTests {
    private static let preampDB = -6.1

    private static func configuration(
        filterCount: Int = 1,
        preampDB: Double = ParametricEQSeamTests.preampDB
    ) -> ParametricEQConfiguration {
        let filters = (0 ..< filterCount).map { index in
            ParametricFilter(
                type: .peaking,
                frequency: Double(100 * (index + 1)),
                gainDB: 3,
                qFactor: 1.0
            )
        }
        return ParametricEQConfiguration(filters: filters, preampDB: preampDB)
    }

    // MARK: - Installing

    @Test("installing a configuration adds a full-capacity node between EQ and pan host")
    func installAddsTheNodeInItsSlot() throws {
        let engine = SFBPlaybackEngine()
        try engine.setParametricConfiguration(Self.configuration())

        let node = try #require(engine.parametricEQNode)
        #expect(node.bands.count == ParametricEQConfiguration.maximumFilterCount)
        #expect(engine.chainNodes.count == 3)
        #expect(engine.chainNodes[1] === node)
        #expect(engine.isChainFullyAttached)
        #expect(engine.isEQInstalled)
        #expect(engine.isBalanceHostInstalled)
    }

    @Test("only the bands a configuration uses are active; the rest stay bypassed")
    func unusedBandsStayBypassed() throws {
        let engine = SFBPlaybackEngine()
        let used = 3
        try engine.setParametricConfiguration(Self.configuration(filterCount: used))

        let node = try #require(engine.parametricEQNode)
        let tailIsBypassed = node.bands.dropFirst(used).allSatisfy(\.bypass)
        #expect(Self.activeBandCount(of: node) == used)
        #expect(node.bands.prefix(used).allSatisfy { !$0.bypass })
        #expect(tailIsBypassed)
        #expect(abs(node.bands[0].frequency - 100) < 0.001)
        #expect(abs(node.bands[0].gain - 3) < 0.001)
    }

    @Test("re-installing reprograms the SAME node rather than rebuilding the graph")
    func reinstallReusesTheInstalledNode() throws {
        let engine = SFBPlaybackEngine()
        try engine.setParametricConfiguration(Self.configuration(filterCount: 1))
        let first = try #require(engine.parametricEQNode)

        try engine.setParametricConfiguration(Self.configuration(filterCount: 2))

        #expect(engine.parametricEQNode === first, "a band change rebuilt the chain")
        #expect(engine.chainNodes.count == 3)
        #expect(Self.activeBandCount(of: first) == 2)
        #expect(engine.isChainFullyAttached)
    }

    // MARK: - Pre-amp routing

    @Test("the pre-amp lands on the gain composer and on neither node's global gain")
    func preampRoutesThroughTheGainComposer() throws {
        let engine = SFBPlaybackEngine()
        try engine.setParametricConfiguration(Self.configuration())

        let composer = engine.gainComposer
        #expect(abs(composer.parametricPreampDB - Float(Self.preampDB)) < 0.001)
        #expect(composer.graphicPreampDB == 0, "the parametric pre-amp landed on the graphic summand")
        #expect(composer.replayGainDB == 0)
        #expect(engine.parametricEQNode?.globalGain == 0, "the pre-amp was written onto the node")
        // The graphic unit's globalGain is the composed TOTAL's output port, so it
        // must carry the sum — not the parametric summand written directly.
        #expect(abs(engine.storedGlobalGain - composer.composedGainDB) < 0.0001)
    }

    @Test("the parametric pre-amp sums with ReplayGain instead of replacing it")
    func preampSumsWithReplayGain() throws {
        let engine = SFBPlaybackEngine()
        engine.gainComposer.setReplayGain(-4)

        try engine.setParametricConfiguration(Self.configuration(preampDB: -6))

        #expect(abs(engine.gainComposer.composedGainDB - -10) < 0.001)
        #expect(abs(engine.storedGlobalGain - -10) < 0.001)
    }

    // MARK: - Clearing

    @Test("clearing removes the node, detaches it, and zeroes the pre-amp summand")
    func clearingRemovesTheStage() throws {
        let engine = SFBPlaybackEngine()
        try engine.setParametricConfiguration(Self.configuration())
        let node = try #require(engine.parametricEQNode)

        try engine.setParametricConfiguration(nil)

        #expect(engine.parametricEQNode == nil)
        #expect(engine.chainNodes.count == 2)
        #expect(engine.isChainFullyAttached)
        #expect(node.engine == nil, "the cleared stage was left attached to the graph")
        #expect(engine.gainComposer.parametricPreampDB == 0)
        #expect(engine.gainComposer.composedGainDB == 0)
    }

    @Test("clearing an already-empty stage is inert")
    func clearingWithoutAStageIsInert() throws {
        let engine = SFBPlaybackEngine()
        let before = engine.chainNodes

        try engine.setParametricConfiguration(nil)

        #expect(engine.chainNodes.count == before.count)
        #expect(zip(engine.chainNodes, before).allSatisfy { $0 === $1 })
        #expect(engine.parametricEQNode == nil)
        #expect(engine.isChainFullyAttached)
    }

    @Test("a cleared stage leaves the graph identical to one that never had it")
    func clearedChainMatchesAVirginEngine() throws {
        let virgin = SFBPlaybackEngine()
        let engine = SFBPlaybackEngine()
        try engine.setParametricConfiguration(Self.configuration())
        try engine.setParametricConfiguration(nil)

        #expect(engine.chainNodes.count == virgin.chainNodes.count)
        #expect(engine.chainNodes.first === engine.processingChainForTesting.equalizer)
        #expect(engine.chainNodes.last === engine.processingChainForTesting.balanceHost)
    }

    // MARK: - The graphic EQ is untouched

    @Test("the ten-band graphic EQ survives an install and a clear unchanged")
    func graphicEqualiserIsUntouched() throws {
        let engine = SFBPlaybackEngine()
        engine.setBandGain(EQBand.hz1k.rawValue, dB: 4)
        engine.setBandGain(EQBand.hz32.rawValue, dB: -3)

        try engine.setParametricConfiguration(Self.configuration())
        try engine.setParametricConfiguration(nil)

        #expect(engine.bandGains.count == EQBand.allCases.count)
        #expect(abs(engine.bandGains[EQBand.hz1k.rawValue] - 4) < 0.001)
        #expect(abs(engine.bandGains[EQBand.hz32.rawValue] - -3) < 0.001)
        #expect(engine.isEQInstalled)
    }

    // MARK: - Capacity

    @Test("a 17-filter configuration is refused and changes nothing")
    func overCapacityConfigurationIsRefused() throws {
        let engine = SFBPlaybackEngine()
        let overCapacity = Self.configuration(
            filterCount: ParametricEQConfiguration.maximumFilterCount + 1
        )

        #expect(
            throws: ParametricEQConfigurationError.tooManyFilters(
                count: ParametricEQConfiguration.maximumFilterCount + 1,
                maximum: ParametricEQConfiguration.maximumFilterCount
            )
        ) {
            try engine.setParametricConfiguration(overCapacity)
        }

        #expect(engine.parametricEQNode == nil)
        #expect(engine.chainNodes.count == 2)
        #expect(engine.gainComposer.parametricPreampDB == 0, "a refused profile still moved the gain")
    }

    @Test("a configuration filling every band is accepted")
    func fullCapacityConfigurationIsAccepted() throws {
        let engine = SFBPlaybackEngine()
        let maximum = ParametricEQConfiguration.maximumFilterCount

        try engine.setParametricConfiguration(Self.configuration(filterCount: maximum))

        let installed = try #require(engine.parametricEQNode)
        #expect(installed.bands.allSatisfy { !$0.bypass })
    }

    // MARK: - The fake mirrors the seam

    @Test("the fake engine mirrors the configuration and its pre-amp")
    func fakeMirrorsTheConfiguration() throws {
        let engine = FakePlaybackEngine()
        let configuration = Self.configuration()
        #expect(engine.parametricConfiguration == nil)

        try engine.setParametricConfiguration(configuration)
        #expect(engine.parametricConfiguration == configuration)
        #expect(abs(engine.gainComposer.parametricPreampDB - Float(Self.preampDB)) < 0.001)

        try engine.setParametricConfiguration(nil)
        #expect(engine.parametricConfiguration == nil)
        #expect(engine.gainComposer.parametricPreampDB == 0)
        #expect(engine.requestedParametricConfigurations.count == 2)
    }

    @Test("the fake refuses an over-capacity configuration but still records the request")
    func fakeRecordsARefusedConfiguration() throws {
        let engine = FakePlaybackEngine()
        let overCapacity = Self.configuration(
            filterCount: ParametricEQConfiguration.maximumFilterCount + 1
        )

        #expect(throws: ParametricEQConfigurationError.self) {
            try engine.setParametricConfiguration(overCapacity)
        }

        #expect(engine.parametricConfiguration == nil)
        #expect(engine.requestedParametricConfigurations.count == 1)
        #expect(engine.gainComposer.parametricPreampDB == 0)
    }

    // MARK: - Live format change (real playback through the SFB graph)

    @Test(
        "a 44.1 → 48 kHz format change keeps the parametric stage attached and programmed",
        .enabled(if: audioHardwareAvailable)
    )
    func formatChangeKeepsTheParametricStageAttached() throws {
        let first = try SFBReloadTests.makeSilentWAV(seconds: 2.0)
        let second = try SFBReloadTests.makeSilentWAV(seconds: 2.0, sampleRate: 48000)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let engine = SFBPlaybackEngine()
        try engine.setParametricConfiguration(Self.configuration(filterCount: 2))
        let node = try #require(engine.parametricEQNode)
        try engine.load(first)
        engine.play()
        #expect(engine.isChainFullyAttached)

        try engine.reload(url: second, at: 0.5, resumePlaying: true)

        #expect(engine.chainNodes.count == 3)
        #expect(engine.parametricEQNode === node, "the reconfigure pass replaced the stage")
        #expect(engine.isChainFullyAttached, "the reconfigure pass dropped the parametric stage")
        #expect(Self.activeBandCount(of: node) == 2, "the reconfigure pass reset the stage's bands")
        #expect(abs(engine.gainComposer.parametricPreampDB - Float(Self.preampDB)) < 0.001)
        engine.stop()
    }

    // MARK: - Helpers

    private static func activeBandCount(of unit: AVAudioUnitEQ) -> Int {
        unit.bands.count { !$0.bypass }
    }
}
