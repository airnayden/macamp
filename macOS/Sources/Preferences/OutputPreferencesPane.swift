// OutputPreferencesPane — the Output tab in the macOS Settings window.
//
// Three sections: which device MacAMP plays through, whether that device is retuned
// per track, and what is actually in effect right now. The picker binds to
// `OutputRoutingModel` (the app's one router) rather than to `AppSettings` directly,
// because choosing a device is not a plain write: the UID has to reach the device
// service and the resulting route has to reach the engine, and the model persists the
// UID on the way through. The rate toggle IS a plain write, so it binds to
// `AppSettings.output` whose `didSet` persists the two flat scalars.
//
// ── THE PICKER SPEAKS UID, NEVER IDENTIFIER ──────────────────────────────────
//
// Every tag here is an `OutputDevice.uid` (`nil` == follow the system default), which
// is the half that survives a replug and a relaunch. Nothing in this pane ever names
// an `OutputDevice.id`.
//
// ── AN ABSENT DEVICE KEEPS ITS ROW ───────────────────────────────────────────
//
// When the chosen device is unplugged, `OutputDeviceSnapshot.hasUnavailableSelection`
// is true and `activeDeviceID` has already fallen back to the system default — so the
// row stays, marked unavailable, and the selection is NOT cleared. Plugging the device
// back in restores it with no further choice from the listener.
import DesignSystem
import Foundation
import Models
import Services
import SwiftUI

/// The Output settings pane: device, sample-rate policy, and the live readout.
struct OutputPreferencesPane: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings

    var body: some View {
        PreferencePane(
            icon: "hifispeaker",
            title: PreferencesStrings.tabOutput,
            subtitle: PreferencesStrings.outputSubtitle
        ) {
            OutputDeviceSection(router: environment.outputRouting)
            OutputSampleRateSection(settings: settings)
            OutputStatusSection(router: environment.outputRouting)
        }
        .task { await environment.outputRouting.refreshNominalRate() }
    }
}

// MARK: - Device

/// The device picker, plus the inline notice a fallen-back selection earns.
private struct OutputDeviceSection: View {
    let router: OutputRoutingModel

    var body: some View {
        Section {
            devicePicker
                .pointingHandCursor()
            if router.snapshot.hasUnavailableSelection {
                DownloadsNoticeLabel(kind: .warning, text: Text(PreferencesStrings.outputDeviceMissingCaption))
                    .accessibilityIdentifier("output.deviceMissingNotice")
            }
            PreferenceCaption(text: PreferencesStrings.outputDeviceCaption)
        }
    }

    private var devicePicker: some View {
        Picker(selection: selection) {
            Text(PreferencesStrings.outputDeviceSystemDefault).tag(String?.none)
            ForEach(router.snapshot.devices) { device in
                Text(verbatim: device.name).tag(String?.some(device.uid))
            }
            if router.snapshot.hasUnavailableSelection, let uid = router.snapshot.selectedUID {
                Text(PreferencesStrings.outputDeviceUnavailable(router.selectedDeviceName ?? uid))
                    .tag(String?.some(uid))
            }
        } label: {
            Text(PreferencesStrings.outputDevice)
        }
        .help(PreferencesStrings.outputDeviceHelp)
        .accessibilityIdentifier("output.devicePicker")
    }

    /// Reads the selection the router published and writes it back THROUGH the router,
    /// so one path persists the UID, retargets the device service, and re-routes the
    /// engine. A binding straight to `AppSettings` would persist and do neither.
    private var selection: Binding<String?> {
        Binding(
            get: { router.snapshot.selectedUID },
            set: { uid in Task { await router.select(uid: uid) } }
        )
    }
}

// MARK: - Sample rate

/// The per-track retune switch, captioned with what it does NOT cover.
///
/// The caption names the gapless exception outright. `SampleRateCoordinator` runs only
/// on `PlaybackCoordinator.preLoadHook`, which fires on explicit track starts and never
/// on the gapless pre-schedule path — retuning a device mid-render would glitch the
/// stream still playing. A caption that promised "every track" would be false for the
/// most common way an album is heard.
private struct OutputSampleRateSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Section {
            Toggle(isOn: $settings.output.autoSampleRate) {
                Text(PreferencesStrings.outputAutoSampleRate)
            }
            .pointingHandCursor()
            .help(PreferencesStrings.outputAutoSampleRateHelp)
            .accessibilityIdentifier("output.autoSampleRateToggle")
            PreferenceCaption(text: PreferencesStrings.outputAutoSampleRateCaption)
        }
    }
}

// MARK: - Readout

/// What is in effect right now: the device sound is going to, and its nominal rate.
///
/// Read from the router's snapshot rather than from the settings store, because the
/// two legitimately disagree — a chosen device that is unplugged is still the stored
/// selection while the system default is what is actually playing.
private struct OutputStatusSection: View {
    let router: OutputRoutingModel

    var body: some View {
        Section {
            LabeledContent {
                deviceValue
            } label: {
                Text(PreferencesStrings.outputCurrentDevice)
            }
            .accessibilityIdentifier("output.currentDevice")
            LabeledContent {
                rateValue
            } label: {
                Text(PreferencesStrings.outputCurrentRate)
            }
            .accessibilityIdentifier("output.currentRate")
        }
    }

    /// `Text(verbatim:)` because a device name arrives from the HAL already localized
    /// by its driver — putting it through the catalog would ask for a translation of
    /// hardware someone owns.
    @ViewBuilder private var deviceValue: some View {
        if let name = router.activeDevice?.name {
            Text(verbatim: name)
        } else {
            Text(PreferencesStrings.outputCurrentUnknown)
        }
    }

    @ViewBuilder private var rateValue: some View {
        if let kilohertz = formattedKilohertz {
            Text(PreferencesStrings.outputSampleRateValue(kilohertz))
        } else {
            Text(PreferencesStrings.outputCurrentUnknown)
        }
    }

    /// The nominal rate in kHz, formatted into the listener's locale here so the
    /// translatable resource carries only the unit, never the digits.
    private var formattedKilohertz: String? {
        guard let rate = router.nominalRate, rate > 0 else { return nil }
        return (rate / 1000).formatted(.number.precision(.fractionLength(0 ... 1)))
    }
}

#Preview {
    OutputPreferencesPane()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .designTokens(.standard)
}
