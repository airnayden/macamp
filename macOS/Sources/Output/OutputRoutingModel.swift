// OutputRoutingModel — the Output pane's device picker, and the app's one router.
//
// It is the single owner of the `OutputDeviceControlling` change seam, which is why
// it lives on `AppEnvironment` rather than inside the pane: the seam is single-slot,
// a replug must re-route playback whether or not Settings happens to be open, and
// `SampleRateCoordinator` deliberately registers no handler of its own.
//
// ── WHAT IS PERSISTED, AND WHAT IS RESOLVED ──────────────────────────────────
//
// The listener picks a `uid`; the engine is routed by `id`. Everything between the
// two is `OutputDeviceSnapshot`'s: `activeDeviceID` already falls back to the system
// default when the chosen device is unplugged, and `hasUnavailableSelection` already
// says so — so nothing here re-derives either. The selection is KEPT while its device
// is away, so replugging restores it without the listener choosing again.
//
// ── NO PRE-CHECK BEFORE A SET ────────────────────────────────────────────────
//
// `route(to:)` hands the identifier straight to the engine seam and swallows a
// refusal. A refused `setOutputDeviceID` already restores the prior route
// synchronously inside `SFBPlaybackEngine+OutputRouting`, so a "is this device still
// there?" guard here would be a second, racier copy of a repair that has already
// happened — and it would need HAL queries this layer has no business making. The one
// guard that IS here compares against the route in effect, which is idempotence (both
// HAL listeners fire for a single unplug), not validation.
import AudioEngine
import Foundation
import Models
import Observation
import Services

/// The live output-device list, the chosen device, and the route it produces.
@MainActor
@Observable
final class OutputRoutingModel {
    /// The device list + selection as the controller last published them.
    private(set) var snapshot = OutputDeviceSnapshot()
    /// The active device's nominal rate in Hz, or `nil` while it is unknown (no
    /// device, or the HAL refused the read).
    private(set) var nominalRate: Double?
    /// The chosen device's last-seen name, kept across an unplug so the picker can
    /// still NAME the remembered selection — a bare UID is opaque to a listener.
    private(set) var selectedDeviceName: String?

    /// Shared with `SampleRateCoordinator` so ONE service owns `start()`/`stop()` and
    /// the change handler — a second instance would fight this one over both.
    @ObservationIgnored let controller: any OutputDeviceControlling

    /// Writes the chosen UID back to `AppSettings`. Assigned by
    /// ``AppEnvironment/connectOutputRouting(settings:)``, which is the only place
    /// that can see both this model and the settings store.
    @ObservationIgnored var persistSelection: (@MainActor (String?) -> Void)?

    @ObservationIgnored private let engine: @MainActor () -> (any PlaybackEngine)?

    init(
        controller: any OutputDeviceControlling,
        engine: @escaping @MainActor () -> (any PlaybackEngine)?
    ) {
        self.controller = controller
        self.engine = engine
    }

    /// The device the engine is routed to right now, or `nil` when the HAL offered
    /// none. Resolved from ``OutputDeviceSnapshot/activeDeviceID``, so it is the
    /// chosen device when present and the system default when it is not.
    var activeDevice: OutputDevice? {
        guard let activeDeviceID = snapshot.activeDeviceID else { return nil }
        return snapshot.devices.first { $0.id == activeDeviceID }
    }

    /// Adopts the persisted selection, starts observing the HAL, and routes.
    func start(selectedUID: String?) async {
        await controller.setOnChange { [weak self] published in
            self?.adopt(published)
        }
        await controller.selectDevice(uid: selectedUID)
        await controller.start()
        await adopt(controller.snapshot())
    }

    /// Chooses `uid` (`nil` ⇒ follow the system default): persists it, tells the
    /// controller, then re-routes from the snapshot that comes back.
    func select(uid: String?) async {
        persistSelection?(uid)
        await controller.selectDevice(uid: uid)
        await adopt(controller.snapshot())
    }

    /// Re-reads the active device's nominal rate for the pane's readout.
    func refreshNominalRate() async {
        guard let deviceID = snapshot.activeDeviceID else {
            nominalRate = nil
            return
        }
        nominalRate = try? await controller.currentNominalRate(for: deviceID)
    }

    private func adopt(_ published: OutputDeviceSnapshot) {
        snapshot = published
        if published.selectedUID == nil {
            selectedDeviceName = nil
        } else if let name = published.selectedDevice?.name {
            selectedDeviceName = name
        }
        route(to: published.activeDeviceID)
        Task { await refreshNominalRate() }
    }

    private func route(to deviceID: OutputDeviceID?) {
        guard let deviceID, let engine = engine(), engine.outputDeviceID != deviceID else { return }
        try? engine.setOutputDeviceID(deviceID)
    }
}
