// EQPanelView — the ten-band graphic EQ, bound to `EQViewModel`.
//
// Ten vertical faders (one per ISO octave band) plus a preset picker. The view
// holds NO EQ logic of its own: each fader writes through
// `EQViewModel.setBandGain(_:dB:)` and applying a preset calls
// `EQViewModel.apply(...)`, which moves every band's `@Observable` gain (so the
// faders animate to the preset shape) and drives the engine. Preamp is shown
// read-only (the view model exposes no setter — it follows the applied preset).
import AudioEngine
import DesignSystem
import SwiftUI

/// A 10-band graphic equalizer with preset selection.
struct EQPanelView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    private let range: ClosedRange<Double> = -12 ... 12

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tokens.spacing.large) {
                header
                modeRow
                bandRow
                footer
                if environment.parametricEqualizer.isParametricActive {
                    ParametricEQEditor(model: environment.parametricEqualizer)
                }
            }
            .padding(tokens.spacing.medium)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { environment.equalizer.loadPresets() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: tokens.spacing.medium) {
            Text(MacAMPStrings.playerEqualizer)
                .font(tokens.typography.titleLarge.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Spacer(minLength: tokens.spacing.medium)
            presetPicker
        }
    }

    private var presetPicker: some View {
        Picker(selection: presetBinding) {
            ForEach(environment.equalizer.presets, id: \.name) { preset in
                Text(verbatim: preset.name).tag(Optional(preset.name))
            }
            Text(MacAMPStrings.eqCustom).tag(String?.none)
        } label: {
            Text(MacAMPStrings.eqPreset)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(tokens.colors.accent.resolve(scheme))
        .frame(maxWidth: 200)
    }

    /// The Graphic | Parametric selector, above the untouched ten faders.
    ///
    /// Parametric ADDS the filter bank alongside them rather than replacing them —
    /// the two are independent nodes in different processing slots, so hiding the
    /// faders here would conceal gains that are still in the signal path.
    private var modeRow: some View {
        VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
            ParametricEQModePicker(model: environment.parametricEqualizer)
            Text(ParametricEQStrings.modeCaption)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
    }

    private var bandRow: some View {
        HStack(alignment: .center, spacing: tokens.spacing.small) {
            ForEach(EQBand.allCases, id: \.rawValue) { band in
                bandCell(band)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func bandCell(_ band: EQBand) -> some View {
        let index = band.rawValue
        return VStack(spacing: tokens.spacing.xSmall) {
            Text(verbatim: gainLabel(index))
                .font(tokens.typography.timecode.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            VerticalGainSlider(gain: bandBinding(index), range: range)
                .frame(minHeight: 80, idealHeight: 160, maxHeight: 200)
                .accessibilityLabel(Text(verbatim: bandAccessibilityLabel(band)))
            Text(verbatim: band.shortLabel)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: tokens.spacing.xxSmall) {
                Text(MacAMPStrings.eqPreamp)
                    .font(tokens.typography.caption.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                Text(verbatim: preampText)
                    .font(tokens.typography.timecode.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            }
            Spacer()
            resetButton
        }
    }

    private var resetButton: some View {
        Button {
            environment.equalizer.reset()
        } label: {
            Label {
                Text(MacAMPStrings.eqReset)
            } icon: {
                Image(systemName: "arrow.counterclockwise")
            }
            .font(tokens.typography.headline.font)
            .foregroundStyle(tokens.colors.accent.resolve(scheme))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bindings + formatting

private extension EQPanelView {
    func bandBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                let gains = environment.equalizer.bandGains
                return gains.indices.contains(index) ? Double(gains[index]) : 0
            },
            set: { environment.equalizer.setBandGain(index, dB: Float($0)) }
        )
    }

    var presetBinding: Binding<String?> {
        Binding(
            get: { environment.equalizer.selectedPresetName },
            set: { newValue in
                if let name = newValue { environment.equalizer.applyPreset(named: name) }
            }
        )
    }

    func gainLabel(_ index: Int) -> String {
        let gains = environment.equalizer.bandGains
        let value = gains.indices.contains(index) ? Int(gains[index].rounded()) : 0
        return value > 0 ? "+\(value)" : "\(value)"
    }

    func bandAccessibilityLabel(_ band: EQBand) -> String {
        "\(String(localized: MacAMPStrings.eqBandGain)) \(band.shortLabel)"
    }

    var preampText: String {
        let value = environment.equalizer.preamp
        return value > 0 ? String(format: "+%.1f dB", value) : String(format: "%.1f dB", value)
    }
}

private extension EQBand {
    /// Compact frequency caption: `32`, `1k`, `16k`.
    var shortLabel: String {
        let hertz = centerFrequency
        if hertz >= 1000 {
            let kilo = hertz / 1000
            return kilo == kilo.rounded() ? "\(Int(kilo))k" : String(format: "%.1fk", kilo)
        }
        return "\(Int(hertz))"
    }
}

#Preview("EQ · Light") {
    EQPanelView()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
        .padding(24)
        .frame(width: 640, height: 420)
        .preferredColorScheme(.light)
}

#Preview("EQ · Dark") {
    EQPanelView()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
        .padding(24)
        .frame(width: 640, height: 420)
        .preferredColorScheme(.dark)
}
