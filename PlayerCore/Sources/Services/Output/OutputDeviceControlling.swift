// OutputDeviceControlling — the seam over the platform's audio-device control API.
//
// This is the ONE abstraction that lets PlayerCore (and, through it, the shared view
// models) choose an output device and retune its sample rate without ever naming a
// CoreAudio HAL symbol. `AudioObjectID`, `kAudioHardwarePropertyDevices`,
// `kAudioDevicePropertyStreams`, `kAudioDevicePropertyNominalSampleRate` and every
// listener call live in exactly one place: `macOS/Sources/Output/`. iOS has no HAL
// device control at all, so a shell that cannot conform this protocol simply does
// not — the seam is what keeps `PlayerCore-Package` building for the iOS Simulator.
//
// This file imports Foundation and `Models` only, and MUST NOT import CoreAudio,
// AudioToolbox, AppKit or UIKit. `scripts/check-playercore-portability.sh` catches
// the UI frameworks; the `ios-portability` CI job catches the HAL.
import Foundation
import Models

/// Everything the output-device seam publishes at one instant.
///
/// One snapshot rather than a handful of independently-readable properties, for the
/// same reason `KaraokeQueueSnapshot` is one value: the device list and the system
/// default change together (unplugging the current default does both at once), and
/// two properties read a moment apart can disagree in a way a single value cannot.
public struct OutputDeviceSnapshot: Sendable, Equatable {
    /// Every attached output-capable device, in HAL enumeration order.
    public var devices: [OutputDevice]

    /// The device the system currently routes to, or `nil` when there is none
    /// (no audio hardware at all — a real state on a headless CI machine).
    public var systemDefaultID: OutputDeviceID?

    /// The UID the user explicitly picked, or `nil` to follow the system default.
    ///
    /// A UID rather than an ``OutputDeviceID`` because this is the value that gets
    /// persisted: HAL identifiers are transient and are reused for other devices
    /// after a replug.
    public var selectedUID: String?

    public init(
        devices: [OutputDevice] = [],
        systemDefaultID: OutputDeviceID? = nil,
        selectedUID: String? = nil
    ) {
        self.devices = devices
        self.systemDefaultID = systemDefaultID
        self.selectedUID = selectedUID
    }

    /// Whether playback follows whatever the system default output device is.
    ///
    /// DERIVED from ``selectedUID`` rather than stored beside it. A stored flag and a
    /// stored UID can contradict each other ("follows the default" while a device is
    /// also selected); deriving it makes that state unrepresentable.
    public var followsSystemDefault: Bool {
        selectedUID == nil
    }

    /// The explicitly-selected device, when it is attached right now.
    ///
    /// `nil` both when nothing is selected AND when the remembered device is absent.
    /// The second case is the ordinary "you unplugged your DAC" path — see
    /// ``activeDeviceID``, which falls back on its own.
    public var selectedDevice: OutputDevice? {
        guard let selectedUID else { return nil }
        return devices.first { $0.uid == selectedUID }
    }

    /// The device audio should actually go to.
    ///
    /// The explicit selection when it is attached, otherwise the system default. The
    /// fallback is what makes an unplugged remembered device a non-event: the
    /// selection is *kept* (so replugging restores it) while playback carries on
    /// through the default.
    public var activeDeviceID: OutputDeviceID? {
        selectedDevice?.id ?? systemDefaultID
    }

    /// The remembered selection exists but its device is not attached.
    ///
    /// The one state a picker needs to render differently — "MyDAC (unavailable)"
    /// rather than silently showing System Default and losing the user's choice.
    public var hasUnavailableSelection: Bool {
        selectedUID != nil && selectedDevice == nil
    }
}

/// Lists, observes and retunes the platform's audio output devices.
///
/// `Sendable`, not `@MainActor`: conformers are actors so that HAL property reads —
/// which are synchronous C calls that can block for milliseconds — and the bounded
/// rate-change wait both run off the main actor. Callers `await` and are suspended,
/// never blocked.
///
/// # Threading
/// HAL property listeners fire on arbitrary system threads. A conformer must funnel
/// them through a serial queue (or its own actor executor) and deliver
/// ``setOnChange(_:)``'s handler on the MAIN ACTOR — which is why the handler type
/// says `@MainActor` rather than leaving it to a convention a call site can forget.
///
/// # Lifecycle
/// Nothing is observed until ``start()``. ``stop()`` removes every listener and is
/// idempotent, so a composition root can call it from a teardown path unconditionally.
public protocol OutputDeviceControlling: Sendable {
    /// The current device list, system default and explicit selection.
    func snapshot() async -> OutputDeviceSnapshot

    /// Picks an explicit device by its persistent UID, or `nil` to follow the system
    /// default.
    ///
    /// A UID that names no attached device is REMEMBERED, not rejected: the device
    /// may be plugged back in, and discarding the choice on a transient absence is
    /// exactly the behaviour that loses a user's settings. See
    /// ``OutputDeviceSnapshot/hasUnavailableSelection``.
    func selectDevice(uid: String?) async

    /// Every nominal sample rate the device advertises, ascending.
    func availableRates(for deviceID: OutputDeviceID) async throws -> [Double]

    /// The device's current nominal sample rate.
    func currentNominalRate(for deviceID: OutputDeviceID) async throws -> Double

    /// Retunes the device, waiting up to
    /// ``OutputDeviceRateChange/boundedWaitSeconds`` for it to report the new rate.
    ///
    /// A device already at `rate` is a no-op: no set is issued and no wait happens.
    ///
    /// - Throws: ``OutputDeviceError/rateUnsupported(rate:deviceID:available:)`` when
    ///   the device does not advertise the rate (no set is issued),
    ///   ``OutputDeviceError/rateChangeTimedOut(rate:deviceID:afterSeconds:)`` when the
    ///   device did not confirm in time (the set WAS issued — callers proceed, they
    ///   never revert), or ``OutputDeviceError/platformFailure(operation:status:)``.
    func setNominalRate(_ rate: Double, on deviceID: OutputDeviceID) async throws

    /// Replaces the change handler, which is invoked on the main actor whenever the
    /// device list, the system default or the explicit selection changes.
    ///
    /// Passing `nil` detaches the current handler without stopping observation.
    func setOnChange(_ handler: (@MainActor @Sendable (OutputDeviceSnapshot) -> Void)?) async

    /// Begins observing device changes and publishes a first snapshot.
    func start() async

    /// Stops observing. Idempotent.
    func stop() async
}
