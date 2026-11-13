// OutputRoutingModelTests — the Output pane's model, without a HAL.
//
// A THIRD scripted double lives here rather than reusing
// `ScriptedOutputDeviceController`: that one answers `snapshot()` with a hardcoded
// `selectedUID: nil` and ignores `selectDevice(uid:)` entirely, which is exactly the
// behaviour this suite has to observe. It also has no way to publish a device-list
// change, and a replug is the case the fallback rules exist for. Extending it would
// have changed the fixture `SampleRateCoordinatorTests` is pinned to.
//
// `PlayerCoreTestSupport`'s `FakeOutputDeviceController` is unreachable from this
// target (see the note in `macOS/Project.swift`); `FakePlaybackEngine` ships inside
// `AudioEngine`, so the transport half needs no double at all.
import AudioEngine
import Foundation
@testable import MacAMP
import Models
import Services
import Testing

@MainActor
enum OutputRoutingFixtures {
    static let builtIn = OutputDevice(id: 1, uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
    static let dac = OutputDevice(id: 7, uid: "USB-DAC-9001", name: "MyDAC")

    static func controller(
        devices: [OutputDevice] = [builtIn, dac],
        systemDefaultID: OutputDeviceID? = builtIn.id,
        selectedUID: String? = nil
    ) -> RoutingScriptedController {
        RoutingScriptedController(
            devices: devices,
            systemDefaultID: systemDefaultID,
            selectedUID: selectedUID,
            rates: [builtIn.id: 44100, dac.id: 96000]
        )
    }

    /// A settings store on a private `UserDefaults` suite. A struct rather than a
    /// three-element tuple because SwiftLint's `large_tuple` caps tuples at two.
    @MainActor
    struct Harness {
        let settings: AppSettings
        let defaults: UserDefaults
        let suiteName: String

        init(_ label: String) {
            suiteName = "com.example.macamp.tests.output.\(label).\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName) ?? .standard
            settings = AppSettings(defaults: defaults)
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    /// Builds the model wired exactly as `connectOutputRouting(settings:)` wires it,
    /// so a divergence between production wiring and test wiring cannot hide here.
    static func router(
        _ controller: some OutputDeviceControlling,
        engine: FakePlaybackEngine,
        settings: AppSettings
    ) -> OutputRoutingModel {
        let model = OutputRoutingModel(controller: controller, engine: { engine })
        model.persistSelection = { [weak settings] uid in settings?.output.deviceUID = uid }
        return model
    }

    /// Polls `condition` on the main actor, because the controller publishes its
    /// snapshot through a `Task { @MainActor in … }` hop exactly as the real service
    /// does — so a change lands a turn later, not synchronously.
    static func settle(
        _ condition: @MainActor () -> Bool,
        timeoutSeconds: Double = 2.0
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

// MARK: - The double

/// An `OutputDeviceControlling` that honours a selection and can publish a device-list
/// change, which is the whole of what the routing rules need to be observable.
actor RoutingScriptedController: OutputDeviceControlling {
    private var devices: [OutputDevice]
    private var systemDefaultID: OutputDeviceID?
    private var selectedUID: String?
    private var rates: [OutputDeviceID: Double]
    private var onChange: (@MainActor @Sendable (OutputDeviceSnapshot) -> Void)?

    private(set) var startCount = 0
    private(set) var selectedUIDs: [String?] = []

    init(
        devices: [OutputDevice],
        systemDefaultID: OutputDeviceID?,
        selectedUID: String?,
        rates: [OutputDeviceID: Double]
    ) {
        self.devices = devices
        self.systemDefaultID = systemDefaultID
        self.selectedUID = selectedUID
        self.rates = rates
    }

    func snapshot() -> OutputDeviceSnapshot {
        OutputDeviceSnapshot(devices: devices, systemDefaultID: systemDefaultID, selectedUID: selectedUID)
    }

    func selectDevice(uid: String?) {
        selectedUIDs.append(uid)
        selectedUID = uid
        publish()
    }

    func availableRates(for _: OutputDeviceID) throws -> [Double] {
        [44100, 48000, 96000]
    }

    func currentNominalRate(for deviceID: OutputDeviceID) throws -> Double {
        guard let rate = rates[deviceID] else { throw OutputDeviceError.deviceNotFound(deviceID) }
        return rate
    }

    func setNominalRate(_ rate: Double, on deviceID: OutputDeviceID) async throws {
        rates[deviceID] = rate
    }

    func setOnChange(_ handler: (@MainActor @Sendable (OutputDeviceSnapshot) -> Void)?) {
        onChange = handler
    }

    func start() {
        startCount += 1
        publish()
    }

    func stop() {}

    /// A replug (or an unplug): the device list changes underneath a kept selection,
    /// and both HAL listeners collapse into this one publish.
    func simulateDevices(_ updated: [OutputDevice], systemDefaultID: OutputDeviceID?) {
        devices = updated
        self.systemDefaultID = systemDefaultID
        publish()
    }

    private func publish() {
        guard let onChange else { return }
        let published = snapshot()
        Task { @MainActor in onChange(published) }
    }
}

// MARK: - Selection

@MainActor
@Suite("Output routing — selection")
struct OutputRoutingSelectionTests {
    @Test("Choosing a device persists its UID and routes the engine to its identifier")
    func choosingADevicePersistsAndRoutes() async {
        let harness = OutputRoutingFixtures.Harness("choose")
        defer { harness.tearDown() }
        let settings = harness.settings
        let engine = FakePlaybackEngine()
        let controller = OutputRoutingFixtures.controller()
        let router = OutputRoutingFixtures.router(controller, engine: engine, settings: settings)

        await router.start(selectedUID: nil)
        await router.select(uid: OutputRoutingFixtures.dac.uid)

        #expect(settings.output.deviceUID == OutputRoutingFixtures.dac.uid)
        #expect(engine.outputDeviceID == OutputRoutingFixtures.dac.id)
        #expect(router.activeDevice?.name == OutputRoutingFixtures.dac.name)
    }

    @Test("The persisted value is the UID, never the transient identifier")
    func onlyTheUIDIsPersisted() async {
        let harness = OutputRoutingFixtures.Harness("uid")
        defer { harness.tearDown() }
        let defaults = harness.defaults
        let settings = harness.settings
        let router = OutputRoutingFixtures.router(
            OutputRoutingFixtures.controller(),
            engine: FakePlaybackEngine(),
            settings: settings
        )

        await router.start(selectedUID: nil)
        await router.select(uid: OutputRoutingFixtures.dac.uid)

        let stored = defaults.string(forKey: AppSettingsKeys.outputDeviceUID)
        #expect(stored == OutputRoutingFixtures.dac.uid)
        #expect(stored != String(OutputRoutingFixtures.dac.id))
    }

    @Test("Clearing the selection returns to the system default and clears the stored UID")
    func clearingReturnsToTheSystemDefault() async {
        let harness = OutputRoutingFixtures.Harness("clear")
        defer { harness.tearDown() }
        let defaults = harness.defaults
        let settings = harness.settings
        let engine = FakePlaybackEngine()
        let router = OutputRoutingFixtures.router(
            OutputRoutingFixtures.controller(),
            engine: engine,
            settings: settings
        )

        settings.output.deviceUID = OutputRoutingFixtures.dac.uid
        await router.start(selectedUID: OutputRoutingFixtures.dac.uid)
        await router.select(uid: nil)

        #expect(settings.output.deviceUID == nil)
        #expect(defaults.string(forKey: AppSettingsKeys.outputDeviceUID) == nil)
        #expect(engine.outputDeviceID == OutputRoutingFixtures.builtIn.id)
        #expect(router.snapshot.followsSystemDefault)
    }

    /// The engine seam already restores the prior route synchronously when a device is
    /// refused (`SFBPlaybackEngine+OutputRouting`), so this layer must SWALLOW the
    /// throw rather than add a pre-check of its own — and must still have asked, so a
    /// caller retrying a dead device stays visible in `requestedOutputDeviceIDs`.
    @Test("A refused device is swallowed, leaving the prior route intact")
    func aRefusedDeviceDoesNotPropagate() async {
        let harness = OutputRoutingFixtures.Harness("refused")
        defer { harness.tearDown() }
        let settings = harness.settings
        let engine = FakePlaybackEngine()
        engine.outputDeviceSelectionError = .selectionFailed(
            deviceID: OutputRoutingFixtures.dac.id,
            status: -4
        )
        let router = OutputRoutingFixtures.router(
            OutputRoutingFixtures.controller(),
            engine: engine,
            settings: settings
        )

        await router.start(selectedUID: OutputRoutingFixtures.dac.uid)

        #expect(engine.requestedOutputDeviceIDs.contains(OutputRoutingFixtures.dac.id))
        #expect(engine.outputDeviceID == nil)
        #expect(settings.output.deviceUID == nil)
    }
}

// MARK: - Availability

@MainActor
@Suite("Output routing — availability")
struct OutputRoutingAvailabilityTests {
    /// The failure path the plan calls out: a UID persisted for hardware that is no
    /// longer plugged in must degrade to the system default without a crash, and must
    /// KEEP the selection so a replug restores it.
    @Test("A persisted UID for an absent device falls back to the system default")
    func anAbsentDeviceFallsBack() async {
        let harness = OutputRoutingFixtures.Harness("absent")
        defer { harness.tearDown() }
        let settings = harness.settings
        let engine = FakePlaybackEngine()
        let router = OutputRoutingFixtures.router(
            OutputRoutingFixtures.controller(devices: [OutputRoutingFixtures.builtIn]),
            engine: engine,
            settings: settings
        )

        await router.start(selectedUID: OutputRoutingFixtures.dac.uid)

        #expect(router.snapshot.hasUnavailableSelection)
        #expect(router.snapshot.selectedUID == OutputRoutingFixtures.dac.uid)
        #expect(router.snapshot.selectedDevice == nil)
        #expect(engine.outputDeviceID == OutputRoutingFixtures.builtIn.id)
    }

    @Test("Replugging the remembered device routes back to it with no further choice")
    func replugRestoresTheSelection() async {
        let harness = OutputRoutingFixtures.Harness("replug")
        defer { harness.tearDown() }
        let settings = harness.settings
        let engine = FakePlaybackEngine()
        let controller = OutputRoutingFixtures.controller(devices: [OutputRoutingFixtures.builtIn])
        let router = OutputRoutingFixtures.router(controller, engine: engine, settings: settings)

        await router.start(selectedUID: OutputRoutingFixtures.dac.uid)
        await controller.simulateDevices(
            [OutputRoutingFixtures.builtIn, OutputRoutingFixtures.dac],
            systemDefaultID: OutputRoutingFixtures.builtIn.id
        )

        let routed = await OutputRoutingFixtures.settle {
            engine.outputDeviceID == OutputRoutingFixtures.dac.id
        }
        #expect(routed)
        #expect(!router.snapshot.hasUnavailableSelection)
        #expect(router.selectedDeviceName == OutputRoutingFixtures.dac.name)
    }

    @Test("The pane's rate readout reports the active device's nominal rate")
    func theRateReadoutFollowsTheActiveDevice() async {
        let harness = OutputRoutingFixtures.Harness("rate")
        defer { harness.tearDown() }
        let settings = harness.settings
        let router = OutputRoutingFixtures.router(
            OutputRoutingFixtures.controller(),
            engine: FakePlaybackEngine(),
            settings: settings
        )

        await router.start(selectedUID: OutputRoutingFixtures.dac.uid)
        await router.refreshNominalRate()

        #expect(router.nominalRate == 96000)
    }
}

// MARK: - Persistence

@MainActor
@Suite("Output preferences — persistence")
struct OutputPreferencesPersistenceTests {
    @Test("An install that never chose gets automatic sample-rate matching ON")
    func absentMeansOn() {
        let harness = OutputRoutingFixtures.Harness("default")
        defer { harness.tearDown() }
        let settings = harness.settings

        #expect(settings.output.autoSampleRate)
        #expect(settings.output.deviceUID == nil)
    }

    @Test("Both output scalars round-trip through a fresh settings store")
    func bothScalarsRoundTrip() {
        let harness = OutputRoutingFixtures.Harness("roundtrip")
        defer { harness.tearDown() }
        let defaults = harness.defaults
        let settings = harness.settings

        settings.output.deviceUID = OutputRoutingFixtures.dac.uid
        settings.output.autoSampleRate = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.output.deviceUID == OutputRoutingFixtures.dac.uid)
        #expect(!reloaded.output.autoSampleRate)
    }

    /// One unreadable value must not reset the other — the whole reason this family is
    /// two flat keys instead of one encoded blob.
    @Test("A garbage device UID degrades without disturbing the rate switch")
    func oneBadScalarDegradesAlone() {
        let harness = OutputRoutingFixtures.Harness("degrade")
        defer { harness.tearDown() }
        let defaults = harness.defaults
        defaults.set(false, forKey: AppSettingsKeys.outputAutoSampleRate)
        defaults.set(["not", "a", "uid"], forKey: AppSettingsKeys.outputDeviceUID)

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.output.deviceUID == nil)
        #expect(!reloaded.output.autoSampleRate)
    }
}
