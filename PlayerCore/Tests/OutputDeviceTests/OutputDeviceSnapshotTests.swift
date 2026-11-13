import Models
import Services
import Testing

@Suite("OutputDeviceSnapshot resolution")
struct OutputDeviceSnapshotTests {
    private let devices: [OutputDevice] = [.builtIn, .usbDAC]

    @Test("No selection follows the system default")
    func noSelectionFollowsSystemDefault() {
        let snapshot = OutputDeviceSnapshot(devices: devices, systemDefaultID: OutputDevice.builtIn.id)

        #expect(snapshot.followsSystemDefault)
        #expect(snapshot.selectedDevice == nil)
        #expect(snapshot.activeDeviceID == OutputDevice.builtIn.id)
        #expect(!snapshot.hasUnavailableSelection)
    }

    @Test("An attached selection wins over the system default")
    func attachedSelectionWins() {
        let snapshot = OutputDeviceSnapshot(
            devices: devices,
            systemDefaultID: OutputDevice.builtIn.id,
            selectedUID: OutputDevice.usbDAC.uid
        )

        #expect(!snapshot.followsSystemDefault)
        #expect(snapshot.selectedDevice == OutputDevice.usbDAC)
        #expect(snapshot.activeDeviceID == OutputDevice.usbDAC.id)
        #expect(!snapshot.hasUnavailableSelection)
    }

    @Test("An unplugged selection falls back to the default but is not forgotten")
    func unpluggedSelectionFallsBack() {
        let snapshot = OutputDeviceSnapshot(
            devices: [.builtIn],
            systemDefaultID: OutputDevice.builtIn.id,
            selectedUID: OutputDevice.usbDAC.uid
        )

        #expect(snapshot.selectedDevice == nil)
        #expect(snapshot.activeDeviceID == OutputDevice.builtIn.id)
        #expect(snapshot.hasUnavailableSelection)
        #expect(snapshot.selectedUID == OutputDevice.usbDAC.uid)
    }

    @Test("A machine with no audio hardware resolves to no active device")
    func noHardwareResolvesToNil() {
        let snapshot = OutputDeviceSnapshot()

        #expect(snapshot.devices.isEmpty)
        #expect(snapshot.activeDeviceID == nil)
        #expect(snapshot.followsSystemDefault)
    }

    @Test("Rate matching tolerates HAL float noise but never merges real rates")
    func rateMatchingTolerance() {
        #expect(OutputDeviceRateChange.matches(44100, 44100.000001))
        #expect(OutputDeviceRateChange.matches(48000, 47999.6))
        #expect(!OutputDeviceRateChange.matches(44100, 48000))
        #expect(!OutputDeviceRateChange.matches(96000, 88200))
    }
}
