// CrossfeedPreferencesStrings — user-facing copy for the Playback pane's crossfeed
// section.
//
// A sibling file for the reason `OutputPreferencesStrings` is one: `PreferencesStrings`
// crossed the 400-line ceiling, so each pane's copy now lives beside the pane. Same
// conventions — every entry is a `LocalizedStringResource` with an English
// `defaultValue` and a dotted key.
//
// THE TWO DESIGNER NAMES ARE TRANSLATED ON PURPOSE. "Chu Moy" and "Jan Meier" are
// proper nouns, but MacAMP ships Bulgarian and Russian, and a Cyrillic locale
// legitimately transliterates a name rather than leaving it in Latin script. Numbers
// are the opposite case: they are formatted into the listener's locale at the call
// site, so the resources below carry only the units.
import Foundation

extension PreferencesStrings {
    static let crossfeedSection = LocalizedStringResource(
        "app.preferences.crossfeed.section",
        defaultValue: "Crossfeed",
        comment: "Section heading in Playback preferences for the headphone crossfeed stage"
    )
    static let crossfeedToggle = LocalizedStringResource(
        "app.preferences.crossfeed.toggle",
        defaultValue: "Crossfeed for headphones",
        comment: "Toggle that inserts the crossfeed stage into the signal path"
    )
    static let crossfeedToggleHelp = LocalizedStringResource(
        "app.preferences.crossfeed.toggle.help",
        defaultValue: "Bleed part of each channel into the other ear.",
        comment: "Tooltip on the crossfeed toggle"
    )
    static let crossfeedCaption = LocalizedStringResource(
        "app.preferences.crossfeed.caption",
        defaultValue: """
        Headphones send each channel to one ear only, which speakers never do. \
        Crossfeed sends a delayed, softened copy of each channel to the other ear, \
        so hard-panned mixes stop sounding split down the middle. It is off until \
        you turn it on, and it affects headphones and speakers alike — switch it \
        off for speakers.
        """,
        comment: "Explains what the crossfeed stage does and that it ships switched off"
    )
    static let crossfeedPreset = LocalizedStringResource(
        "app.preferences.crossfeed.preset",
        defaultValue: "Strength",
        comment: "Label for the picker choosing a crossfeed preset"
    )
    static let crossfeedPresetHelp = LocalizedStringResource(
        "app.preferences.crossfeed.preset.help",
        defaultValue: "How much of each channel reaches the other ear.",
        comment: "Tooltip on the crossfeed preset picker"
    )
    static let crossfeedPresetCaption = LocalizedStringResource(
        "app.preferences.crossfeed.preset.caption",
        defaultValue: """
        Default is the gentlest. Chu Moy feeds more of each channel across; \
        Jan Meier crosses over lower and feeds more still. Custom lets you set both.
        """,
        comment: "Explains the three crossfeed presets and the custom option"
    )
    static let crossfeedPresetDefault = LocalizedStringResource(
        "app.preferences.crossfeed.preset.default",
        defaultValue: "Default",
        comment: "Crossfeed preset: the gentlest published setting"
    )
    static let crossfeedPresetCmoy = LocalizedStringResource(
        "app.preferences.crossfeed.preset.cmoy",
        defaultValue: "Chu Moy",
        comment: "Crossfeed preset named after headphone-amplifier designer Chu Moy"
    )
    static let crossfeedPresetJmeier = LocalizedStringResource(
        "app.preferences.crossfeed.preset.jmeier",
        defaultValue: "Jan Meier",
        comment: "Crossfeed preset named after headphone-amplifier designer Jan Meier"
    )
    static let crossfeedPresetCustom = LocalizedStringResource(
        "app.preferences.crossfeed.preset.custom",
        defaultValue: "Custom",
        comment: "Crossfeed preset option that reveals the two hand-dialled sliders"
    )
    static let crossfeedCutFrequency = LocalizedStringResource(
        "app.preferences.crossfeed.cutFrequency",
        defaultValue: "Crossover frequency",
        comment: "Label for the slider setting the crossfeed low-pass corner frequency"
    )
    static let crossfeedCutFrequencyHelp = LocalizedStringResource(
        "app.preferences.crossfeed.cutFrequency.help",
        defaultValue: "Below this frequency, the channels blend most.",
        comment: "Tooltip on the crossfeed crossover-frequency slider"
    )
    static let crossfeedFeed = LocalizedStringResource(
        "app.preferences.crossfeed.feed",
        defaultValue: "Feed level",
        comment: "Label for the slider setting how much signal crosses to the other ear"
    )
    static let crossfeedFeedHelp = LocalizedStringResource(
        "app.preferences.crossfeed.feed.help",
        defaultValue: "How loud the crossed-over copy is.",
        comment: "Tooltip on the crossfeed feed-level slider"
    )
    static let crossfeedInEffect = LocalizedStringResource(
        "app.preferences.crossfeed.inEffect",
        defaultValue: "In effect",
        comment: "Label for the readout showing the crossfeed values the engine actually programmed"
    )
    static let crossfeedNotInPath = LocalizedStringResource(
        "app.preferences.crossfeed.notInPath",
        defaultValue: "Not in the signal path",
        comment: "Readout shown when the crossfeed stage is not inserted"
    )

    /// A crossover frequency, already formatted into the listener's locale by the
    /// caller — so the translatable part is the unit, never the digits.
    static func crossfeedFrequencyValue(_ hertz: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.crossfeed.cutFrequency.value",
            defaultValue: "\(hertz) Hz",
            comment: "A crossfeed crossover frequency in hertz, e.g. 700 Hz"
        )
    }

    /// A feed level, formatted by the caller for the same reason.
    static func crossfeedFeedValue(_ decibels: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.crossfeed.feed.value",
            defaultValue: "\(decibels) dB",
            comment: "A crossfeed feed level in decibels, e.g. 4.5 dB"
        )
    }

    /// The pair the engine actually programmed, both formatted by the caller.
    static func crossfeedLevelValue(frequency: String, feed: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.preferences.crossfeed.inEffect.value",
            defaultValue: "\(frequency) Hz · \(feed) dB",
            comment: "The crossover frequency and feed level currently programmed, e.g. 700 Hz · 4.5 dB"
        )
    }
}
