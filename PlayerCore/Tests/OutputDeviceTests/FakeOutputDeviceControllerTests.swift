import Models
import PlayerCoreTestSupport
import Services
import Testing

/// Counts main-actor change events, standing in for whatever a shell would drive off
/// them — the Output pane's list and, through todo 14's engine seam, a reconfigure.
/// A failed rate change must leave this at zero.
@MainActor
final class SnapshotRecorder {
    private(set) var snapshots: [OutputDeviceSnapshot] = []

    func record(_ snapshot: OutputDeviceSnapshot) {
        snapshots.append(snapshot)
    }

    var count: Int {
        snapshots.count
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(1), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Suite("Output device seam", .serialized)
struct FakeOutputDeviceControllerTests {
    /// The upper edge of the bounded wait, generously padded.
    ///
    /// The bound under test is `OutputDeviceRateChange.boundedWaitSeconds` (2.0 s) and
    /// the assertion that matters is the LOWER one — that the wait was really served
    /// rather than bailed out of early. This ceiling only has to rule out a runaway
    /// (a 10 s wait, or no bound at all), so it is deliberately loose: `Task.sleep`
    /// guarantees a MINIMUM duration and the wake-up lands whenever the scheduler gets
    /// round to it. A tight ceiling measures the CI machine's load, not this code —
    /// an earlier 2.1 s version flaked at 2.126 s on an otherwise idle laptop.
    private static let boundedWaitCeiling = Duration.seconds(3)

    /// The ceiling for a path that must NOT enter the bounded wait at all.
    ///
    /// Anything comfortably under `boundedWaitSeconds` proves the 2 s wait was skipped;
    /// 1 s leaves double the headroom while still failing unambiguously if it was not.
    private static let fastPathCeiling = Duration.seconds(1)

    /// When a late-confirming device answers, measured from the start of the set.
    ///
    /// Twice the 2 s bound, and the gap is doing real work in BOTH directions: the
    /// test asserts the confirmation has NOT landed at the moment the caller times out
    /// (so the delay must exceed the timeout by more than its jitter, or the test
    /// fails for the wrong reason), and then that it DOES land (so the subsequent wait
    /// must cover the remaining ~2 s). 2.3 s left only ~0.3 s on the first margin.
    private static let lateConfirmationDelay = 4.0

    private func makeController(
        behavior: FakeOutputDeviceController.RateChangeBehavior = .confirmsImmediately
    ) -> FakeOutputDeviceController {
        FakeOutputDeviceController(
            devices: [.builtIn, .usbDAC],
            systemDefaultID: OutputDevice.builtIn.id,
            rates: [OutputDevice.usbDAC.id: [44100, 48000, 96000]],
            currentRates: [OutputDevice.builtIn.id: 48000, OutputDevice.usbDAC.id: 44100],
            behavior: behavior
        )
    }

    private func attachRecorder(to controller: FakeOutputDeviceController) async -> SnapshotRecorder {
        let recorder = SnapshotRecorder()
        await controller.setOnChange { @MainActor @Sendable snapshot in recorder.record(snapshot) }
        return recorder
    }

    // MARK: - Enumeration

    @Test("Lists seeded devices with their id, uid and name")
    func listsSeededDevices() async {
        let controller = makeController()

        let snapshot = await controller.snapshot()

        #expect(snapshot.devices.map(\.id) == [OutputDevice.builtIn.id, OutputDevice.usbDAC.id])
        #expect(snapshot.devices.map(\.uid) == [OutputDevice.builtIn.uid, OutputDevice.usbDAC.uid])
        #expect(snapshot.devices.map(\.name) == [OutputDevice.builtIn.name, OutputDevice.usbDAC.name])
        #expect(snapshot.activeDeviceID == OutputDevice.builtIn.id)
    }

    @Test("Selecting a UID switches the active device; clearing it follows the default again")
    func selectionTogglesFollowFlag() async {
        let controller = makeController()

        await controller.selectDevice(uid: OutputDevice.usbDAC.uid)
        var snapshot = await controller.snapshot()
        #expect(!snapshot.followsSystemDefault)
        #expect(snapshot.activeDeviceID == OutputDevice.usbDAC.id)

        await controller.selectDevice(uid: nil)
        snapshot = await controller.snapshot()
        #expect(snapshot.followsSystemDefault)
        #expect(snapshot.activeDeviceID == OutputDevice.builtIn.id)
    }

    @Test("Unplugging the selected device falls back to the default without losing the choice")
    func unplugFallsBackWithoutForgetting() async {
        let controller = makeController()
        await controller.selectDevice(uid: OutputDevice.usbDAC.uid)

        await controller.simulateDeviceList([.builtIn], systemDefaultID: OutputDevice.builtIn.id)

        let snapshot = await controller.snapshot()
        #expect(snapshot.hasUnavailableSelection)
        #expect(snapshot.activeDeviceID == OutputDevice.builtIn.id)
        #expect(snapshot.selectedUID == OutputDevice.usbDAC.uid)
    }

    // MARK: - Rates

    @Test("Advertised rates are per device and ascending")
    func advertisedRatesArePerDevice() async throws {
        let controller = makeController()

        let dacRates = try await controller.availableRates(for: OutputDevice.usbDAC.id)
        let builtInRates = try await controller.availableRates(for: OutputDevice.builtIn.id)

        #expect(dacRates == [44100, 48000, 96000])
        #expect(builtInRates == FakeOutputDeviceController.defaultRates)
        #expect(builtInRates == builtInRates.sorted())
    }

    @Test("An unknown device id is a typed deviceNotFound, never a trap")
    func unknownDeviceThrows() async {
        let controller = makeController()

        await #expect(throws: OutputDeviceError.deviceNotFound(999)) {
            try await controller.availableRates(for: 999)
        }
        await #expect(throws: OutputDeviceError.deviceNotFound(999)) {
            try await controller.currentNominalRate(for: 999)
        }
    }

