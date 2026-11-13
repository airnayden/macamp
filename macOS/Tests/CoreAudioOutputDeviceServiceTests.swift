import CoreAudio
import Foundation
@testable import MacAMP
import Models
import Services
import Testing

/// Whether this machine has any CoreAudio output hardware at all.
///
/// A headless CI runner legitimately has none, and a suite that failed there would be
/// asserting the runner's configuration rather than MacAMP's code. The
/// hardware-dependent cases below gate on this and are REPORTED AS SKIPPED with a
/// reason, so an empty run is visible in the log rather than silently green.
enum CoreAudioProbe {
    static var hasOutputDevice: Bool {
        !(((try? CoreAudioDeviceEnumerator.outputDevices()) ?? []).isEmpty)
    }

    static let skipReason: Comment =
        "No CoreAudio output device on this machine (headless CI) — HAL enumeration coverage skipped."
}

@MainActor
final class OutputSnapshotRecorder {
    private(set) var snapshots: [OutputDeviceSnapshot] = []

    func record(_ snapshot: OutputDeviceSnapshot) {
        snapshots.append(snapshot)
    }

    var count: Int {
        snapshots.count
    }
}

@MainActor
func waitForOutputSnapshot(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
@Suite("CoreAudio output device service", .serialized)
struct CoreAudioOutputDeviceServiceTests {
    private let missingDeviceID: OutputDeviceID = 0xFFFF_FFFE

    // MARK: - Hardware-dependent

    @Test(
        "Enumerates output devices with a non-empty, unique identity",
        .enabled(if: CoreAudioProbe.hasOutputDevice, CoreAudioProbe.skipReason)
    )
    func enumeratesOutputDevices() throws {
        let devices = try CoreAudioDeviceEnumerator.outputDevices()

        #expect(!devices.isEmpty)
        #expect(devices.allSatisfy { !$0.uid.isEmpty })
        #expect(devices.allSatisfy { !$0.name.isEmpty })
        #expect(Set(devices.map(\.id)).count == devices.count)
        #expect(Set(devices.map(\.uid)).count == devices.count)
    }

    @Test(
        "The system default output device is one of the enumerated devices",
        .enabled(if: CoreAudioProbe.hasOutputDevice, CoreAudioProbe.skipReason)
    )
    func systemDefaultIsEnumerated() throws {
        let devices = try CoreAudioDeviceEnumerator.outputDevices()
        let defaultID = try #require(CoreAudioDeviceEnumerator.systemDefaultOutputDeviceID())

        #expect(devices.contains { $0.id == defaultID })
    }

    @Test(
        "A device advertises the rate it is currently running at",
        .enabled(if: CoreAudioProbe.hasOutputDevice, CoreAudioProbe.skipReason)
    )
    func currentRateIsAdvertised() async throws {
        let service = CoreAudioOutputDeviceService()
        let defaultID = try #require(CoreAudioDeviceEnumerator.systemDefaultOutputDeviceID())

        let current = try await service.currentNominalRate(for: defaultID)
        let available = try await service.availableRates(for: defaultID)

        #expect(current > 0)
        #expect(available == available.sorted())
        #expect(available.contains { OutputDeviceRateChange.matches($0, current) })
    }

    @Test(
        "start() publishes the live device list on the main actor",
        .enabled(if: CoreAudioProbe.hasOutputDevice, CoreAudioProbe.skipReason)
    )
    func startPublishesLiveDevices() async throws {
        let service = CoreAudioOutputDeviceService()
        let recorder = OutputSnapshotRecorder()
        await service.setOnChange { @MainActor @Sendable snapshot in recorder.record(snapshot) }

        await service.start()
        #expect(await waitForOutputSnapshot { recorder.count >= 1 })
        let published = try #require(recorder.snapshots.last)
        await service.stop()

        #expect(!published.devices.isEmpty)
        #expect(published.activeDeviceID != nil)
        #expect(published.followsSystemDefault)
    }

    // MARK: - Hardware-independent

    @Test("An id that names no attached device is a typed deviceNotFound")
    func missingDeviceIsTyped() async {
        let service = CoreAudioOutputDeviceService()

        await #expect(throws: OutputDeviceError.deviceNotFound(missingDeviceID)) {
            try await service.availableRates(for: missingDeviceID)
        }
        await #expect(throws: OutputDeviceError.deviceNotFound(missingDeviceID)) {
            try await service.setNominalRate(48000, on: missingDeviceID)
        }
    }

    @Test("A remembered selection for an absent device is kept, not discarded")
    func absentSelectionIsRemembered() async {
        let service = CoreAudioOutputDeviceService(selectedUID: "NoSuchDevice-0000")

        let snapshot = await service.snapshot()

        #expect(snapshot.selectedUID == "NoSuchDevice-0000")
        #expect(snapshot.selectedDevice == nil)
        #expect(snapshot.hasUnavailableSelection)
        #expect(!snapshot.followsSystemDefault)
    }

    @Test("stop() is idempotent and safe before start()")
    func stopIsIdempotent() async {
        let service = CoreAudioOutputDeviceService()

        await service.stop()
        await service.start()
        await service.stop()
        await service.stop()

        #expect(await service.snapshot().selectedUID == nil)
    }

    @Test("A continuous HAL rate range is reduced to the standard rates inside it")
    func continuousRangeIsReducedToStandardRates() {
        let continuous = AudioValueRange(mMinimum: 44100, mMaximum: 96000)
        let discrete = AudioValueRange(mMinimum: 192_000, mMaximum: 192_000)

        let rates = CoreAudioRateCatalog.rates(in: [continuous, discrete])

        #expect(rates == [44100, 48000, 64000, 88200, 96000, 192_000])
    }
}
