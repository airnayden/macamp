// SettingsScreen — iOS settings, bound to the shared view models.
//
// A token-styled grouped `Form` of playback (ReplayGain mode), equalizer (default
// preset) and visualizer (default mode) defaults, plus an About section. The
// system Form chrome is hidden (`scrollContentBackground(.hidden)`) and re-skinned
// on the design tokens: the canvas shows behind, every section becomes a
// `tokens.colors.surface` card, headers/footers use the type scale, and each row
// carries an accent-tinted SF Symbol. A bespoke brand hero crowns the form.
//
// Every control drives a real view model (`EQViewModel` / `VisualizerViewModel`)
// so a change is reflected immediately on the now-playing surface — the binding
// closures (and therefore the UserDefaults persistence keys) are unchanged. The
// "MacAMP" brand is rendered with `Text(verbatim:)` and never localized.
import DesignSystem
import Foundation
import Services
import SwiftUI
import Visualizer

/// The settings screen.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettings.self) private var settings
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            Form {
                brandHero
                playbackSection
                equalizerSection
                visualizerSection
                metadataSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(tokens.colors.canvas.resolve(scheme))
            .tint(tokens.colors.accent.resolve(scheme))
            .navigationTitle(Text(MacAMPStrings.settingsTitle))
            .task { environment.equalizer.loadPresets() }
        }
    }
}

// MARK: - Brand hero

private extension SettingsScreen {
    /// A centered app-identity crown: a gradient-filled glyph and the wordmark,
    /// floating on the canvas (no surface card) above the grouped settings.
    var brandHero: some View {
        Section {
            VStack(spacing: tokens.spacing.small) {
                RoundedRectangle(cornerRadius: tokens.radii.large, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tokens.colors.accent.resolve(scheme),
                                tokens.colors.accentMuted.resolve(scheme),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 76, height: 76)
                    .overlay {
                        Image(systemName: "waveform")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(tokens.colors.onAccent.resolve(scheme))
                    }
                    .shadow(
                        color: Color.black.opacity(tokens.elevation.medium.colorOpacity),
                        radius: tokens.elevation.medium.radius,
                        x: tokens.elevation.medium.offsetX,
                        y: tokens.elevation.medium.offsetY
                    )

                Text(verbatim: "MacAMP")
                    .font(tokens.typography.titleLarge.font)
                    .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, tokens.spacing.medium)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }
}

// MARK: - Sections

private extension SettingsScreen {
    var playbackSection: some View {
        Section {
            Picker(selection: replayGainBinding) {
                ForEach(ReplayGainMode.allCases, id: \.self) { mode in
                    Text(MacAMPStrings.replayGainName(mode)).tag(mode)
                }
            } label: {
                rowLabel(MacAMPStrings.settingsReplayGain, systemImage: "speaker.wave.2.fill")
            }
        } header: {
            sectionHeader(MacAMPStrings.settingsPlayback)
        } footer: {
            sectionFooter(MacAMPStrings.settingsPlaybackFooter)
        }
        .listRowBackground(tokens.colors.surface.resolve(scheme))
    }

    var equalizerSection: some View {
        Section {
            Picker(selection: presetBinding) {
                Text(MacAMPStrings.eqCustom).tag(String?.none)
                ForEach(environment.equalizer.presets, id: \.name) { preset in
                    Text(verbatim: preset.name).tag(Optional(preset.name))
                }
            } label: {
                rowLabel(MacAMPStrings.settingsDefaultPreset, systemImage: "slider.vertical.3")
            }
        } header: {
            sectionHeader(MacAMPStrings.settingsEqualizer)
        } footer: {
            sectionFooter(MacAMPStrings.settingsEqualizerFooter)
        }
        .listRowBackground(tokens.colors.surface.resolve(scheme))
    }

    var visualizerSection: some View {
        Section {
            Picker(selection: visualizerModeBinding) {
                ForEach(VisualizerMode.allCases, id: \.self) { mode in
                    Text(MacAMPStrings.visualizerModeName(mode)).tag(mode)
                }
            } label: {
                rowLabel(MacAMPStrings.settingsVisualizerMode, systemImage: "waveform")
            }
        } header: {
            sectionHeader(MacAMPStrings.settingsVisualizer)
        } footer: {
            sectionFooter(MacAMPStrings.settingsVisualizerFooter)
        }
        .listRowBackground(tokens.colors.surface.resolve(scheme))
    }

    var metadataSection: some View {
        Section {
            Toggle(isOn: autoEnrichBinding) {
                rowLabel(MacAMPStrings.settingsAutoEnrich, systemImage: "sparkles")
            }
            enrichmentProgressRow
        } header: {
            sectionHeader(MacAMPStrings.settingsMetadata)
        } footer: {
            sectionFooter(MacAMPStrings.settingsAutoEnrichFooter)
        }
        .listRowBackground(tokens.colors.surface.resolve(scheme))
    }

    @ViewBuilder
    var enrichmentProgressRow: some View {
        let enrichment = environment.enrichmentViewModel
        if enrichment.isRunning {
            VStack(alignment: .leading, spacing: tokens.spacing.xSmall) {
                HStack(spacing: tokens.spacing.small) {
                    Text(MacAMPStrings.settingsEnriching)
                        .font(tokens.typography.body.font)
                        .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
                    Spacer()
                    Text(verbatim: enrichment.progressText)
                        .font(tokens.typography.caption.font)
                        .monospacedDigit()
                        .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                }
                ProgressView(value: enrichment.progressFraction)
                    .tint(tokens.colors.accent.resolve(scheme))
            }
        }
    }

    var aboutSection: some View {
        Section {
            NavigationLink {
                AcknowledgmentsView()
                    .navigationTitle(Text(MacAMPStrings.settingsAcknowledgments))
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                rowLabel(MacAMPStrings.settingsAcknowledgments, systemImage: "heart.text.square")
            }
            HStack {
                rowLabel(MacAMPStrings.settingsVersion, systemImage: "info.circle")
                Spacer()
                Text(verbatim: appVersion)
                    .font(tokens.typography.body.font)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            }
        } header: {
            sectionHeader(MacAMPStrings.settingsAbout)
        }
        .listRowBackground(tokens.colors.surface.resolve(scheme))
    }
}

// MARK: - Token-styled row chrome

private extension SettingsScreen {
    func rowLabel(_ title: LocalizedStringResource, systemImage: String) -> some View {
        Label {
            Text(title)
                .font(tokens.typography.body.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tokens.colors.accent.resolve(scheme))
        }
    }

    func sectionHeader(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
    }

    func sectionFooter(_ title: LocalizedStringResource) -> some View {
        Text(title)
            .font(tokens.typography.caption.font)
            .foregroundStyle(tokens.colors.textTertiary.resolve(scheme))
    }
}

// MARK: - Bindings (persistence keys unchanged)

private extension SettingsScreen {
    var replayGainBinding: Binding<ReplayGainMode> {
        Binding(
            get: { environment.equalizer.replayGainMode },
            set: { environment.equalizer.setReplayGainMode($0) }
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

    var visualizerModeBinding: Binding<VisualizerMode> {
        Binding(
            get: { environment.visualizer.mode },
            set: { environment.visualizer.setMode($0) }
        )
    }

    var autoEnrichBinding: Binding<Bool> {
        Binding(
            get: { settings.autoEnrichOnImport },
            set: { settings.autoEnrichOnImport = $0 }
        )
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

#Preview {
    SettingsScreen()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .designTokens(.standard)
}