    @Test("A confirmed rate change lands on the device")
    func rateChangeApplies() async throws {
        let controller = makeController()

        try await controller.setNominalRate(96000, on: OutputDevice.usbDAC.id)

        let rate = try await controller.currentNominalRate(for: OutputDevice.usbDAC.id)
        let requests = await controller.rateChangeRequests
        #expect(rate == 96000)
        #expect(requests == [OutputRateChangeRequest(rate: 96000, deviceID: OutputDevice.usbDAC.id)])
    }

    @Test("A device already at the requested rate is a no-op: no set, no wait")
    func alreadyAtRateIssuesNoWait() async throws {
        let controller = makeController(behavior: .neverConfirms)
        let clock = ContinuousClock()

        let elapsed = try await clock.measure {
            try await controller.setNominalRate(44100, on: OutputDevice.usbDAC.id)
        }

        let rate = try await controller.currentNominalRate(for: OutputDevice.usbDAC.id)
        #expect(elapsed < Self.fastPathCeiling)
        #expect(rate == 44100)
    }

    @Test("An unadvertised rate is refused outright, without burning the bounded wait")
    func unsupportedRateIsRefusedImmediately() async {
        let controller = makeController(behavior: .neverConfirms)
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: OutputDeviceError.self) {
            try await controller.setNominalRate(192_000, on: OutputDevice.usbDAC.id)
        }

        #expect(clock.now - start < Self.fastPathCeiling)
    }

    // MARK: - Bounded wait

    @Test("A device that never answers times out within the bound and publishes nothing")
    func neverConfirmingDeviceTimesOut() async {
        let controller = makeController(behavior: .neverConfirms)
        let recorder = await attachRecorder(to: controller)
        await controller.start()
        _ = await waitUntil { recorder.count == 1 }
        let baseline = recorder.count

        let clock = ContinuousClock()
        let start = clock.now
        var caught: OutputDeviceError?
        do {
            try await controller.setNominalRate(96000, on: OutputDevice.usbDAC.id)
        } catch let error as OutputDeviceError {
            caught = error
        } catch {
            Issue.record("Expected OutputDeviceError, got \(error)")
        }
        let elapsed = clock.now - start
        let rate = try? await controller.currentNominalRate(for: OutputDevice.usbDAC.id)

        #expect(caught == .rateChangeTimedOut(
            rate: 96000,
            deviceID: OutputDevice.usbDAC.id,
            afterSeconds: OutputDeviceRateChange.boundedWaitSeconds
        ))
        #expect(elapsed >= .seconds(OutputDeviceRateChange.boundedWaitSeconds))
        #expect(elapsed < Self.boundedWaitCeiling)
        #expect(rate == 44100)
        #expect(recorder.count == baseline)
    }

    @Test("A confirmation that arrives after the timeout still lands, exactly once")
    func lateConfirmationIsAbsorbed() async {
        let controller = makeController(behavior: .confirms(afterSeconds: Self.lateConfirmationDelay))
        let recorder = await attachRecorder(to: controller)
        let baseline = recorder.count

        await #expect(throws: OutputDeviceError.self) {
            try await controller.setNominalRate(96000, on: OutputDevice.usbDAC.id)
        }
        #expect(recorder.count == baseline)

        let landed = await waitUntil(timeout: .seconds(Self.lateConfirmationDelay)) {
            recorder.count == baseline + 1
        }
        let rate = try? await controller.currentNominalRate(for: OutputDevice.usbDAC.id)
        let requests = await controller.rateChangeRequests
        #expect(landed)
        #expect(rate == 96000)
        #expect(requests.count == 1)
    }

    // MARK: - Observation

    @Test("start() publishes a first snapshot on the main actor and device changes republish")
    func startPublishesAndChangesRepublish() async {
        let controller = makeController()
        let recorder = await attachRecorder(to: controller)

        await controller.start()
        #expect(await waitUntil { recorder.count == 1 })

        await controller.simulateSystemDefault(OutputDevice.usbDAC.id)
        #expect(await waitUntil { recorder.count == 2 })
        #expect(recorder.snapshots.last?.systemDefaultID == OutputDevice.usbDAC.id)

        await controller.simulateDeviceList([.builtIn])
        #expect(await waitUntil { recorder.count == 3 })
        #expect(recorder.snapshots.last?.devices == [.builtIn])
        #expect(await controller.startCount == 1)
    }

    @Test("Detaching the handler stops delivery without stopping observation")
    func detachingHandlerStopsDelivery() async {
        let controller = makeController()
        let recorder = await attachRecorder(to: controller)
        await controller.start()
        #expect(await waitUntil { recorder.count == 1 })

        await controller.setOnChange(nil)
        await controller.simulateSystemDefault(OutputDevice.usbDAC.id)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(recorder.count == 1)
        #expect(await controller.snapshot().systemDefaultID == OutputDevice.usbDAC.id)
    }
}
