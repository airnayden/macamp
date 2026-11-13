// EQSheet — the ten-band graphic EQ sheet, bound to `EQViewModel`.
//
// A preset picker plus ten horizontal band sliders (one per ISO octave centre).
// The view holds NO EQ logic of its own: each slider writes through
// `EQViewModel.setBandGain(_:dB:)` and applying a preset calls
// `EQViewModel.apply(...)`, which moves every band's `@Observable` gain (so the
// sliders animate to the preset shape) and drives the engine. Preamp is shown
// read-only (the view model exposes no setter — it follows the applied preset).
import AudioEngine
import DesignSystem
import SwiftUI

/// A 10-band graphic equalizer presented as a sheet.
struct EQSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    private let range: ClosedRange<Double> = -12 ... 12

    var body: some View {
        NavigationStack {
            Form {
                presetSection
                bandsSection
                preampSection
            }
            .navigationTitle(Text(MacAMPStrings.eqTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { resetButton }
                ToolbarItem(placement: .topBarTrailing) { doneButton }
            }
            .task { environment.equalizer.loadPresets() }
        }
    }
}

// MARK: - Sections

private extension EQSheet {
    var presetSection: some View {
        Section {
            Picker(selection: presetBinding) {
                ForEach(environment.equalizer.presets, id: \.name) { preset in
                    Text(verbatim: preset.name).tag(Optional(preset.name))
                }
                Text(MacAMPStrings.eqCustom).tag(String?.none)
            } label: {
                Text(MacAMPStrings.eqPreset)
            }
        }
    }

    var bandsSection: some View {
        Section {
            ForEach(EQBand.allCases, id: \.rawValue) { band in
                bandRow(band)
            }
        }
    }

    func bandRow(_ band: EQBand) -> some View {
        let index = band.rawValue
        return HStack(spacing: tokens.spacing.medium) {
            Text(verbatim: band.shortLabel)
                .font(tokens.typography.timecode.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .frame(width: 44, alignment: .leading)
            Slider(value: bandBinding(index), in: range)
                .tint(tokens.colors.accent.resolve(scheme))
                .accessibilityLabel(Text(verbatim: bandAccessibilityLabel(band)))
            Text(verbatim: gainLabel(index))
                .font(tokens.typography.timecode.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                .frame(width: 48, alignment: .trailing)
        }
    }

    var preampSection: some View {
        Section {
            HStack {
                Text(MacAMPStrings.eqPreamp)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                Spacer()
                Text(verbatim: preampText)
                    .font(tokens.typography.timecode.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            }
        }
    }

    var resetButton: some View {
        Button { environment.equalizer.reset() } label: {
            Text(MacAMPStrings.eqReset)
        }
    }

    var doneButton: some View {
        Button { dismiss() } label: {
            Text(MacAMPStrings.done)
        }
    }
}

// MARK: - Bindings + formatting

private extension EQSheet {
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

// MARK: - Band labels

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

#Preview {
    EQSheet()
        .environment(AppEnvironment.preview())
        .designTokens(.standard)
}
