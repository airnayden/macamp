@testable import AudioEngine
import AVFAudio
import Foundation
import Models
import Testing

/// Coverage of the engine's output-routing seam: which device the graph plays to
/// and what format it is running at.
///
/// The contract that matters is NEGATIVE — selecting a device must change the
/// route and NOTHING else. `SFBAudioPlayer` writes the identifier straight to
/// `AVAudioEngine.outputNode`'s `AUAudioUnit.deviceID` on the running engine, so
/// the stream keeps rendering and the processing chain, its tap, the balance and
/// the composed gain are all untouched. The tests below assert exactly that, and
/// the mid-play cases additionally assert the playhead ADVANCES across the set —
/// the one observation a stopped-and-restarted engine could not produce.
///
/// Real playback needs a default output device, so — like ``SFBReloadTests`` and
/// ``SFBBalanceTests`` — those cases are gated behind `MACAMP_AUDIO_HW=1`. Run:
///   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer MACAMP_AUDIO_HW=1 \
///     swift test --filter OutputDeviceSeamTests
/// File scope, not a member: `@Test`'s `.enabled(if:)` trait is a `Sendable`
/// closure, so it cannot read a static on the `@MainActor` suite.
private let audioHardwareAvailable = ProcessInfo.processInfo.environment["MACAMP_AUDIO_HW"] == "1"

@MainActor
@Suite(.serialized)
struct OutputDeviceSeamTests {
    /// An identifier no HAL will ever hand out — one below `UInt32.max`, far above
    /// any real device object id, and never `kAudioObjectUnknown` (0).
    static let unroutableDeviceID: OutputDeviceID = 0xFFFF_FFFE

    // MARK: - The hermetic double

    @Test("the fake stores the routed device and records every request in call order")
    func fakeStoresTheRoutedDevice() throws {
        let engine = FakePlaybackEngine()
        #expect(engine.outputDeviceID == nil)

        try engine.setOutputDeviceID(42)
        try engine.setOutputDeviceID(7)

        #expect(engine.outputDeviceID == 7)
        #expect(engine.requestedOutputDeviceIDs == [42, 7])
    }

    @Test("a refused selection keeps the fake's prior route and is still recorded")
    func fakeRefusalKeepsThePriorRoute() throws {
        let engine = FakePlaybackEngine()
        try engine.setOutputDeviceID(42)
        let refusal = OutputDeviceSelectionError.selectionFailed(deviceID: 99, status: -4)
        engine.outputDeviceSelectionError = refusal

        #expect(throws: refusal) {
            try engine.setOutputDeviceID(99)
        }

