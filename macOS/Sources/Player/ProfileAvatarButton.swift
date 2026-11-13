// ProfileAvatarButton — the player bar's leading profile entry point.
//
// A 36pt tappable ``ProfileAvatarView`` for the active profile. The parent gates
// it on `AppSettings.profilesEnabled`, so when profiles are off this control —
// and its `player.profileButton` accessibility identifier — is genuinely absent
// (not merely hidden). Tapping runs the injected `action`, which the parent wires
// to toggle the transient `NavigationModel.showProfileOverlay` flag, exactly as
// the identity zone toggles the now-playing overlay: the player bar keeps its
// callback-only relationship with navigation state.
import DesignSystem
import Persistence
import Services
import SwiftUI

struct ProfileAvatarButton: View {
    var action: () -> Void

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Button(action: action) {
            ProfileAvatarView(
                preset: preset,
                imagePath: environment.profileService.activeProfile.avatarImagePath,
                size: 36
            )
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help(Text(ProfileStrings.profileButtonHelp))
        .accessibilityIdentifier("player.profileButton")
        .accessibilityLabel(Text(ProfileStrings.profileButtonLabel(profileName: activeProfileName)))
        .pointingHandCursor()
    }

    private var preset: ProfileAvatarPreset {
        ProfileAvatarPreset(id: environment.profileService.activeProfile.avatarId)
    }

    private var activeProfileName: String {
        let active = environment.profileService.activeProfile
        return active.id == ProfileRecord.guestID
            ? String(localized: ProfileStrings.guestName)
            : active.name
    }
}
