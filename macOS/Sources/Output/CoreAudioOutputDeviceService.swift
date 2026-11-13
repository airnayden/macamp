// CoreAudioOutputDeviceService — the production `OutputDeviceControlling`.
//
// An `actor`, which is what keeps two promises at once: HAL property reads are
// synchronous C calls that can block for milliseconds, and the nominal-rate wait can
// run for two seconds — neither may happen on the main actor. Callers `await` and are
// suspended, never blocked.
//
// # Where the listener callbacks land
// `AudioObjectAddPropertyListenerBlock` fires on an arbitrary system thread, so this
// service hands it a private SERIAL queue to hop onto first. From there the block
// enters the actor, and the actor delivers the resulting snapshot on the MAIN ACTOR.
// Three hops, each one deliberate: arbitrary thread → serial queue → actor → main.
import CoreAudio
import Foundation
import Models
import Services

actor CoreAudioOutputDeviceService: OutputDeviceControlling {
    private struct ListenerRegistration {
        let selector: AudioObjectPropertySelector
        let block: AudioObjectPropertyListenerBlock
    }

    private let listenerQueue = DispatchQueue(label: "com.example.macamp.output.device-listener")
    private var cached = OutputDeviceSnapshot()
    private var onChange: (@MainActor @Sendable (OutputDeviceSnapshot) -> Void)?
    private var registrations: [ListenerRegistration] = []
    private var isObserving = false

    init(selectedUID: String? = nil) {
        cached = OutputDeviceSnapshot(selectedUID: selectedUID)
    }

    // MARK: - OutputDeviceControlling

    func snapshot() -> OutputDeviceSnapshot {
        cached
    }

    func selectDevice(uid: String?) {
        guard cached.selectedUID != uid else { return }
        cached.selectedUID = uid
        publish()
    }

    func availableRates(for deviceID: OutputDeviceID) throws -> [Double] {
        try requireAttached(deviceID)
        return try CoreAudioNominalRate.available(of: AudioObjectID(deviceID))
    }

    func currentNominalRate(for deviceID: OutputDeviceID) throws -> Double {
        try requireAttached(deviceID)
        return try CoreAudioNominalRate.current(of: AudioObjectID(deviceID))
    }

    func setNominalRate(_ rate: Double, on deviceID: OutputDeviceID) async throws {
        try requireAttached(deviceID)
        let object = AudioObjectID(deviceID)
        let available = try CoreAudioNominalRate.available(of: object)
        guard available.contains(where: { OutputDeviceRateChange.matches($0, rate) }) else {
            throw OutputDeviceError.rateUnsupported(rate: rate, deviceID: deviceID, available: available)
        }
        let current = try CoreAudioNominalRate.current(of: object)
        guard !OutputDeviceRateChange.matches(current, rate) else { return }
        try await CoreAudioNominalRate.set(
            rate,
            on: object,
            timeoutSeconds: OutputDeviceRateChange.boundedWaitSeconds
        )
    }

    func setOnChange(_ handler: (@MainActor @Sendable (OutputDeviceSnapshot) -> Void)?) {
        onChange = handler
    }

    func start() {
        guard !isObserving else { return }
        isObserving = true
        addListener(for: kAudioHardwarePropertyDevices)
        addListener(for: kAudioHardwarePropertyDefaultOutputDevice)
        cached = reading(selectedUID: cached.selectedUID)
        publish()
    }

    func stop() {
        guard isObserving else { return }
        isObserving = false
        for registration in registrations {
            var target = CoreAudioProperty.address(registration.selector)
            AudioObjectRemovePropertyListenerBlock(
                CoreAudioDeviceEnumerator.systemObject,
                &target,
                listenerQueue,
                registration.block
            )
        }
        registrations.removeAll()
    }

    // MARK: - Internals

    /// Re-reads the HAL and republishes only when something actually changed.
    ///
    /// The equality guard matters because both listeners fire for one physical event:
    /// unplugging the current default device changes the device list AND the default,
    /// and an unguarded refresh would publish the same settled snapshot twice.
    private func refresh() {
        let updated = reading(selectedUID: cached.selectedUID)
        guard updated != cached else { return }
        cached = updated
        publish()
    }

    private func reading(selectedUID: String?) -> OutputDeviceSnapshot {
        OutputDeviceSnapshot(
            devices: (try? CoreAudioDeviceEnumerator.outputDevices()) ?? [],
            systemDefaultID: CoreAudioDeviceEnumerator.systemDefaultOutputDeviceID(),
            selectedUID: selectedUID
        )
    }

    private func addListener(for selector: AudioObjectPropertySelector) {
        var target = CoreAudioProperty.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { await self?.refresh() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            CoreAudioDeviceEnumerator.systemObject,
            &target,
            listenerQueue,
            block
        )
        guard status == noErr else { return }
        registrations.append(ListenerRegistration(selector: selector, block: block))
    }

    /// Validates against the LIVE HAL, not the cached snapshot.
    ///
    /// A caller can legitimately hold an id from before the last unplug, and the
    /// cached snapshot may not have caught up yet; asking the device itself is both
    /// authoritative and one cheap size query.
    private func requireAttached(_ deviceID: OutputDeviceID) throws {
        guard CoreAudioDeviceEnumerator.isOutputCapable(AudioObjectID(deviceID)) else {
            throw OutputDeviceError.deviceNotFound(deviceID)
        }
    }

    private func publish() {
        guard let onChange else { return }
        let snapshot = cached
        Task { @MainActor in onChange(snapshot) }
    }
}
