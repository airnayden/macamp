// SignalPathStrings — localized copy for the player-bar signal-path panel.
//
// Only LABELS live here. Every VALUE the panel shows is a non-translatable token
// produced by `SignalPathModel` (a codec name, a number with its unit) and is
// rendered with `Text(verbatim:)`, exactly as `TagsPanelView` renders tag values.
//
// # The one piece of copy that is a promise
//
// ``directPathTitle`` reads "Direct path" and MUST NEVER read "bit-perfect".
// MacAMP cannot make that claim: two `AVAudioMixerNode`s are unconditionally in
// the graph, every sample passes through 32-bit float, and the system's own output
// volume sits downstream of the app. ``directPathSubtitle`` says so out loud, so
// the badge describes what MacAMP did rather than implying a guarantee about what
// the whole system did.
import Foundation

/// Localized copy for the signal-path panel (labels, badges, disclosures).
enum SignalPathStrings {
    static let title = LocalizedStringResource(
        "app.signalPath.title",
        defaultValue: "Signal Path",
        comment: "Title of the popover that shows what processing is applied to the playing audio"
    )
    static let help = LocalizedStringResource(
        "app.signalPath.help",
        defaultValue: "Show the signal path",
        comment: "Hover tooltip for the player-bar control that opens the signal-path panel"
    )
    static let accessibilityLabel = LocalizedStringResource(
        "app.signalPath.accessibilityLabel",
        defaultValue: "Signal path",
        comment: "Accessibility label for the player-bar control that opens the signal-path panel"
    )
    static let accessibilityHint = LocalizedStringResource(
        "app.signalPath.accessibilityHint",
        defaultValue: "Shows the format, processing, and output device of the playing audio",
        comment: "Accessibility hint for the player-bar control that opens the signal-path panel"
    )

    // MARK: Sections

    static let sectionSource = LocalizedStringResource(
        "app.signalPath.section.source",
        defaultValue: "Source",
        comment: "Section header for the source file's own audio format"
    )
    static let sectionProcessing = LocalizedStringResource(
        "app.signalPath.section.processing",
        defaultValue: "Processing",
        comment: "Section header for the processing stages MacAMP applies to the audio"
    )
    static let sectionOutput = LocalizedStringResource(
        "app.signalPath.section.output",
        defaultValue: "Output",
        comment: "Section header for the engine connection format and the output device clock"
    )

    // MARK: Rows

    static let fieldFormat = LocalizedStringResource(
        "app.signalPath.field.format",
        defaultValue: "Format",
        comment: "Row label for the source file's codec, sample rate, bit depth and bitrate"
    )
    static let fieldReplayGain = LocalizedStringResource(
        "app.signalPath.field.replayGain",
        defaultValue: "ReplayGain",
        comment: "Row label for the ReplayGain loudness trim applied to the playing track"
    )
    static let fieldTotalGain = LocalizedStringResource(
        "app.signalPath.field.totalGain",
        defaultValue: "Total gain",
        comment: "Row label for every gain MacAMP applies, summed"
    )
    static let fieldGraphicEQ = LocalizedStringResource(
        "app.signalPath.field.graphicEQ",
        defaultValue: "Graphic EQ",
        comment: "Row label for the ten-band graphic equalizer stage"
    )
    static let fieldParametricEQ = LocalizedStringResource(
        "app.signalPath.field.parametricEQ",
        defaultValue: "Parametric EQ",
        comment: "Row label for the parametric equalizer stage"
    )
    static let fieldCrossfeed = LocalizedStringResource(
        "app.signalPath.field.crossfeed",
        defaultValue: "Crossfeed",
        comment: "Row label for the headphone crossfeed stage"
    )
    static let fieldBalance = LocalizedStringResource(
        "app.signalPath.field.balance",
        defaultValue: "Balance",
        comment: "Row label for the stereo balance (pan) stage"
    )
    static let fieldEngineFormat = LocalizedStringResource(
        "app.signalPath.field.engineFormat",
        defaultValue: "Engine",
        comment: "Row label for the sample rate and channel count the audio graph is wired at"
    )
    static let fieldDeviceRate = LocalizedStringResource(
        "app.signalPath.field.deviceRate",
        defaultValue: "Device clock",
        comment: "Row label for the output device's current nominal sample rate"
    )

    // MARK: States

    static let stateOn = LocalizedStringResource(
        "app.signalPath.state.on",
        defaultValue: "On",
        comment: "Value shown when a processing stage is engaged"
    )
    static let stateOff = LocalizedStringResource(
        "app.signalPath.state.off",
        defaultValue: "Off",
        comment: "Value shown when a processing stage is not engaged"
    )
    static let stateFlat = LocalizedStringResource(
        "app.signalPath.state.flat",
        defaultValue: "Flat",
        comment: "Value shown when every equalizer band sits at 0 dB"
    )
    static let stateCentre = LocalizedStringResource(
        "app.signalPath.state.centre",
        defaultValue: "Centre",
        comment: "Value shown when the stereo balance is centred"
    )
    static let stateNotPlaying = LocalizedStringResource(
        "app.signalPath.state.notPlaying",
        defaultValue: "Nothing is playing",
        comment: "Message shown in the signal-path panel when no track is loaded"
    )

    // MARK: Badges

    static let dsdBadge = LocalizedStringResource(
        "app.signalPath.badge.dsd",
        defaultValue: "DSD",
        comment: "Badge shown when the playing file is Direct Stream Digital material"
    )
    static let srcBadge = LocalizedStringResource(
        "app.signalPath.badge.src",
        defaultValue: "Sample-rate conversion",
        comment: "Badge shown when the source sample rate differs from the output device's clock"
    )
    static let srcSubtitle = LocalizedStringResource(
        "app.signalPath.badge.src.subtitle",
        defaultValue: "The source rate and the device clock differ, so the audio is being resampled.",
        comment: "Explanation shown beneath the sample-rate-conversion badge"
    )
    /// NEVER "bit-perfect" — see this file's header for why that claim is unavailable.
    static let directPathTitle = LocalizedStringResource(
        "app.signalPath.badge.directPath",
        defaultValue: "Direct path",
        comment: "Badge shown when MacAMP is applying no gain, equalization, crossfeed, pan or resampling"
    )
    /// The honest caveat the badge is never shown without.
    static let directPathSubtitle = LocalizedStringResource(
        "app.signalPath.badge.directPath.subtitle",
        defaultValue: """
        MacAMP is changing nothing: no gain, equalization, crossfeed, balance or resampling. \
        The system mixer and the output volume are still outside this app’s control.
        """,
        comment: "Explanation shown beneath the Direct path badge, stating what remains outside the app's control"
    )
    static let processedTitle = LocalizedStringResource(
        "app.signalPath.badge.processed",
        defaultValue: "Processed",
        comment: "Badge shown when at least one MacAMP processing stage is changing the audio"
    )
    static let processedSubtitle = LocalizedStringResource(
        "app.signalPath.badge.processed.subtitle",
        defaultValue: "At least one stage above is changing the audio.",
        comment: "Explanation shown beneath the Processed badge"
    )
}
