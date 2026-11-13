// IntelligencePlaybackControlStrings — the playback-control grants, in words.
//
// A SEVENTH `PreferencesStrings` extension file, for the reason there are already
// six: `swiftlint --strict` caps a file at 400 lines and extension members do not
// count against the parent declaration, so every call site still reads
// `PreferencesStrings.<name>`.
//
// ── THE COPY STATES THE DEFAULT, BECAUSE THE DEFAULTS DIFFER ─────────────────
//
// The in-app grant is ON and the external one is OFF, and a listener who assumed
// they matched would be wrong in whichever direction they guessed. Both captions
// therefore open by saying which way their switch ships. That is the same honesty
// the External Access caption already practises ("Off by default…"), applied to
// the case where the answer is the other one.
import Foundation

extension PreferencesStrings {
    // MARK: In-app chat

    static let assistantControlSection = LocalizedStringResource(
        "app.preferences.intelligence.control.section",
        defaultValue: "Playback Control",
        comment: "Heading of the section deciding whether the in-app assistant may control the player"
    )

    static let assistantControlToggle = LocalizedStringResource(
        "app.preferences.intelligence.control.toggle",
        defaultValue: "Let the assistant play and pause your music",
        comment: "The switch allowing MacAMP's own assistant to control playback"
    )

    static let assistantControlCaption = LocalizedStringResource(
        "app.preferences.intelligence.control.caption",
        defaultValue:
        "On by default. In chat you can say “play this”, “pause” or “what's playing?” and MacAMP does it straight away.",
        comment: "Caption under the assistant playback-control switch, stating the default and what it enables"
    )

    static let assistantControlOffCaption = LocalizedStringResource(
        "app.preferences.intelligence.control.off.caption",
        defaultValue:
        "Turn it off for an assistant that can look things up and suggest playlists, but never touch the player.",
        comment: "Caption explaining what switching the assistant playback-control off leaves behind"
    )

    static let assistantControlScopeCaption = LocalizedStringResource(
        "app.preferences.intelligence.control.scope.caption",
        defaultValue:
        "It never changes your settings, your themes or your equaliser — only what is playing and what is queued.",
        comment: "Caption bounding what the assistant may control"
    )

    // MARK: External programs

    static let externalAccessControlToggle = LocalizedStringResource(
        "app.preferences.intelligence.external.control.toggle",
        defaultValue: "Also let them play and pause your music",
        comment: "The switch allowing a connected external program to control playback"
    )

    static let externalAccessControlCaption = LocalizedStringResource(
        "app.preferences.intelligence.external.control.caption",
        defaultValue:
        "Off by default. A connected tool could start, pause and skip your music, and change what plays next.",
        comment: "Caption under the external playback-control switch, stating the default and what it allows"
    )

    static let externalAccessControlNeedsAccess = LocalizedStringResource(
        "app.preferences.intelligence.external.control.needsAccess",
        defaultValue: "Allow external access first.",
        comment: "Caption explaining that the external playback-control switch depends on external access being on"
    )

    // MARK: The disclosure's own line

    static let externalAccessConsentControlHeading = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.control.heading",
        defaultValue: "Controlling your music is a separate switch:",
        comment: "Heading of the disclosure block that separates reading the library from controlling playback"
    )

    static let externalAccessConsentControlItem = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.control.item",
        defaultValue:
        "Accepting this lets tools READ your library. It does not let them touch the player.",
        comment: "Disclosure line stating that accepting external access does not grant playback control"
    )

    static let externalAccessConsentControlOptIn = LocalizedStringResource(
        "app.preferences.intelligence.external.consent.control.optIn",
        defaultValue:
        "Starting, pausing and skipping your music needs a second switch in this pane, which stays off until you turn it on.",
        comment: "Disclosure line naming the separate opt-in required before an external program may control playback"
    )
}
