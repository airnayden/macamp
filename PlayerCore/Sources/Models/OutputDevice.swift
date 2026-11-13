// OutputDevice — the portable vocabulary for an audio output device.
//
// PlayerCore never learns that these values come from CoreAudio's HAL. Every
// macOS-only symbol (`AudioObjectID`, `kAudioHardwarePropertyDevices`,
// `kAudioDevicePropertyNominalSampleRate`, …) lives in the macOS shell's
// `Sources/Output/` module behind the `OutputDeviceControlling` seam in `Services`.
// This file therefore imports Foundation and nothing else — the `ios-portability`
// CI job builds `PlayerCore-Package` for the iOS Simulator, where those symbols do
// not exist, so a leak across the seam fails the build rather than the review.
//
// It lives in `Models` rather than beside the protocol in `Services` for one
// concrete reason: `AudioEngine` (todo 14's `PlaybackEngine.outputDeviceID`) needs
// the identifier type, and `AudioEngine` cannot import `Services` without inverting
// the module graph. `Models` is the one layer both sides already depend on.
import Foundation

/// A device identifier as the platform's audio HAL hands it out.
///
/// `UInt32` deliberately, NOT CoreAudio's `AudioDeviceID`: that typedef exists only
/// on macOS, and naming it here would break the iOS build of this package. The two
/// are the same underlying type, so the macOS shell crosses the seam by plain
/// assignment — and SFBAudioEngine's `AUAudioObjectID` is a third spelling of the
/// same `UInt32`, which is what lets the engine seam speak this type without a cast.
public typealias OutputDeviceID = UInt32

/// One output-capable audio device.
///
/// Only the three fields a picker and a rate coordinator actually need. Nothing
/// here is a handle: the struct is a snapshot of what the device looked like at
/// enumeration time and stays valid (as a value) even after the device unplugs.
public struct OutputDevice: Sendable, Equatable, Hashable, Identifiable, Codable {
    /// The transient HAL identifier.
    ///
    /// Valid only while the device stays attached, and reused for a *different*
    /// device after a replug. Never persist it — persist ``uid`` instead.
    public let id: OutputDeviceID

    /// The device's persistent unique identifier.
    ///
    /// Stable across replug, reboot and OS update, which makes it the only field
    /// safe to write into preferences. Resolving it back to an ``id`` can fail
    /// (the device may simply not be there), and that failure is the normal
    /// "fall back to the system default" path, not an error.
    public let uid: String

    /// The device's human-readable name, as the system reports it.
    ///
    /// Already localized by the HAL; it is a device's own name, never app copy, so
    /// it is displayed verbatim and never routed through a String Catalog.
    public let name: String

    public init(id: OutputDeviceID, uid: String, name: String) {
        self.id = id
        self.uid = uid
        self.name = name
    }
}
