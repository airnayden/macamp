// ParametricEQStrings — user-facing copy for the parametric equalizer.
//
// A standalone enum rather than an extension of `PreferencesStrings` because two
// surfaces read it: the EQ panel's mode toggle and editor (`macOS/Sources/Player`)
// and the Equalizer preferences pane. Same conventions as every other `*Strings`
// file — each label is a `LocalizedStringResource` with an English `defaultValue`
// and a dotted key.
//
// FILTER TYPE TOKENS ARE NOT IN HERE. `PK` / `LSC` / `HSC` are AutoEq wire format,
// not prose, and are rendered with `Text(verbatim:)`; only the long-form names
// beside them translate. Frequencies, gains and Q values are numbers formatted
// into the listener's locale by the view, so only the units translate.
import Foundation

enum ParametricEQStrings {
    // MARK: Mode

    static let mode = LocalizedStringResource(
        "app.eq.mode",
        defaultValue: "Equalizer",
        comment: "Label for the picker choosing between the graphic and parametric equalizers"
    )
    static let modeGraphic = LocalizedStringResource(
        "app.eq.mode.graphic",
        defaultValue: "Graphic",
        comment: "Equalizer mode: the ten-band graphic equalizer with vertical faders"
    )
    static let modeParametric = LocalizedStringResource(
        "app.eq.mode.parametric",
        defaultValue: "Parametric",
        comment: "Equalizer mode: the AutoEq-style parametric filter bank"
    )
    static let modeCaption = LocalizedStringResource(
        "app.eq.mode.caption",
        defaultValue: "Graphic uses the ten faders alone. Parametric adds a filter bank on top — import one from an AutoEq profile for your headphones. Switching back to Graphic takes the bank out of the signal path but keeps it here.",
        comment: "Explains the graphic/parametric equalizer choice: parametric adds a filter bank alongside the faders, and switching back keeps the bank without applying it"
    )

    // MARK: Bands

    static let bands = LocalizedStringResource(
        "app.eq.parametric.bands",
        defaultValue: "Filters",
        comment: "Header for the list of parametric equalizer filter bands"
    )
    static let addBand = LocalizedStringResource(
        "app.eq.parametric.addBand",
        defaultValue: "Add Filter",
        comment: "Button that appends a new band to the parametric filter bank"
    )
    static let removeBand = LocalizedStringResource(
        "app.eq.parametric.removeBand",
        defaultValue: "Remove Filter",
        comment: "Button that deletes one band from the parametric filter bank"
    )
    static let noBands = LocalizedStringResource(
        "app.eq.parametric.noBands",
        defaultValue: "No filters yet. Add one, or import an AutoEq profile for your headphones.",
        comment: "Placeholder shown when the parametric filter bank is empty"
    )
    static let bandType = LocalizedStringResource(
        "app.eq.parametric.type",
        defaultValue: "Type",
        comment: "Label for the picker choosing a parametric band's filter shape"
    )
    static let typePeaking = LocalizedStringResource(
        "app.eq.parametric.type.peaking",
        defaultValue: "Peak",
        comment: "Parametric filter shape: a peaking (bell) filter, AutoEq token PK"
    )
    static let typeLowShelf = LocalizedStringResource(
        "app.eq.parametric.type.lowShelf",
        defaultValue: "Low shelf",
        comment: "Parametric filter shape: a low shelf, AutoEq token LSC"
    )
    static let typeHighShelf = LocalizedStringResource(
        "app.eq.parametric.type.highShelf",
        defaultValue: "High shelf",
        comment: "Parametric filter shape: a high shelf, AutoEq token HSC"
    )
    static let frequency = LocalizedStringResource(
        "app.eq.parametric.frequency",
        defaultValue: "Frequency (Hz)",
        comment: "Label for a parametric band's centre or corner frequency field, in hertz"
    )
    static let gain = LocalizedStringResource(
        "app.eq.parametric.gain",
        defaultValue: "Gain (dB)",
        comment: "Label for a parametric band's gain field, in decibels"
    )
    static let qFactor = LocalizedStringResource(
        "app.eq.parametric.q",
        defaultValue: "Q",
        comment: "Label for a parametric band's quality factor field (Q), a unitless number"
    )
    static let preamp = LocalizedStringResource(
        "app.eq.parametric.preamp",
        defaultValue: "Pre-amp (dB)",
        comment: "Label for the parametric bank's global pre-amp trim, in decibels"
    )
    static let preampCaption = LocalizedStringResource(
        "app.eq.parametric.preamp.caption",
        defaultValue: "A negative trim makes headroom so the boosted filters do not clip. An imported profile brings its own.",
        comment: "Explains what the parametric pre-amp trim is for"
    )
    static let reset = LocalizedStringResource(
        "app.eq.parametric.reset",
        defaultValue: "Clear Filters",
        comment: "Button that removes every parametric filter and resets the pre-amp to zero"
    )
    static let capacityCaption = LocalizedStringResource(
        "app.eq.parametric.capacity.caption",
        defaultValue: "Up to 16 filters.",
        comment: "Caption stating the maximum number of parametric filters"
    )
    static let shelfApproximated = LocalizedStringResource(
        "app.eq.parametric.shelfApproximated",
        defaultValue: "Some shelf filters use a Q macOS cannot reproduce exactly, so their slope is approximated. Their frequency and gain are exact.",
        comment: "Notice shown when a shelf filter's Q deviates far enough that the system equalizer only approximates its slope"
    )

