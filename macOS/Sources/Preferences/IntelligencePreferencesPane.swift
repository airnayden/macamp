// IntelligencePreferencesPane — the Intelligence tab in the macOS Settings window.
//
// One pane for the whole local-AI surface: the single switch that builds or tears
// down the object graph, a status row explaining whether the tier that actually
// answers can run here, the provider and model pickers (their own file,
// `IntelligenceProviderSection`), the six per-feature switches, and the opt-in
// audio-analysis pass (its own file, `AudioAnalysisSettingsSection`).
//
// NO `.onChange` FIRES A REBUILD HERE — deliberately. `AppEnvironment` watches
// `intelligenceEnabled` with a self-re-arming `withObservationTracking`, so the
// binding alone rebuilds the graph; adding a change handler beside it would rebuild
// twice per flip. This is the opposite of the Karaoke pane, whose seam is an
// explicit `onKaraokeEnabledChanged` closure the pane must call.
//
// The availability row renders the ACTIVE TIER, not Apple Intelligence
// unconditionally: once a connector is selected, that connector is what answers,
// and reporting "Apple Intelligence is unavailable" beside a working provider reads
// as a broken app. `IntelligenceActiveTier` makes that precedence explicit, and the
// on-device branch still renders `AssistantUnavailableReason.message` so the pane
// says exactly what every other assistant surface says. Availability is probed into
// `@State` rather than read in `body`, because the reading crosses into the system's
// language-model service and `body` re-runs far more often than the answer changes.
import DesignSystem
import Services
import SwiftUI

/// The Intelligence settings pane: the switch, the provider, the feature bundles,
/// the status of whichever tier answers, and the audio-analysis pass.
struct IntelligencePreferencesPane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppEnvironment.self) private var environment

    /// Owned HERE, not by the provider section, because the availability row and
    /// the provider section report on the same selection and must never disagree.
    @State private var provider = IntelligenceProviderModel()

    var body: some View {
        PreferencePane(
            icon: "sparkles",
            title: PreferencesStrings.tabIntelligence,
            subtitle: AppleIntelligenceRetirement.isRetired
                ? PreferencesStrings.intelligenceSubtitleRetired
                : PreferencesStrings.intelligenceSubtitle
        ) {
            IntelligenceEnableSection(settings: settings, provider: provider)
            IntelligenceProviderSection(settings: settings, provider: provider)
            IntelligencePlaybackControlSection(settings: settings)
            IntelligenceExternalAccessSection(settings: settings, externalAccess: environment.externalAccess)
            IntelligenceWebSuggestionsSection(settings: settings)
            IntelligenceMCPServersSection(settings: settings)
            IntelligenceBundlesSection(settings: settings)
            AudioAnalysisSettingsSection()
        }
        .accessibilityIdentifier("preferences.tab.intelligence")
    }
}

// MARK: - Enable

/// The switch that owns the whole feature, its captions, and the live status of
/// the on-device model.
private struct IntelligenceEnableSection: View {
    @Bindable var settings: AppSettings
    let provider: IntelligenceProviderModel

    @State private var availability: AssistantAvailability?

    var body: some View {
        Section {
            Toggle(isOn: $settings.intelligenceEnabled) {
                Text(PreferencesStrings.intelligenceToggle)
            }
            .accessibilityIdentifier("intelligence.masterToggle")
            PreferenceCaption(text: AppleIntelligenceRetirement.isRetired ? PreferencesStrings
                .intelligenceCaptionRetired : PreferencesStrings.intelligenceCaption)
            PreferenceCaption(text: PreferencesStrings.intelligenceOffNotice)
            if let tier {
                IntelligenceStatusRow(tier: tier)
                if tier.showsHeuristicFallbackNotice {
                    PreferenceCaption(text: PreferencesStrings.intelligenceStatusFallback)
                }
            }
        }
        // `.task(id:)` rather than a `.task` + `.onChange` pair: it re-runs on every
        // flip of the switch by itself, and the pane admits no change handlers.
        .task(id: settings.intelligenceEnabled) {
            availability = AssistantAvailabilityProbe.current(
                intelligenceEnabled: settings.intelligenceEnabled
            )
        }
    }

    private var tier: IntelligenceActiveTier? {
        IntelligenceActiveTier(availability: availability, selection: provider.selection)
    }
}

// MARK: - Status row

/// "Apple Intelligence — Ready on this device.", or the selected provider's own
/// state once one is chosen. One row, whichever tier is actually in force.
private struct IntelligenceStatusRow: View {
    let tier: IntelligenceActiveTier

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LabeledContent {
            Label {
                Text(tier.message)
                    .font(tokens.typography.callout.font)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .accessibilityIdentifier("intelligence.availabilityStatus")
        } label: {
            label
        }
    }

    /// A provider name is a BRAND — rendered verbatim; the on-device tier's label
    /// is catalog copy.
    @ViewBuilder
    private var label: some View {
        if let providerName = tier.providerName {
            Text(verbatim: providerName)
        } else if AppleIntelligenceRetirement.isRetired {
            Text(PreferencesStrings.intelligenceStatusLabelNoProvider)
        } else {
            Text(PreferencesStrings.intelligenceStatusLabel)
        }
    }

    private var symbol: String {
        tier.isHealthy ? "checkmark.circle.fill" : "exclamationmark.circle"
    }

    private var tint: Color {
        tier.isHealthy
            ? tokens.colors.success.resolve(scheme)
            : tokens.colors.textSecondary.resolve(scheme)
    }
}

// MARK: - Feature bundles

/// One switch per ``AIFeatureBundle``, disabled wholesale when the feature is off.
private struct IntelligenceBundlesSection: View {
    @Bindable var settings: AppSettings

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Section {
            Text(PreferencesStrings.intelligenceFeaturesSection)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            ForEach(AIFeatureBundle.allCases, id: \.self) { bundle in
                Toggle(isOn: binding(for: bundle)) {
                    Text(PreferencesStrings.intelligenceBundleLabel(bundle))
                }
                .accessibilityIdentifier("intelligence.bundleToggle.\(bundle.rawValue)")
                PreferenceCaption(text: PreferencesStrings.intelligenceBundleCaption(bundle))
            }
        }
        .disabled(!settings.intelligenceEnabled)
    }

    private func binding(for bundle: AIFeatureBundle) -> Binding<Bool> {
        switch bundle {
        case .nlCreation: $settings.nlCreationEnabled
        case .autoMixes: $settings.autoMixesEnabled
        case .organization: $settings.organizationEnabled
        case .rediscovery: $settings.rediscoveryEnabled
        case .insights: $settings.insightsEnabled
        case .hygiene: $settings.hygieneEnabled
        }
    }
}

#Preview {
    IntelligencePreferencesPane()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .designTokens(.standard)
}
