// SFBPlaybackEngine+OutputRouting — which device the engine plays to, and what
// format the processing chain is running at.
//
// Split out of `SFBPlaybackEngine.swift` because that file sits near SwiftLint's
// 400-line ceiling; the split follows the module's existing `Type+Facet.swift`
// pattern. Extension members in the SAME module satisfy protocol requirements and
// are entered into the witness table, so these dispatch dynamically through
// `any PlaybackEngine` exactly as the transport members do.
//
// DEVICE SET IS LIVE — NO STOP/START. `SFBAudioPlayer` writes the identifier to
// `AVAudioEngine.outputNode`'s `AUAudioUnit.deviceID` on the running engine, so a
// mid-song device change keeps rendering. The engine's lifecycle belongs to
// `AudioPlayer` (it asserts on external mutation), so bracketing the set with
// `engine.stop()`/`start()` would be both unnecessary and a contract violation.
//
// SFB's `AUAudioObjectID`, CoreAudio's `AudioDeviceID` and ``OutputDeviceID`` are
// three spellings of `UInt32`, which is what lets this seam speak the portable
// alias with no cast and no CoreAudio import.
//
// This file imports only AVFAudio + Foundation + Models + SFBAudioEngine; it MUST
// NOT import AppKit or UIKit (PlayerCore portability invariant).
import AVFAudio
import Foundation
import Models
@preconcurrency import SFBAudioEngine

public extension SFBPlaybackEngine {
    /// The identifier CoreAudio reserves for "no such object" (`kAudioObjectUnknown`).
    ///
    /// Spelled as a literal rather than imported: naming the CoreAudio constant
    /// would pull the HAL into a module that must also build for iOS.
    private static var unknownDeviceID: OutputDeviceID {
        0
    }

    var outputDeviceID: OutputDeviceID? {
        #if os(macOS)
            let identifier = player.outputDeviceID
            return identifier == Self.unknownDeviceID ? nil : identifier
        #else
            nil
        #endif
    }

    func setOutputDeviceID(_ deviceID: OutputDeviceID) throws {
        #if os(macOS)
            let previous = player.outputDeviceID
            do {
                try player.setOutputDeviceID(deviceID)
            } catch {
                restoreOutputDevice(previous)
                throw OutputDeviceSelectionError.selectionFailed(
                    deviceID: deviceID,
                    status: Int32(truncatingIfNeeded: (error as NSError).code)
                )
            }
        #else
            throw OutputDeviceSelectionError.unsupportedOnPlatform
        #endif
    }

    #if os(macOS)
        /// Puts `previous` back when a refused selection left the output node with
        /// no device at all.
        ///
        /// MEASURED, and the reason this method exists: `AUAudioUnit setDeviceID:`
        /// rejecting an identifier is NOT a no-op. It reports the error AND leaves
        /// `deviceID` at `kAudioObjectUnknown`, so `AVAudioEngine` posts a
        /// configuration change whose output format has zero channels, and SFB's
        /// own `handleAudioEngineConfigurationChange` reconnects with it —
        /// `AVFAudio` then RAISES `IsFormatSampleRateAndChannelCountValid(format)`
        /// and the process dies. Picking a device that has since been unplugged is
        /// an ordinary user action, so the seam repairs the node synchronously,
        /// before the notification block that would read it can run.
        ///
        /// Best-effort by construction: if the restore is itself refused there is
        /// nothing further this layer can do, and the original refusal is still
        /// what the caller is told about.
        private func restoreOutputDevice(_ previous: OutputDeviceID) {
            guard previous != Self.unknownDeviceID, player.outputDeviceID != previous else { return }
            try? player.setOutputDeviceID(previous)
        }
    #endif

    /// The format the processing chain is wired at, read from the chain's own tap
    /// host rather than from the player's source node.
    ///
    /// The source node's format is documented as STALE during SFB's
    /// `reconfigureProcessingGraph` — which is exactly when a consumer most wants
    /// to know the new rate — whereas the tap host's output format is set by the
    /// `connect(_:to:format:)` the chain just made. It is also the format the
    /// spectrum tap delivers buffers in, so a metering consumer reading the
    /// channel count here is reading the channel count it will actually receive.
    var currentConnectionFormat: AVAudioFormat {
        Self.connectionFormat(for: processingChain.tapHost.outputFormat(forBus: 0))
    }
}
