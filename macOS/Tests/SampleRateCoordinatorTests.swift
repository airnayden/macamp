import AudioEngine
@testable import MacAMP
import Models
import Services
import Testing

/// Records which tracks actually reached `engine.load`, which is the only way to
/// tell a superseded activation from one that ran.
@MainActor
final class StartedTrackRecorder {
    private(set) var startedIDs: [Int64] = []

    func record(_ trackID: Int64) {
        startedIDs.append(trackID)
    }
}

@MainActor
enum SampleRateFixtures {
    static let deviceID = OutputDevice.scriptedDAC.id

    /// A DAC sitting at 44.1 kHz that also advertises 48 and 96 kHz.
    static func controller(
        behavior: ScriptedOutputDeviceController.Behavior = .confirmsImmediately
    ) -> ScriptedOutputDeviceController {
        ScriptedOutputDeviceController(
            devices: [.scriptedDAC],
            rates: [deviceID: [44100, 48000, 96000]],
            currentRates: [deviceID: 44100],
            behavior: behavior
        )
    }

    static func track(_ name: String, id: Int64, sampleRate: Int?) -> TrackRef {
        TrackRef(
            trackID: id,
            filePath: "/tmp/macamp-rate-\(name).flac",
            title: name,
            sampleRate: sampleRate
        )
    }

    static func rateCoordinator(
        _ controller: some OutputDeviceControlling,
        enabled: Bool = true
    ) -> SampleRateCoordinator {
        SampleRateCoordinator(
            controller: controller,
            activeDeviceID: { deviceID },
            isEnabled: { enabled }
        )
    }

    /// A playback coordinator whose explicit track starts run through `rate` first.
    static func playback(
        engine: FakePlaybackEngine,
        rate: SampleRateCoordinator?
    ) -> PlaybackCoordinator {
        let coordinator = PlaybackCoordinator(engine: engine)
        coordinator.preLoadHook = rate?.preLoadHook()
        return coordinator
    }
}

