// ProfilesPane — the Profiles preferences pane (enable toggle + management entry).
//
// Binds the `profilesEnabled` feature flag to the shared `AppSettings` store and,
// on change, drives `ProfileService`'s enable/disable state machine. The pane owns
// only the toggle, a read-only active-profile row, and a "Manage Profiles…" button
// that surfaces the shared full-window overlay (`NavigationModel.showProfileOverlay`,
// presented by the main window) and brings that window forward. Profile CRUD lives
// in the overlay/editor, never here. Copy resolves through `ProfileStrings`.
import DesignSystem
import Persistence
import Services
import SwiftUI

/// Enable/disable the profiles feature and reach the management overlay.
struct ProfilesPreferencesPane: View {
    @Environment(AppEnvironment.self) var environment
    @Environment(AppSettings.self) var settings
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    @State var pendingImportURL: URL?
    @State var isArchiveBusy = false

    var body: some View {
        @Bindable var settings = settings
        PreferencePane(
            icon: "person.crop.circle",
            title: ProfileStrings.preferencesTitle,
            subtitle: ProfileStrings.preferencesSubtitle
        ) {
            Section {
                Toggle(isOn: $settings.profilesEnabled) {
                    Text(ProfileStrings.enableToggleLabel)
                }
                .accessibilityIdentifier("preferences.profiles.toggle")
                PreferenceCaption(text: ProfileStrings.enableFooter)
            }
            Section {
                currentProfileRow
                Button { openManageProfiles() } label: {
                    Text(ProfileStrings.manageButton)
                }
                .accessibilityIdentifier("preferences.profiles.manageButton")
                .disabled(!settings.profilesEnabled)
            }
            archiveSection
        }
        .onChange(of: settings.profilesEnabled) { _, isEnabled in
            handleToggle(isEnabled)
        }
        .confirmationDialog(
            Text(ProfileArchiveStrings.importOptInTitle),
            isPresented: importOptInPresented,
            titleVisibility: .visible
        ) {
            Button(String(localized: ProfileArchiveStrings.importEverything)) {
                performImport(applyingGlobals: true)
            }
            Button(String(localized: ProfileArchiveStrings.importStatsOnly)) {
                performImport(applyingGlobals: false)
            }
            Button(String(localized: ProfileArchiveStrings.importCancel), role: .cancel) {
                pendingImportURL = nil
            }
        } message: {
            Text(ProfileArchiveStrings.importOptInMessage)
        }
    }

    var importOptInPresented: Binding<Bool> {
        Binding(
            get: { pendingImportURL != nil },
            set: { if !$0 { pendingImportURL = nil } }
        )
    }
}

// MARK: - Rows

extension ProfilesPreferencesPane {
    var currentProfileRow: some View {
        let active = environment.profileService.activeProfile
        return LabeledContent {
            HStack(spacing: tokens.spacing.xSmall) {
                ProfileAvatarView(
                    preset: ProfileAvatarPreset(id: active.avatarId),
                    imagePath: active.avatarImagePath,
                    size: 20
                )
                profileName(active)
                    .foregroundStyle(tokens.colors.textSecondary.resolve(scheme))
            }
        } label: {
            Text(ProfileStrings.currentProfileLabel)
        }
        .accessibilityIdentifier("preferences.profiles.currentProfile")
    }

    @ViewBuilder
    func profileName(_ profile: ProfileRecord) -> some View {
        if profile.id == ProfileRecord.guestID {
            Text(ProfileStrings.guestName)
        } else {
            Text(verbatim: displayName(profile))
        }
    }

    func displayName(_ profile: ProfileRecord) -> String {
        guard let lastName = profile.lastName, !lastName.isEmpty else { return profile.name }
        return "\(profile.name) \(lastName)"
    }
}

// MARK: - Actions

private extension ProfilesPreferencesPane {
    func handleToggle(_ isEnabled: Bool) {
        environment.profileService.setEnabled(isEnabled)
        // Req 2: enabling while only the built-in Guest exists invites the user to
        // create or pick a profile straight away.
        if isEnabled, onlyGuestExists {
            openManageProfiles()
        }
    }

    var onlyGuestExists: Bool {
        let profiles = environment.profileService.profiles
        return profiles.count == 1 && profiles.first?.id == ProfileRecord.guestID
    }

    func openManageProfiles() {
        navigation.showProfileOverlay = true
        openWindow(id: "main")
    }
}

#Preview {
    ProfilesPreferencesPane()
        .environment(AppEnvironment.preview())
        .environment(AppSettings.preview)
        .environment(NavigationModel())
        .designTokens(.standard)
}
