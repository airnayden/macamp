// CrossfeedSettingsSection — the crossfeed controls inside the EXISTING Playback pane.
//
// A `Section`, not a pane: crossfeed is one stage in the same signal path ReplayGain,
// gapless and the loudness pass already live on, and a tab of its own would push the
// Settings window's tab-bar floor wider for three controls.
//
// ── THE SLIDERS READ BACK THROUGH `CrossfeedLevel` ──────────────────────────
//
// Each slider's `get` routes the stored pair through ``CrossfeedPreferences/customLevel``
// rather than reading the raw number, so a stale or hand-edited preference is clamped
// into the slider's own bounds on the way to the screen. Without that, a stored 20 000
// Hz would hand `Slider` a value outside `in:` and SwiftUI would draw the thumb pinned
// at a position the model does not hold.
//
// ── "IN EFFECT" IS READ FROM THE STAGE, NOT MIRRORED FROM THE SLIDERS ───────
//
// The readout shows what the engine actually programmed, which is why it can disagree
// with the controls above it: an out-of-range custom pair arrives clamped, and a stage
// that failed to install reports nothing at all while the switch still says on. A
// mirrored readout would simply restate the sliders and could never say either.
import DesignSystem
import DSP
import SwiftUI

/// Crossfeed on/off, its strength, and what the engine made of that.
struct CrossfeedSettingsSection: View {
    @Bindable var model: CrossfeedSettingsModel

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Section {
            sectionTitle
            enableToggle
            PreferenceCaption(text: PreferencesStrings.crossfeedCaption)
            presetPicker
            PreferenceCaption(text: PreferencesStrings.crossfeedPresetCaption)
            if model.preferences.preset == .custom {
                cutFrequencySlider
                feedSlider
            }
            inEffectRow
        }
    }
}

// MARK: - Controls

private extension CrossfeedSettingsSection {
    var sectionTitle: some View {
        Text(PreferencesStrings.crossfeedSection)
            .font(tokens.typography.headline.font)
            .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
    }

    var enableToggle: some View {
        Toggle(isOn: $model.preferences.isEnabled) {
            Text(PreferencesStrings.crossfeedToggle)
        }
        .pointingHandCursor()
        .help(PreferencesStrings.crossfeedToggleHelp)
        .accessibilityIdentifier("playback.crossfeedToggle")
    }

    var presetPicker: some View {
        Picker(selection: $model.preferences.preset) {
            Text(PreferencesStrings.crossfeedPresetDefault).tag(CrossfeedPreset.default)
            Text(PreferencesStrings.crossfeedPresetCmoy).tag(CrossfeedPreset.cmoy)
            Text(PreferencesStrings.crossfeedPresetJmeier).tag(CrossfeedPreset.jmeier)
            Text(PreferencesStrings.crossfeedPresetCustom).tag(CrossfeedPreset.custom)
        } label: {
            Text(PreferencesStrings.crossfeedPreset)
        }
        .pointingHandCursor()
        .help(PreferencesStrings.crossfeedPresetHelp)
        .accessibilityIdentifier("playback.crossfeedPreset")
    }

    var cutFrequencySlider: some View {
        sliderRow(
            label: PreferencesStrings.crossfeedCutFrequency,
            value: PreferencesStrings.crossfeedFrequencyValue(
                Self.formatted(model.preferences.customLevel.cutFrequency, fractionLength: 0)
            ),
            help: PreferencesStrings.crossfeedCutFrequencyHelp,
            identifier: "playback.crossfeedCutFrequency"
        ) {
            Slider(value: cutFrequency, in: CrossfeedLevel.cutFrequencyRange, step: 10)
        }
    }

    var feedSlider: some View {
        sliderRow(
            label: PreferencesStrings.crossfeedFeed,
            value: PreferencesStrings.crossfeedFeedValue(
                Self.formatted(model.preferences.customLevel.feedDB, fractionLength: 1)
            ),
            help: PreferencesStrings.crossfeedFeedHelp,
            identifier: "playback.crossfeedFeed"
        ) {
            Slider(value: feed, in: CrossfeedLevel.feedRange, step: 0.1)
        }
    }

    var inEffectRow: some View {
        LabeledContent {
            inEffectValue
        } label: {
            Text(PreferencesStrings.crossfeedInEffect)
        }
        .accessibilityIdentifier("playback.crossfeedInEffect")
    }

    @ViewBuilder var inEffectValue: some View {
        if let level = model.programmedLevel {
            Text(PreferencesStrings.crossfeedLevelValue(
                frequency: Self.formatted(level.cutFrequency, fractionLength: 0),
                feed: Self.formatted(level.feedDB, fractionLength: 1)
            ))
            .monospacedDigit()
        } else {
            Text(PreferencesStrings.crossfeedNotInPath)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
        }
    }
}

// MARK: - Building blocks

private extension CrossfeedSettingsSection {
    /// A labelled slider with its current value on the trailing edge. The slider itself
    /// carries no SwiftUI label, so the accessible name is set explicitly.
    func sliderRow(
        label: LocalizedStringResource,
        value: LocalizedStringResource,
        help: LocalizedStringResource,
        identifier: String,
        @ViewBuilder slider: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            HStack(spacing: tokens.spacing.small) {
                Text(label)
                Spacer(minLength: tokens.spacing.small)
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            }
            slider()
                .pointingHandCursor()
                .help(help)
                .accessibilityLabel(Text(label))
                .accessibilityIdentifier(identifier)
        }
    }

    var cutFrequency: Binding<Double> {
        Binding(
            get: { model.preferences.customLevel.cutFrequency },
            set: { model.preferences.customCutFrequency = $0 }
        )
    }

    var feed: Binding<Double> {
        Binding(
            get: { model.preferences.customLevel.feedDB },
            set: { model.preferences.customFeedDB = $0 }
        )
    }

    /// Formats into the listener's locale here, so the translatable resource carries
    /// only its unit and never the digits.
    static func formatted(_ value: Double, fractionLength: Int) -> String {
        value.formatted(.number.precision(.fractionLength(fractionLength)))
    }
}

#Preview {
    Form {
        CrossfeedSettingsSection(model: CrossfeedSettingsModel(engine: { nil }))
    }
    .formStyle(.grouped)
    .designTokens(.standard)
}