@MainActor
func waitUntilRateSettles(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
@Suite("Sample-rate coordinator", .serialized)
struct SampleRateCoordinatorTests {
    // MARK: - Paths that must issue no set at all

    @Test("A track already at the device's rate issues no rate call")
    func matchingRateIssuesNothing() async throws {
        let controller = SampleRateFixtures.controller()
        let rate = SampleRateFixtures.rateCoordinator(controller)

        await rate.prepare(for: SampleRateFixtures.track("match", id: 1, sampleRate: 44100))

        #expect(await controller.rateChangeRequests.isEmpty)
        let nominalRate = try await controller.currentNominalRate(for: SampleRateFixtures.deviceID)
        #expect(nominalRate == 44100)
    }

    @Test("An unknown or zero stored sample rate issues no rate call")
    func unknownRateIssuesNothing() async {
        let controller = SampleRateFixtures.controller()
        let rate = SampleRateFixtures.rateCoordinator(controller)

        await rate.prepare(for: SampleRateFixtures.track("unknown", id: 2, sampleRate: nil))
        await rate.prepare(for: SampleRateFixtures.track("zero", id: 3, sampleRate: 0))

        #expect(SampleRateCoordinator.nominalRate(
            of: SampleRateFixtures.track("unknown", id: 2, sampleRate: nil)
        ) == nil)
        #expect(await controller.rateChangeRequests.isEmpty)
    }

    @Test("The preference being off issues no rate call")
    func disabledIssuesNothing() async {
        let controller = SampleRateFixtures.controller()
        let rate = SampleRateFixtures.rateCoordinator(controller, enabled: false)

        await rate.prepare(for: SampleRateFixtures.track("off", id: 4, sampleRate: 96000))

        #expect(await controller.rateChangeRequests.isEmpty)
    }

    @Test("A rate the device does not advertise is never set")
    func unsupportedRateIsNeverSet() async throws {
        let controller = SampleRateFixtures.controller()
        let rate = SampleRateFixtures.rateCoordinator(controller)

        await rate.prepare(for: SampleRateFixtures.track("dsd", id: 5, sampleRate: 352_800))

        #expect(await controller.rateChangeRequests.isEmpty)
        let nominalRate = try await controller.currentNominalRate(for: SampleRateFixtures.deviceID)
        #expect(nominalRate == 44100)
    }

    // MARK: - The switching path

    @Test("A differing rate issues exactly one set, and the load waits for it")
    func differingRateSetsOnceBeforeLoad() async throws {
        let controller = SampleRateFixtures.controller(behavior: .confirms(afterSeconds: 0.4))
        let engine = FakePlaybackEngine()
        let coordinator = SampleRateFixtures.playback(
            engine: engine,
            rate: SampleRateFixtures.rateCoordinator(controller)
        )

        coordinator.setQueue([SampleRateFixtures.track("hires", id: 10, sampleRate: 96000)], startingAt: 0)

        // Still waiting on the device, so nothing has loaded yet — this ordering IS
        // the "the set strictly precedes the load" assertion.
        #expect(engine.state == .idle)
        #expect(await waitUntilRateSettles { engine.state == .playing })
        #expect(await controller.rateChangeRequests == [
            ScriptedOutputDeviceController.OutputRateChange(
                rate: 96000,
                deviceID: SampleRateFixtures.deviceID
            ),
        ])
        let nominalRate = try await controller.currentNominalRate(for: SampleRateFixtures.deviceID)
        #expect(nominalRate == 96000)
    }

    @Test("With no hook installed, activation stays fully synchronous")
    func noHookKeepsActivationSynchronous() {
        let engine = FakePlaybackEngine()
        let coordinator = SampleRateFixtures.playback(engine: engine, rate: nil)

        coordinator.setQueue([SampleRateFixtures.track("plain", id: 11, sampleRate: 96000)], startingAt: 0)

        #expect(engine.state == .playing)
    }

    // MARK: - The gapless exemption

    @Test("The gapless pre-schedule path issues zero rate calls")
    func gaplessPrescheduleNeverRetunes() async throws {
        let controller = SampleRateFixtures.controller()
        let engine = FakePlaybackEngine()
        let coordinator = SampleRateFixtures.playback(
            engine: engine,
            rate: SampleRateFixtures.rateCoordinator(controller)
        )
        coordinator.setQueue([
            SampleRateFixtures.track("first", id: 20, sampleRate: 44100),
            SampleRateFixtures.track("second", id: 21, sampleRate: 96000),
        ], startingAt: 0)
        #expect(await waitUntilRateSettles { engine.state == .playing })
        let beforePreschedule = await controller.rateChangeRequests.count

        // The engine's own gapless seam — NOT a user next / auto-advance.
        engine.onRenderingComplete?()
        try await Task.sleep(for: .milliseconds(300))

        #expect(await controller.rateChangeRequests.count == beforePreschedule)
        let nominalRate = try await controller.currentNominalRate(for: SampleRateFixtures.deviceID)
        #expect(nominalRate == 44100)
    }

    // MARK: - Failure paths

    @Test("A device that never confirms times out and the load proceeds anyway")
    func timeoutStillLoads() async throws {
        let controller = SampleRateFixtures.controller(behavior: .neverConfirms)
        let engine = FakePlaybackEngine()
        let coordinator = SampleRateFixtures.playback(
            engine: engine,
            rate: SampleRateFixtures.rateCoordinator(controller)
        )

        coordinator.setQueue([SampleRateFixtures.track("stubborn", id: 30, sampleRate: 48000)], startingAt: 0)

        #expect(await waitUntilRateSettles { engine.state == .playing })
        #expect(await controller.rateChangeRequests.count == 1)
        let nominalRate = try await controller.currentNominalRate(for: SampleRateFixtures.deviceID)
        #expect(nominalRate == 44100)
    }

    @Test("A confirmation after the bounded wait is neither re-issued nor acted on")
    func lateConfirmationIsAbsorbed() async throws {
        let late = OutputDeviceRateChange.boundedWaitSeconds + 0.3
        let controller = SampleRateFixtures.controller(behavior: .confirms(afterSeconds: late))
        let engine = FakePlaybackEngine()
        let coordinator = SampleRateFixtures.playback(
            engine: engine,
            rate: SampleRateFixtures.rateCoordinator(controller)
        )

        coordinator.setQueue([SampleRateFixtures.track("laggy", id: 40, sampleRate: 48000)], startingAt: 0)
        #expect(await waitUntilRateSettles { engine.state == .playing })
        let atTimeout = await controller.rateChangeRequests.count
        try await Task.sleep(for: .seconds(1))

        #expect(atTimeout == 1)
        let nominalRate = try await controller.currentNominalRate(for: SampleRateFixtures.deviceID)
        #expect(nominalRate == 48000)
        #expect(await controller.rateChangeRequests.count == 1)
        #expect(engine.state == .playing)
        #expect(coordinator.current?.title == "laggy")
        #expect(coordinator.state.playback == .playing)
    }

    @Test("A superseding activation wins over one still waiting on its device")
    func supersededActivationNeverLoads() async throws {
        let controller = SampleRateFixtures.controller(behavior: .confirms(afterSeconds: 0.4))
        let engine = FakePlaybackEngine()
        let coordinator = SampleRateFixtures.playback(
            engine: engine,
            rate: SampleRateFixtures.rateCoordinator(controller)
        )
        let recorder = StartedTrackRecorder()
        coordinator.onTrackStarted = { recorder.record($0) }
        coordinator.setQueue([
            SampleRateFixtures.track("first", id: 50, sampleRate: 96000),
            SampleRateFixtures.track("second", id: 51, sampleRate: 48000),
        ], startingAt: 0)

        coordinator.next()

        #expect(await waitUntilRateSettles { coordinator.current?.title == "second" })
        try await Task.sleep(for: .milliseconds(600))
        #expect(recorder.startedIDs == [51])
    }
}
