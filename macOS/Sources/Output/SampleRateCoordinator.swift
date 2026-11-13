// SampleRateCoordinator — retunes the output device to a track's own rate at load.
//
// Installed on `PlaybackCoordinator.preLoadHook`, so it runs immediately BEFORE
// `engine.load` on the two explicit-start paths (`activate` / `activateManual`) and
// on no other. The gapless pre-schedule path deliberately never reaches here:
// retuning a device that is mid-render glitches the stream still playing, so a
// device is only ever retuned at an explicit track start.
//
// Three rules the plan fixes exactly, and which the tests pin:
//
//   1. An unknown/`nil` stored sample rate issues NO set at all — a track whose rate
//      was never scanned must not drag the device to a guess.
//   2. The bounded wait belongs to `OutputDeviceControlling` (2 s, shared by the
//      CoreAudio conformer and the Fake). When it times out the set has ALREADY
//      reached the HAL, so this type stops waiting and lets the load proceed. It
//      never reverts and never re-issues — a late confirmation is allowed to land.
//   3. It registers no change handler, so a device confirming after the wait has
//      elapsed has nothing here to call back into. That, rather than a guard, is
//      what makes a stale completion incapable of writing state or re-triggering a
//      reconfigure.
//
// This type is macOS-shell code by design even though it names no HAL symbol: it is
// the composition of a portable seam with a platform policy, and PlayerCore holds
// only the `@Sendable` closure seam it is installed through.
import AudioEngine
import Foundation
import Models
import Services

/// Prepares the output device's nominal rate for the track about to load.
@MainActor
final class SampleRateCoordinator {
    private let controller: any OutputDeviceControlling
    private let activeDeviceID: @MainActor () -> OutputDeviceID?
    private let isEnabled: @MainActor () -> Bool

    /// - Parameters:
    ///   - controller: The output-device seam (`CoreAudioOutputDeviceService` live).
    ///   - activeDeviceID: The device the engine is routed to right now, read fresh
    ///     per track because the identifier is transient across a replug.
    ///   - isEnabled: The `outputAutoSampleRate` preference, read fresh per track so
    ///     a mid-session flip takes effect on the very next track.
    init(
        controller: any OutputDeviceControlling,
        activeDeviceID: @escaping @MainActor () -> OutputDeviceID?,
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        self.controller = controller
        self.activeDeviceID = activeDeviceID
        self.isEnabled = isEnabled
    }

    /// The closure to assign to `PlaybackCoordinator.preLoadHook`.
    ///
    /// Captures `self` STRONGLY on purpose: the playback coordinator's hook is the
    /// only owner of this object, so a weak capture would deallocate it the instant
    /// the composition root returned.
    func preLoadHook() -> @Sendable (TrackRef) async -> Void {
        { [self] track in await prepare(for: track) }
    }

    /// Retunes the device for `track`, returning once the device confirmed, the
    /// bounded wait elapsed, or there was nothing to do.
    func prepare(for track: TrackRef) async {
        guard isEnabled(),
              let rate = Self.nominalRate(of: track),
              let deviceID = activeDeviceID()
        else { return }
        let controller = controller
        await Task.detached(priority: .userInitiated) {
            try? await Self.retune(to: rate, on: deviceID, using: controller)
        }.value
    }

    /// The device rate a track asks for, or `nil` when the library never recorded
    /// one — the "issue no set at all" case.
    nonisolated static func nominalRate(of track: TrackRef) -> Double? {
        guard let sampleRate = track.sampleRate, sampleRate > 0 else { return nil }
        return Double(sampleRate)
    }

    /// Both guards are this type's own, not the seam's: the seam records every
    /// request it is handed, so asking it to set a rate the device already runs at
    /// would look — correctly — like a rate change nobody needed.
    private nonisolated static func retune(
        to rate: Double,
        on deviceID: OutputDeviceID,
        using controller: any OutputDeviceControlling
    ) async throws {
        let current = try await controller.currentNominalRate(for: deviceID)
        guard !OutputDeviceRateChange.matches(current, rate) else { return }
        let available = try await controller.availableRates(for: deviceID)
        guard available.contains(where: { OutputDeviceRateChange.matches($0, rate) }) else { return }
        try await controller.setNominalRate(rate, on: deviceID)
    }
}
