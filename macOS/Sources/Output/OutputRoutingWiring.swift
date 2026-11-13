// OutputRoutingWiring — installs the device router and the sample-rate coordinator.
//
// A sibling-file extension rather than lines inside `AppEnvironment.swift` for the
// reason `DownloadsUIWiring` is one: the composition root's designated initializer
// sits at the SwiftLint body-length ceiling, and every feature that grows it makes
// the next one harder to add.
//
// OWNERSHIP: exactly ONE `CoreAudioOutputDeviceService` exists, and `outputRouting`
// holds it. This file used to build its own here and let the playback coordinator's
// `preLoadHook` retain it, which was fine while nothing else needed the seam; the
// Output preferences pane does, and two services would have fought over
// `start()`/`stop()` and the single-slot change handler. `SampleRateCoordinator` is
// therefore handed the router's controller rather than a new one.
import Foundation
import Services

extension AppEnvironment {
    /// Routes playback to the chosen output device, and sends every explicit track
    /// start through a device rate check first.
    func connectOutputRouting(settings: AppSettings) {
        let router = outputRouting
        router.persistSelection = { [weak settings] uid in settings?.output.deviceUID = uid }
        let rateCoordinator = SampleRateCoordinator(
            controller: router.controller,
            activeDeviceID: { [weak self] in self?.engine.outputDeviceID },
            isEnabled: { [weak settings] in settings?.output.autoSampleRate ?? false }
        )
        coordinator.preLoadHook = rateCoordinator.preLoadHook()
        Task { await router.start(selectedUID: settings.output.deviceUID) }
    }
}