    // MARK: Import

    static let importProfile = LocalizedStringResource(
        "app.eq.parametric.import",
        defaultValue: "Import AutoEq Profile…",
        comment: "Button that opens a file picker to import an AutoEq parametric EQ text profile"
    )
    static let importCaption = LocalizedStringResource(
        "app.eq.parametric.import.caption",
        defaultValue: "Reads an AutoEq “ParametricEQ.txt” profile, including its pre-amp line.",
        comment: "Explains what the AutoEq import button accepts"
    )
    static let importFailedTitle = LocalizedStringResource(
        "app.eq.parametric.import.failed",
        defaultValue: "Couldn’t use that profile",
        comment: "Title of the alert shown when an AutoEq profile or a preset could not be used"
    )

    // MARK: Presets

    static let presets = LocalizedStringResource(
        "app.eq.parametric.presets",
        defaultValue: "Parametric Presets",
        comment: "Header for the list of saved parametric equalizer presets"
    )
    static let savePreset = LocalizedStringResource(
        "app.eq.parametric.savePreset",
        defaultValue: "Save as Preset…",
        comment: "Button that saves the current parametric filter bank under a name"
    )
    static let savePresetPrompt = LocalizedStringResource(
        "app.eq.parametric.savePreset.prompt",
        defaultValue: "Preset name",
        comment: "Prompt for the text field naming a new parametric preset"
    )
    static let saveButton = LocalizedStringResource(
        "app.eq.parametric.savePreset.confirm",
        defaultValue: "Save",
        comment: "Confirm button of the save-parametric-preset sheet"
    )
    static let cancelButton = LocalizedStringResource(
        "app.eq.parametric.cancel",
        defaultValue: "Cancel",
        comment: "Cancel button of the save-parametric-preset sheet"
    )
    static let applyPreset = LocalizedStringResource(
        "app.eq.parametric.applyPreset",
        defaultValue: "Apply",
        comment: "Button that loads a saved parametric preset into the editor and the signal path"
    )
    static let deletePreset = LocalizedStringResource(
        "app.eq.parametric.deletePreset",
        defaultValue: "Delete",
        comment: "Button that deletes a saved parametric preset"
    )
    static let noPresets = LocalizedStringResource(
        "app.eq.parametric.noPresets",
        defaultValue: "No saved presets yet.",
        comment: "Placeholder shown when no parametric presets have been saved"
    )
    static let presetUnreadableBadge = LocalizedStringResource(
        "app.eq.parametric.preset.unreadableBadge",
        defaultValue: "Unreadable",
        comment: "Badge on a saved parametric preset whose stored filter bank could not be read; it can still be deleted"
    )
    static let dismissButton = LocalizedStringResource(
        "app.eq.parametric.dismiss",
        defaultValue: "OK",
        comment: "Dismiss button of the parametric equalizer error alert"
    )

    /// A saved preset's summary line: how many filters it holds and its trim.
    ///
    /// Both numbers arrive already formatted into the listener's locale, so the
    /// translatable part is the grammar and the units, not the digits.
    static func presetSummary(filters: Int, preamp: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "app.eq.parametric.preset.summary",
            defaultValue: "^[\(filters) filter](inflect: true) · \(preamp) dB pre-amp",
            comment: "Summary of a saved parametric preset: its filter count and pre-amp trim in decibels"
        )
    }
}
