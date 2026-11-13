// OutputDeviceSelectionError — what a ``PlaybackEngine`` throws when it cannot
// route its output to the requested device.
//
// This is the ENGINE's error, deliberately distinct from the `Services` layer's
// `OutputDeviceError` (enumeration / nominal-rate failures against the HAL):
// `AudioEngine` cannot import `Services` without inverting the module graph, and
// the two failures are raised by different subsystems anyway. `Models` is the one
// layer both sides already depend on, which is why ``OutputDeviceID`` — and only
// ``OutputDeviceID`` — is shared between them.
//
// The underlying platform status crosses as a plain `Int32`, NOT `OSStatus`, for
// exactly the reason `OutputDeviceError.platformFailure` does: `OSStatus` is a
// CoreAudio-adjacent spelling and PlayerCore must stay buildable for iOS, where
// the HAL does not exist. `Int32` is the same width and carries the same value.
//
// This file imports only Foundation + Models; it MUST NOT import AppKit or UIKit
// (PlayerCore portability invariant).
import Foundation
import Models

/// A refusal to route a playback engine's output to a particular device.
///
/// Raised by ``PlaybackEngine/setOutputDeviceID(_:)`` only. A throw means the
/// ROUTE was not changed — the engine keeps rendering to whatever device it was
/// already using, and its transport state is untouched. Selecting an output
/// device is never a reason to interrupt playback.
public enum OutputDeviceSelectionError: Error, Sendable, Equatable, Hashable {
    /// The platform exposes no per-player output-device selection.
    ///
    /// iOS is the case that matters: routing there belongs to `AVAudioSession`
    /// and the system, so `SFBAudioPlayer` compiles its output-device API out
    /// entirely (`#if !TARGET_OS_IPHONE`).
    case unsupportedOnPlatform

    /// The platform refused the device.
    ///
    /// The usual cause is an identifier that no longer names an attached device
    /// — HAL identifiers are transient and are reused after a replug, which is
    /// why a device is persisted by UID and resolved to an id just before use.
    /// - Parameters:
    ///   - deviceID: the identifier that was refused.
    ///   - status: the underlying platform error code.
    case selectionFailed(deviceID: OutputDeviceID, status: Int32)
}
