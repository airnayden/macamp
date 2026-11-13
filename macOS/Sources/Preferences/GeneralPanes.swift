// GeneralPanes — the General, Updates and Acknowledgments preferences panes.
//
// These three "shell" panes bind to the shared `AppSettings` store for the values
// they own (appearance, theme preset, update channel); Updates additionally drives
// the app's one Sparkle `UpdaterModel` from the environment. All copy resolves
// through `PreferencesStrings`.
import DesignSystem
import SwiftUI

// MARK: - General

/// Appearance + startup options.
struct GeneralPreferencesPane: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        PreferencePane(
            icon: "gearshape",
            title: PreferencesStrings.tabGeneral,
            subtitle: PreferencesStrings.generalSubtitle
        ) {
            // First, not beside the other two: a listener who cannot read the current
            // interface language needs the shortest path to the control that fixes it.
            GeneralLanguageSection(defaults: settings.defaults)
            Section {
                Picker(selection: $settings.appearance) {
                    Text(PreferencesStrings.appearanceSystem).tag(AppearanceSetting.system)
                    Text(PreferencesStrings.appearanceLight).tag(AppearanceSetting.light)
                    Text(PreferencesStrings.appearanceDark).tag(AppearanceSetting.dark)
                } label: {
                    Text(PreferencesStrings.appearance)
                }
            }
            Section {
                Picker(selection: $settings.themePreset) {
                    Text(verbatim: "MacAMP").tag(ThemePreset.macAMP)
                } label: {
                    Text(PreferencesStrings.themePreset)
                }
            }
        }
    }
}

// MARK: - Updates

/// The software-update channel and a manual Sparkle check.
struct UpdatesPreferencesPane: View {
    @Environment(AppSettings.self) private var settings
    @Environment(UpdaterModel.self) private var updater

    var body: some View {
        @Bindable var settings = settings
        PreferencePane(
            icon: "arrow.triangle.2.circlepath",
            title: PreferencesStrings.tabUpdates,
            subtitle: PreferencesStrings.updatesSubtitle
        ) {
            Section {
                Picker(selection: $settings.updateChannel) {
                    Text(PreferencesStrings.updateChannelStable).tag(UpdateChannel.stable)
                    Text(PreferencesStrings.updateChannelBeta).tag(UpdateChannel.beta)
                } label: {
                    Text(PreferencesStrings.updateChannel)
                }
                PreferenceCaption(text: PreferencesStrings.updateChannelCaption)
            }
            Section {
                Button { updater.checkForUpdates() } label: {
                    Text(PreferencesStrings.checkForUpdates)
                }
                .disabled(!updater.canCheckForUpdates)
                .pointingHandCursor()
                .help(PreferencesStrings.checkForUpdatesHelp)
                .accessibilityIdentifier("preferences.updates.checkButton")
                PreferenceCaption(text: PreferencesStrings.updatesAutomatic)
            }
        }
    }
}

// MARK: - Acknowledgments

/// Open-source acknowledgments, rendered from the shared `AcknowledgmentsView`
/// over the components this macOS build actually bundles.
struct AcknowledgmentsPreferencesPane: View {
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            versionBadge
            legalNotice
            AcknowledgmentsView(entries: bundledComponents)
        }
        .frame(width: 500)
        .frame(minHeight: 320)
    }

    private var versionBadge: some View {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return HStack(spacing: tokens.spacing.xSmall) {
            Text(verbatim: "MacAMP")
                .font(tokens.typography.titleMedium.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Text(verbatim: "· v\(bundleVersion)")
                .font(tokens.typography.callout.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
        }
        .padding(.top, tokens.spacing.large)
        .padding(.horizontal, tokens.spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// GPLv3 "Appropriate Legal Notices": copyright, license, no warranty, and where the
    /// source lives. Read from `NSHumanReadableCopyright` (macOS/Project.swift) so the
    /// About window and this pane can never disagree, and no copy is hard-coded here.
    @ViewBuilder
    private var legalNotice: some View {
        if let notice = Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String {
            Text(verbatim: notice)
                .font(tokens.typography.caption.font)
                .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, tokens.spacing.xxSmall)
                .padding(.horizontal, tokens.spacing.large)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("acknowledgments.legalNotice")
        }
    }

    private var bundledComponents: [Acknowledgment] {
        var items = Acknowledgments.core + Acknowledgments.macOS
        #if MACAMP_PROJECTM
            items += Acknowledgments.projectM
        #endif
        return items
    }
}

#Preview("General") {
    GeneralPreferencesPane()
        .environment(AppSettings.preview)
        .designTokens(.standard)
}

#Preview("Updates") {
    UpdatesPreferencesPane()
        .environment(AppSettings.preview)
        .environment(UpdaterModel.preview)
        .designTokens(.standard)
}

#Preview("Acknowledgments") {
    AcknowledgmentsPreferencesPane()
        .designTokens(.standard)
}