        #expect(engine.outputDeviceID == 42, "a refused selection must not move the route")
        #expect(engine.requestedOutputDeviceIDs == [42, 99], "a refused request is still a request")
    }

    @Test("the fake reports a stereo standby format and can present a mono graph")
    func fakeConnectionFormatIsSettable() throws {
        let engine = FakePlaybackEngine()
        #expect(engine.currentConnectionFormat.sampleRate == 44100)
        #expect(engine.currentConnectionFormat.channelCount == 2)

        let mono = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        engine.currentConnectionFormat = mono

        #expect(engine.currentConnectionFormat.sampleRate == 48000)
        #expect(engine.currentConnectionFormat.channelCount == 1)
    }

    // MARK: - The production engine, headless

    @Test("the production engine reports a usable connection format before any media is loaded")
    func connectionFormatIsUsableAtConstruction() {
        let engine = SFBPlaybackEngine()

        #expect(engine.currentConnectionFormat.sampleRate > 0)
        #expect(
            engine.currentConnectionFormat.channelCount > 0,
            "a zero-channel placeholder would reach the signal-path readout as a dead graph"
        )
    }

    @Test("a device selection — honoured or refused — never disturbs the processing graph")
    func deviceSelectionLeavesTheGraphIntact() {
        let engine = SFBPlaybackEngine()
        let crossfeed = AVAudioMixerNode()
        engine.processingChainForTesting.setOptionalNode(crossfeed, for: .crossfeed)
        engine.rewireProcessingChain()
        engine.setGlobalGain(-6)
        engine.setBandGain(0, dB: -4)
        engine.setBalance(0.3)
        let nodesBefore = engine.chainNodes

        // On a host with a default device this routes for real; on a deviceless
        // one the platform refuses it. Both outcomes must leave the graph alone.
        try? engine.setOutputDeviceID(engine.outputDeviceID ?? Self.unroutableDeviceID)

        expectGraphUnchanged(engine, nodesBefore: nodesBefore, balance: 0.3, globalGain: -6, lowBandGain: -4)
    }

    // MARK: - The production engine, mid-play

    @Test(
        "routing mid-play to the device already in use changes nothing and keeps rendering",
        .enabled(if: audioHardwareAvailable)
    )
    func sameDeviceSetMidPlayIsInert() async throws {
        let url = try SFBReloadTests.makeSilentWAV(seconds: 5.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = SFBPlaybackEngine()
        let crossfeed = AVAudioMixerNode()
        engine.processingChainForTesting.setOptionalNode(crossfeed, for: .crossfeed)
        engine.rewireProcessingChain()
        engine.setGlobalGain(-6)
        engine.setBandGain(0, dB: -4)
        engine.setBalance(0.3)
        try engine.load(url)
        engine.play()
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.state == .playing)

        let current = try #require(engine.outputDeviceID, "no default output device on this host")
        let nodesBefore = engine.chainNodes
        let timeAtSet = engine.currentTime

        try engine.setOutputDeviceID(current)

        #expect(engine.state == .playing)
        #expect(engine.outputDeviceID == current)
        expectGraphUnchanged(engine, nodesBefore: nodesBefore, balance: 0.3, globalGain: -6, lowBandGain: -4)

        // The playhead advancing across the set is the observation a stopped and
        // restarted engine could not produce.
        try await Task.sleep(for: .milliseconds(400))
        #expect(
            engine.currentTime > timeAtSet,
            "playhead stalled at \(engine.currentTime) — the device set interrupted rendering"
        )
        engine.stop()
    }

    @Test(
        "the connection format reports the live graph rate while a fixture plays",
        .enabled(if: audioHardwareAvailable)
    )
    func connectionFormatTracksThePlayingGraph() async throws {
        let url = try SFBReloadTests.makeSilentWAV(seconds: 4.0, sampleRate: 48000)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = SFBPlaybackEngine()
        try engine.load(url)
        engine.play()
        try await Task.sleep(for: .milliseconds(400))
        #expect(engine.state == .playing)

        let format = engine.currentConnectionFormat
        #expect(format.sampleRate > 0)
        #expect(
            format.sampleRate == 48000,
            "graph rate \(format.sampleRate) — the accessor is reporting the standby format, not the live one"
        )
        #expect(format.channelCount == 2)
        engine.stop()
    }

    @Test(
        "an unroutable device id surfaces a typed error and playback carries on",
        .enabled(if: audioHardwareAvailable)
    )
    func unroutableDeviceKeepsPlaybackAlive() async throws {
        let url = try SFBReloadTests.makeSilentWAV(seconds: 5.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = SFBPlaybackEngine()
        engine.setBalance(0.3)
        engine.setGlobalGain(-6)
        engine.setBandGain(0, dB: -4)
        try engine.load(url)
        engine.play()
        try await Task.sleep(for: .milliseconds(300))
        let routeBefore = try #require(engine.outputDeviceID, "no default output device on this host")
        let nodesBefore = engine.chainNodes
        let timeAtSet = engine.currentTime

        var captured: OutputDeviceSelectionError?
        do {
            try engine.setOutputDeviceID(Self.unroutableDeviceID)
        } catch let error as OutputDeviceSelectionError {
            captured = error
        }

        let failure = try #require(captured, "the platform accepted an unroutable device id")
        guard case let .selectionFailed(deviceID, status) = failure else {
            Issue.record("expected .selectionFailed, got \(failure)")
            return
        }
        #expect(deviceID == Self.unroutableDeviceID)
        #expect(status != 0, "a refusal must carry the platform's own status code")

        #expect(engine.state == .playing, "a refused device selection must not stop playback")
        #expect(engine.outputDeviceID == routeBefore, "the prior route must survive a refusal")
        expectGraphUnchanged(engine, nodesBefore: nodesBefore, balance: 0.3, globalGain: -6, lowBandGain: -4)

        try await Task.sleep(for: .milliseconds(400))
        #expect(
            engine.currentTime > timeAtSet,
            "playhead stalled at \(engine.currentTime) — the refused set interrupted rendering"
        )
        engine.stop()
    }

    // MARK: - Shared assertion

    /// Asserts every graph-side invariant a device selection must leave alone:
    /// the EQ and pan hosts stay installed, the chain keeps its exact nodes in
    /// their exact order, and the balance, band gains and composed gain are unmoved.
    private func expectGraphUnchanged(
        _ engine: SFBPlaybackEngine,
        nodesBefore: [AVAudioNode],
        balance: Float,
        globalGain: Float,
        lowBandGain: Float
    ) {
        #expect(engine.isEQInstalled)
        #expect(engine.isBalanceHostInstalled)
        #expect(engine.isChainFullyAttached, "a chain node was detached by the device selection")
        #expect(engine.chainNodes.count == nodesBefore.count)
        #expect(
            zip(nodesBefore, engine.chainNodes).allSatisfy { $0 === $1 },
            "the chain was rebuilt with different nodes"
        )
        #expect(abs(engine.balanceHostPan - balance) < 0.0001)
        #expect(engine.balance == balance)
        #expect(engine.storedGlobalGain == globalGain)
        #expect(engine.bandGains[0] == lowBandGain)
    }
}
