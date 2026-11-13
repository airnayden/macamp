// IntelligencePlaybackControlSection — the in-app assistant's playback grant.
//
// ── WHY IT SITS RIGHT AFTER PROVIDER ─────────────────────────────────────────
//
// Provider answers "who is thinking"; this answers "what may it do". Both are
// about the assistant the listener talks to INSIDE MacAMP, so they belong
// together and above External Access, which is about a different principal
// entirely. Putting it among the feature bundles was rejected: a bundle switch
// turns a FEATURE on or off, while this bounds a capability of a feature that is
// already on.
//
// ── WHY THIS ONE SHIPS ON ────────────────────────────────────────────────────
//
// Every other grant in this pane is off by default because it either sends data
// somewhere or admits a stranger. This one does neither: nothing leaves the
// machine, nothing is written, and every effect is audible the moment it happens
// and undone by pressing pause. Typing "play it" into your own player's chat box
// IS the instruction — a switch you had to find first would be asking permission
// for the thing you just asked for. The caption says "On by default" in as many
// words so nobody has to discover that.
//
// The section is `.disabled(!settings.intelligenceEnabled)` for the same structural
// reason every other one is: there is no assistant to bound when the graph is not
// built.
import DesignSystem
import SwiftUI

/// Whether MacAMP's own assistant may touch the player.
struct IntelligencePlaybackControlSection: View {
    @Bindable var settings: AppSettings

    @Environment(\.designTokens) private var tokens
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Section {
            Text(PreferencesStrings.assistantControlSection)
                .font(tokens.typography.headline.font)
                .foregroundStyle(tokens.colors.textPrimary.resolve(scheme))
            Toggle(isOn: $settings.assistantPlaybackControlEnabled) {
                Text(PreferencesStrings.assistantControlToggle)
            }
            .accessibilityIdentifier("intelligence.playbackControl.toggle")
            PreferenceCaption(text: PreferencesStrings.assistantControlCaption)
            PreferenceCaption(text: PreferencesStrings.assistantControlOffCaption)
            PreferenceCaption(text: PreferencesStrings.assistantControlScopeCaption)
        }
        .disabled(!settings.intelligenceEnabled)
    }
}

#Preview {
    Form {
        IntelligencePlaybackControlSection(settings: AppSettings.preview)
    }
    .designTokens(.standard)
}
