// OutputPreferencesStrings — user-facing copy for the Output settings pane.
//
// Split out of `PreferencesStrings` (which crossed the 400-line file ceiling) so the
// Output pane's copy lives beside the pane, exactly as `KaraokePreferencesStrings`
// and `DownloadsPreferencesStrings` do. Same conventions as its parent: every label
// is a `LocalizedStringResource` with an English `defaultValue` and a dotted key.
//
// DEVICE NAMES ARE NOT IN HERE. `OutputDevice.name` comes from the HAL already
// localized by the driver, so it is rendered with `Text(verbatim:)` and only the
// decoration around it (the "(unavailable)" suffix) is translatable.
import Foundation

extension PreferencesStrings {
    static let tabOutput = LocalizedStringResource(
        "app.preferences.tab.output",
        defaultValue: "Output",
        comment: "Preferences tab: audio output device and sample-rate options"
    )
    static let outputSubtitle = LocalizedStringResource(
        "app.preferences.output.subtitle",
        defaultValue: "Choose where MacAMP sends sound.",
        comment: "One-line subtitle under the Output preferences pane title"
    )
    static let outputDevice = LocalizedStringResource(
        "app.preferences.output.device",
        defaultValue: "Output device",
        comment: "Label for the picker choosing which audio device MacAMP plays through"
    )
    static let outputDeviceSystemDefault = LocalizedStringResource(
        "app.preferences.output.device.systemDefault",
        defaultValue: "System Default",
        comment: "Output device option: follow whatever device macOS is currently using"
    )
    static let outputDeviceHelp = LocalizedStringResource(
        "app.preferences.output.device.help",
        defaultValue: "The audio device MacAMP plays through.",
        comment: "Tooltip on the output device picker"
    )
    static let outputDeviceCaption = LocalizedStringResource(
        "app.preferences.output.device.caption",
        defaultValue: "System Default follows whatever device macOS is using. Pick a device to keep MacAMP on it.",
        comment: "Explains the output device picker's System Default option"
    )
    static let outputDeviceMissingCaption = LocalizedStringResource(
        "app.preferences.output.device.missing",
        defaultValue: "That device isn't connected, so sound is going to the system default. Plug it back in and MacAMP will return to it.",
        comment: "Notice shown when the chosen output device is unplugged and playback fell back to the system default"
    )
    static let outputAutoSampleRate = LocalizedStringResource(
        "app.preferences.output.autoSampleRate",
        defaultValue: "Match each track's sample rate",
        comment: "Toggle that retunes the output device to the sample rate of the track being started"
    )
    static let outputAutoSampleRateHelp = LocalizedStringResource(
        "app.preferences.output.autoSampleRate.help",
        defaultValue: "Retune the output device when a track starts.",
        comment: "Tooltip on the automatic sample-rate toggle"
    )
    static let outputAutoSampleRateCaption = LocalizedStringResource(
        "app.preferences.output.autoSampleRate.caption",
        defaultValue: "Switches the device to a track's own rate when you start that track, avoiding resampling. Gapless album playback keeps the rate already in use, so later tracks in an album are not retuned.",
        comment: "Explains the automatic sample-rate toggle, including that gapless album playback keeps the current rate"
    )
    static let outputCurrentDevice = LocalizedStringResource(
        "app.preferences.output.current.device",
        defaultValue: "Playing through",
        comment: "Label for the readout naming the device audio is currently routed to"
    )
    static let outputCurrentRate = LocalizedStringResource(
        "app.preferences.output.current.rate",
        defaultValue: "Device sample rate",
        comment: "Label for the readout showing the current device's nominal sample rate"
    )
    static let outputCurrentUnknown = LocalizedStringResource(
        "app.preferences.output.current.unknown",
        defaultValue: "Unknown",
        comment: "Placeholder shown when the current output device or its sample rate can't be read"
    )

    /// The chosen-but-absent device's row, which keeps the selection visible while its
    /// hardware is away. The name is the HAL's own text, so only the suffix translates.
    static func outputDeviceUnavailable(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.output.device.unavailableName",
            defaultValue: "\(name) (unavailable)",
            comment: "Output device row for a remembered device that is not connected right now"
        )
    }

    /// A nominal sample rate for the readout, already formatted into the listener's
    /// locale by the caller — so the translatable part is the unit, not the number.
    static func outputSampleRateValue(_ kilohertz: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.output.current.rate.value",
            defaultValue: "\(kilohertz) kHz",
            comment: "A device sample rate in kilohertz, e.g. 44.1 kHz"
        )
    }
}
